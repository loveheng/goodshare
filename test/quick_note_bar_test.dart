import 'package:flutter/material.dart';
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
  });

  Future<void> pumpShell(WidgetTester tester) async {
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
    await tester.tap(find.text('记点什么…  ·  点按或上滑展开'));
    await tester.pumpAndSettle();
  }

  testWidgets('收合态：拉手存在，无布局异常', (tester) async {
    await pumpShell(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('记点什么…  ·  点按或上滑展开'), findsOneWidget);
  });

  testWidgets('展开态：点拉手不抛 unbounded flex 异常，顶栏出现', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('记点什么…  ·  点按或上滑展开'));
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
      find.text('记点什么…  ·  点按或上滑展开'),
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
          'peek=${find.text('记点什么…  ·  点按或上滑展开').evaluate().length}');
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
}
