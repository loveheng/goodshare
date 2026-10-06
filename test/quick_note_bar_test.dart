import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/draft_store.dart';
import 'package:goodshare/ui/format_dial.dart';
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

  Future<Repository> pumpShell(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository();
    final handler = ItemActionHandler(repo);
    final collector = TextCollector(handler);
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
                collector: collector,
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

  // 速记转盘（2026-10-03 拍板）：旧胶囊+小横条退役，换 48dp「Tt」圆钮 +
  // 三级径向盘（挂载与交互见 format_dial.dart）。编辑区全程无 md 标记。
  testWidgets('圆钮：点按展开转盘，再点 hub 收合（显式 toggle）', (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), '内容');
    expect(find.text('Tt'), findsOneWidget, reason: '圆钮常驻可见');
    expect(find.text('H'), findsNothing);
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    // 二级 3 扇区：业界标识 H/Aa/BIU（「Aa」含 hub 盘面字两处）
    expect(find.text('H'), findsOneWidget);
    expect(find.text('Aa'), findsWidgets);
    expect(find.text('BIU'), findsOneWidget);
    // 展开期 hub 即格式按钮本体：原 Tt 钮隐藏（防双显重叠）
    expect(find.text('Tt'), findsNothing, reason: '展开期原钮隐藏');
    // 显式 toggle：点 hub（内整圆=原死区语义，根态松手=收合）
    final hub =
        tester.getRect(find.byType(FormatDial)).bottomRight -
        const Offset(kDialHubRadius, kDialHubRadius);
    await tester.tapAt(hub);
    await tester.pumpAndSettle();
    expect(find.text('H'), findsNothing, reason: '点 hub 应收合');
    expect(find.text('Tt'), findsOneWidget, reason: '收合后原钮恢复');
  });

  /// 转盘拖选手势：在 [FormatDial] 角锚坐标系里按下-移动-松手。面板矩形
  /// 已为 hub 完整圆外扩 hub 半径（锚点内收），扇心=右下角点向面板内收 (hubR,hubR)。
  Future<void> dialDrag(
    WidgetTester tester, {
    required Offset at,
    Offset? move,
  }) async {
    final origin =
        tester.getRect(find.byType(FormatDial)).bottomRight -
        const Offset(kDialHubRadius, kDialHubRadius);
    final g = await tester.startGesture(origin + at);
    await tester.pump();
    if (move != null) {
      await g.moveBy(move - at);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
  }

  testWidgets('转盘选「一级标题」：当前行直设档位，编辑区无 # 前缀，角标 H1',
      (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), '购物清单');
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    // 松手即选：按住「标题」扇区（idx0 中角 -165°、中径 70）扇出三级，
    // 再滑 H1（叶子 idx0 中角 -157.5°、中径 122）
    await dialDrag(
      tester,
      at: const Offset(-48.3, -12.9),
      move: const Offset(-48.3, -12.9),
    );
    await tester.pumpAndSettle();
    expect(find.text('H1'), findsOneWidget, reason: '三级扇出 H1/H2');
    await dialDrag(tester, at: const Offset(-85.9, -35.6));
    await tester.pumpAndSettle();
    final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(ctrl.text, '购物清单', reason: '所见即所得：编辑区无 # 前缀');
    expect(find.text('H1'), findsOneWidget, reason: '圆钮角标外显当前档位');
  });

  testWidgets('先选「加粗」后打：文字无 ** 标记，角标 B 外显', (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    // 先有激活段（_activeText 非空面板才挂载），再开转盘
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    // 按住「行内」扇区（idx2 中角 -105°、中径 70）期间 pump 150ms 触发
    // hover 联动扇出，松手保持展开（与 format_dial_test 稳定手势同款）
    final origin =
        tester.getRect(find.byType(FormatDial)).bottomRight -
        const Offset(kDialHubRadius, kDialHubRadius);
    final g = await tester.startGesture(origin + const Offset(-12.9, -48.3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await g.up();
    await tester.pumpAndSettle();
    // 行内子盘 B（idx0 中角 -157.5°、中径 122）松手即选
    await dialDrag(tester, at: const Offset(-85.9, -35.6));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget, reason: '圆钮角标外显激活 mark');
    await tester.enterText(find.byType(TextField), '重点');
    final ctrl = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(ctrl.text, '重点', reason: '所见即所得：编辑区无 ** 标记');
  });

  testWidgets('行内单选制：B 激活中再选 I → I 替换 B（不做复合选择）',
      (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    // 激活 B（行内子盘 idx0，与上加粗用例同手势）
    final origin =
        tester.getRect(find.byType(FormatDial)).bottomRight -
        const Offset(kDialHubRadius, kDialHubRadius);
    final g = await tester.startGesture(origin + const Offset(-12.9, -48.3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await g.up();
    await tester.pumpAndSettle();
    await dialDrag(tester, at: const Offset(-85.9, -35.6)); // B 松手挂起
    await tester.pumpAndSettle(); // 倒计时走完提交并闭合
    expect(find.text('B'), findsOneWidget, reason: 'B 已激活');
    // 再开转盘选 I：单选制下应替换 B 而非叠加
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    final origin2 =
        tester.getRect(find.byType(FormatDial)).bottomRight -
        const Offset(kDialHubRadius, kDialHubRadius);
    final g2 = await tester.startGesture(origin2 + const Offset(-12.9, -48.3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await g2.up();
    await tester.pumpAndSettle();
    // 行内子盘 I（idx1 中角 -135°、中径 122）
    await dialDrag(tester, at: const Offset(-86.3, -86.3));
    await tester.pumpAndSettle();
    expect(find.text('I'), findsOneWidget, reason: 'I 替换生效，角标外显');
    expect(find.text('B'), findsNothing, reason: '单选制：B 被替换熄灭，不叠加');
  });

  testWidgets('失焦自动闭合：失焦 1.5s 收合，回焦撤销（替代点空白命中层）', (tester) async {
    await pumpShell(tester);
    await expandViaPeek(tester);
    await tester.enterText(find.byType(TextField), '失焦');
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    expect(find.text('H'), findsOneWidget, reason: '转盘已展开');
    // 失焦（清全场焦点）→ 1.5s 内回焦 = 撤销，超时 = 自动收合
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('H'), findsOneWidget, reason: '延时窗内未闭合');
    await tester.enterText(find.byType(TextField), '回焦');
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('H'), findsOneWidget, reason: '回焦撤销延时器');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('H'), findsNothing, reason: '失焦 1.5s 后自动闭合');
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
