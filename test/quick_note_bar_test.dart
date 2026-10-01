import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/share/text_collector.dart';
import 'package:goodshare/ui/quick_note_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 便利贴布局回归：展开态靠 Column+Expanded 撑满，依赖**有界**高度约束。
/// 曾因 home_shell 的 Positioned 只给 bottom 锚点（高度无界）触发 unbounded
/// flex layout 异常，整棵便利贴子树渲染失败——真机表现=点一下整个功能消失。
/// 本测试复刻 home_shell 挂载结构，断言展开前后无布局异常。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
    // record 插件在测试环境无平台实现，AudioRecorder 构造的异步 MissingPluginException
    // 会落在「测试完成后」把用例误判失败——mock 掉其方法通道
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'),
            (call) async => null);
    // ffmpeg_kit 的会话事件通道在测试环境无平台实现，其 listen 的
    // MissingPluginException 逃逸出 probeVideoDurationMs 的 try/catch
    // （异步事件回调抛出），mock 掉保证视频门槛用例只走纯 Dart 分支
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.arthenica.com/ffmpeg_kit_event'),
            (call) async => null);
  });

  Future<Repository> pumpShell(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository();
    final handler = ItemActionHandler(repo);
    final collector = TextCollector(handler);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // 复刻 home_shell：非 positioned 列表 + Positioned 覆盖层
            ListView(children: const [Text('占位列表')]),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: QuickNoteBar(collector: collector, handler: handler),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return repo;
  }

  // 面板态是静态字段留存（防 Activity 重建丢态），上一个测试的展开会泄漏
  // 到下一个测试——每个用例先归位收合态，保证用例彼此独立。
  Future<void> ensureCollapsed(WidgetTester tester) async {
    final collapse = find.byIcon(Icons.keyboard_arrow_down);
    if (tester.any(collapse)) {
      await tester.tap(collapse);
      await tester.pumpAndSettle();
    }
  }

  Future<void> expandViaPeek(WidgetTester tester) async {
    await ensureCollapsed(tester);
    await tester.tap(find.text('记点什么…'));
    await tester.pumpAndSettle();
  }

  testWidgets('收合态：拉手存在，无布局异常', (tester) async {
    await pumpShell(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('记点什么…'), findsOneWidget);
  });

  testWidgets('展开态：点拉手不抛 unbounded flex 异常，顶栏出现', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('记点什么…'));
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: '展开态必须在有界高度下完成布局（Column+Expanded 依赖紧约束）',
    );
    expect(find.text('保存'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('上滑拽出：手势展开仍生效（跟手改版回归）', (tester) async {
    await pumpShell(tester);
    await ensureCollapsed(tester);
    await tester.drag(
      find.text('记点什么…'),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('保存'), findsOneWidget, reason: '上滑过阈值应完成展开');
  });

  testWidgets('标题按钮：当前行加 ## 前缀，再点去除', (tester) async {
    await pumpShell(tester);
    void probe(String tag) {
      // ignore: avoid_print
      print('PROBE[$tag] tf=${find.byType(TextField).evaluate().length} '
          'save=${find.text('保存').evaluate().length} '
          'peek=${find.text('记点什么…').evaluate().length}');
    }
    probe('pump');
    await expandViaPeek(tester);
    probe('after-expand');
    await tester.enterText(find.byType(TextField), '购物清单');
    await tester.tap(find.byIcon(Icons.title));
    await tester.pumpAndSettle();
    probe('after-title-tap');
    final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(ctrl.text, '## 购物清单');
    await tester.tap(find.byIcon(Icons.title));
    await tester.pumpAndSettle();
    expect(ctrl.text, '购物清单');
  });

  testWidgets('粗体按钮：无选中插入 **** 且光标居中', (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.byIcon(Icons.format_bold));
    await tester.pumpAndSettle();
    final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(ctrl.text, 'abc****');
    expect(ctrl.selection.baseOffset, 5, reason: '光标应落在 ** 中间');
  });

  testWidgets('保存路由：纯文本走 collectText，保存成功清空内容区（可连续记）', (tester) async {
    final repo = await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), '购物清单一条');
    await tester.tap(find.text('保存'));
    // sqflite_ffi 写链的每道真实异步边界都需要「runAsync 放行真实时钟 →
    // pump 推进假区微任务」交替驱动，循环到 UI 反馈出现为止
    // （2026-09-30 保存路由用例踩坑：单独 runAsync 或单独 pump 都推不完）
    for (var i = 0; i < 30; i++) {
      if (find.text('已记下').evaluate().isNotEmpty) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('已记下'), findsOneWidget, reason: '保存成功有反馈');
    await tester.runAsync(() async {
      expect(await repo.count(), 1, reason: '纯文本保存 = 一个 note 条目');
      final items = await repo.list();
      expect(items.single.preview, contains('购物清单一条'));
    });
    expect(find.byType(TextField), findsOneWidget,
        reason: '保存后内容区清空但面板保持张开（单空文本段 + 提示语）');
  });

  testWidgets('保存按钮内容感知：空态禁用，输入后点亮（禁用=实色无半透明罩）', (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '保存'),
          )
          .onPressed,
      isNull,
      reason: '空便签：保存钮不可点',
    );
    await tester.enterText(find.byType(TextField), '第一条');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '保存'),
          )
          .onPressed,
      isNotNull,
      reason: '有内容：保存钮点亮（橘红动作态）',
    );
  });

  testWidgets('视频门槛：白名单外格式拦截提示且不留孤儿副本', (tester) async {
    final tmp = await tester.runAsync(() async {
      final d = await Directory.systemTemp.createTemp('gs_note_video_block');
      File('${d.path}/pick.webm').writeAsStringSync('fake-webm-bytes');
      return d;
    });
    const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
          pickerChannel, (call) async => '${tmp!.path}/pick.webm')
      ..setMockMethodCallHandler(pathChannel, (call) async => tmp!.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(pickerChannel, null)
        ..setMockMethodCallHandler(pathChannel, null);
    });
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.tap(find.byIcon(Icons.movie_creation_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择'));
    for (var i = 0; i < 20; i++) {
      if (find.text('暂不支持该格式，建议使用 MP4 或 MOV').evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('暂不支持该格式，建议使用 MP4 或 MOV'), findsOneWidget,
        reason: '拦截类必须 SnackBar 明示原因（R1）');
    expect(find.byIcon(Icons.play_circle_outline), findsNothing,
        reason: '拦截类不得插入视频卡');
    // 删除链是 FakeAsync 区的续体：runAsync 放行真实 IO，pump 推进微任务，
    // 交替到副本消失（同「保存路由」用例的既有口径）
    bool deleted() {
      final shares = Directory('${tmp!.path}/shares');
      return !shares.existsSync() || shares.listSync().isEmpty;
    }

    for (var i = 0; i < 20 && !deleted(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final shares = Directory('${tmp!.path}/shares');
    final leftovers =
        shares.existsSync() ? shares.listSync().whereType<File>().toList() : <File>[];
    expect(leftovers, isEmpty, reason: '拦截后不留孤儿副本');
  });

  testWidgets('视频门槛：相册 mp4 校验通过即插入视频卡（真机回归：通过后未插入）',
      (tester) async {
    // 真机回归（2026-10-01）：checkNoteVideoAlbum 约定 null=通过，但
    // _pickAlbumVideo 把 null 当「已取消」直接 return——mp4/mov 通过校验后
    // 永不插入，只有 >5min 弹窗路径才插得进去。
    final tmp = await tester.runAsync(() async {
      final d = await Directory.systemTemp.createTemp('gs_note_video_ok');
      File('${d.path}/pick.mp4').writeAsStringSync('fake-mp4-bytes');
      return d;
    });
    const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    void mock() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(
            pickerChannel, (call) async => '${tmp!.path}/pick.mp4')
        ..setMockMethodCallHandler(pathChannel, (call) async => tmp!.path);
    }

    void unmock() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(pickerChannel, null)
        ..setMockMethodCallHandler(pathChannel, null);
    }

    mock();
    addTearDown(unmock);
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.tap(find.byIcon(Icons.movie_creation_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从相册选择'));
    // 选→拷贝→FFprobe 探时长（测试环境 MissingPlugin 被吞→判过）→插入，
    // 真实文件 IO 在 FakeAsync 外完成，runAsync/pump 交替驱动（同上踩坑口径）
    for (var i = 0; i < 20; i++) {
      if (find.byIcon(Icons.play_circle_outline).evaluate().isNotEmpty) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('视频（点按预览，保存后详情可播放）'), findsOneWidget,
        reason: '校验通过的视频必须插入视频卡');
  });
}
