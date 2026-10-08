import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/draft_store.dart';
import 'package:goodshare/models/item.dart' show InboxItem;
import 'package:goodshare/share/text_collector.dart';
import 'package:goodshare/ui/quick_note_bar.dart';
import 'package:goodshare/ui/toast.dart';
import 'package:goodshare/ui/video_cover.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 便利贴布局回归：展开态靠 Column+Expanded 撑满，依赖**有界**高度约束。
/// 曾因 home_shell 的 Positioned 只给 bottom 锚点（高度无界）触发 unbounded
/// flex layout 异常，整棵便利贴子树渲染失败——真机表现=点一下整个功能消失。
/// 本测试复刻 home_shell 挂载结构，断言展开前后无布局异常。
///
/// 2026-10-08 清理：随悬浮球三级径向盘（format_dial.dart）退役，本文件的 5 条
/// 转盘用例一并删除；「先选后打 / 行内单选制」的行为覆盖迁至
/// test/composer_inline_mark_test.dart 钉新形态（浮层 B/I 档）。
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
  });

  // Toast 单例是 static 跨用例状态：error 驻留档会吞掉后续用例的轻档提示
  tearDown(() => ToastManager.resetForTest());

  Future<Repository> pumpShell(
    WidgetTester tester, {
    TextCollector? collector,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository();
    final handler = ItemActionHandler(repo);
    final collector0 = collector ?? TextCollector(handler);
    await tester.pumpWidget(MaterialApp(
      // Toast 挂根 overlay（SnackBar 退役）：测试环境同样绑全局 navigatorKey
      navigatorKey: ToastManager.navigatorKey,
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
              child: QuickNoteBar(
                collector: collector0,
                handler: handler,
                draftPersistencer: InMemoryDraftStore(),
              ),
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

  // R5 拆分·UI 侧（2026-10-08）：本用例**不碰真实 sqlite**——落库正确性由数据侧
  // test/text_collector_test.dart「速记保存路径」钉住，这里只守「内容被交给动作层
  // 唯一写入口 + 有反馈 + 内容区清空」。（原形态是 UI+真实 sqlite 组合，sqflite
  // 内部 10s Timer 与 FakeAsync 打架导致静默失败，见项目 R5。）
  testWidgets('保存路由（UI 侧）：点保存 → 内容交 TextCollector + 反馈 + 清空内容区',
      (tester) async {
    final fake = _FakeCollector(ItemActionHandler(Repository()));
    await pumpShell(tester, collector: fake);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), '购物清单一条');
    await tester.pump();
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 20; i++) {
      if (find.text('已记下').evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(tester.takeException(), isNull);
    expect(fake.collected, '购物清单一条',
        reason: '速记内容必须交给动作层唯一写入口（UI 不自造落库）');
    expect(fake.sourceApp, '速记');
    expect(find.text('已记下'), findsOneWidget, reason: '保存成功有反馈');
    expect(find.byType(TextField), findsOneWidget,
        reason: '保存后内容区清空但面板保持张开（单空文本段 + 提示语）');
    // Toast 的退场 Timer/动画存活到用例结束会触发 flutter_test 不变量检查
    //（pending Timer / active Ticker，检查先于 tearDown 执行）——用例内硬停复位
    await ToastManager.resetForTest();
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
    // Toast 退场 Timer/动画触发 flutter_test 不变量检查（先于 tearDown）——用例内硬停
    await ToastManager.resetForTest();
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
    // 视频卡=原生提帧封面组件（测试环境无平台实现→null 回落占位，组件仍在）
    expect(find.byType(VideoCoverImage), findsOneWidget,
        reason: '校验通过的视频必须插入视频卡');
    // Toast 退场 Timer/动画触发 flutter_test 不变量检查（先于 tearDown）——用例内硬停
    await ToastManager.resetForTest();
  });
}

/// 测试替身（R5 拆分·UI 侧）：只记录调用参数，**不碰真实 sqlite**——
/// 「落库对不对」归数据侧 `test/text_collector_test.dart` 守，UI 只守接线。
class _FakeCollector extends TextCollector {
  _FakeCollector(super.handler);

  String? collected;
  String? sourceApp;
  List<String>? tags;

  @override
  Future<InboxItem?> collectText(
    String text, {
    String? sourceApp,
    List<String>? tags,
  }) async {
    collected = text;
    this.sourceApp = sourceApp;
    this.tags = tags;
    return null;
  }
}
