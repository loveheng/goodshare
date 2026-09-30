import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/share/text_collector.dart';
import 'package:goodshare/ui/quick_note_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 回归：展开态面板顶缘必须避开状态栏（B1 拍板：头部固定在搜索框水平带）。
/// 曾因 Scaffold 消费 body 的 MediaQuery.padding（=0），「避开状态栏」失效，
/// 顶栏顶进状态栏（真机=日期行被遮挡）。状态栏高度改取 FlutterView 原始 padding。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  testWidgets('展开态：顶栏不被状态栏遮挡', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = Repository();
    final handler = ItemActionHandler(repo);
    final collector = TextCollector(handler);
    // 状态栏逻辑高度 40（物理 120 / dpr 3，默认测试视口 800x600 逻辑）
    tester.view.padding = FakeViewPadding(top: 120);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
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
    await tester.tap(find.text('记点什么…  ·  点按或上滑展开'));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.byIcon(Icons.keyboard_arrow_down)).dy;
    expect(top, greaterThanOrEqualTo(40), reason: '顶栏不得顶进状态栏');

    // 解耦回归（用户 2026-09-30 提问）：搜索条随滚动隐藏（D1 floating+snap），
    // 便签头部不得连带隐藏/位移——面板在 HomeShell Stack 上层、锚点是
    // 屏幕静态位置，与页面滚动零耦合。滚动列表后头部位置必须纹丝不动。
    await tester.drag(find.text('占位列表'), const Offset(0, -300));
    await tester.pumpAndSettle();
    final topAfterScroll =
        tester.getTopLeft(find.byIcon(Icons.keyboard_arrow_down)).dy;
    expect(topAfterScroll, top,
        reason: '搜索条隐藏（列表滚动）后便签头部位置不变、不隐藏');
  });
}
