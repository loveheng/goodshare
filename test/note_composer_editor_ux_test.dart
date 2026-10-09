import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart' show InlineMark;
import 'package:goodshare/ui/note_composer_editor.dart';

/// 回归测试：覆盖 2026-10-08 的两处 UX 修复
///   ① 格式入口常驻（失焦段也显示极淡角标，不再完全隐身）
///   ③ 行内 mark 放宽 D5（有选区→套到选中文字；无选区→先选后打）
void main() {
  Future<NoteComposerEditorState> pump(
    WidgetTester tester,
    String text,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: NoteComposerEditor(initialRows: [
              ['t', text],
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(NoteComposerEditor)) as NoteComposerEditorState;
  }

  testWidgets('① 失焦段也显示格式入口角标（不再完全隐身）', (tester) async {
    await pump(tester, 'hello');
    // 初始无任何段聚焦，角标仍应常驻可见（opacity 0.32 但 widget 存在）。
    expect(find.text('T'), findsOneWidget,
        reason: '修复前失焦段角标 width=0 完全隐藏（findsNothing），现在常驻');
  });

  testWidgets('③ 有选区点 B/I 直接套到选中文字（所见即所得）', (tester) async {
    final state = await pump(tester, '买菜牛奶');
    await tester.tap(find.byType(TextField).first); // 聚焦首段
    await tester.pumpAndSettle();
    await tester.tap(find.text('T').first); // 开面板（首匹配=段首角标；面板「正文」档另有同名徽标）
    await tester.pumpAndSettle();
    // 直接在控制器上划出选区 [0,2)="买菜"
    final seg = state.segs.first as NoteTextSeg;
    seg.ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.tap(find.text('B')); // 点亮加粗（选区分支）
    await tester.pumpAndSettle();
    final bold = seg.spans.runs.where((r) => r.mark == InlineMark.bold).toList();
    expect(bold.any((r) => r.start == 0 && r.end == 2), isTrue,
        reason: '选中"买菜"点B后，该区间立即变粗（不再"先选后打"）');
    // 选区保持，再点 I 叠加斜体
    await tester.tap(find.text('I'));
    await tester.pumpAndSettle();
    final italic = seg.spans.runs.where((r) => r.mark == InlineMark.italic).toList();
    expect(italic.any((r) => r.start == 0 && r.end == 2), isTrue,
        reason: '选区路径下 B/I 可嵌套叠加（与先选后打的单选制不同）');
  });

  testWidgets('③ 无选区点 B 仍走先选后打（之后输入变粗，已写不变）', (tester) async {
    final state = await pump(tester, '买菜');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('T').first); // 开面板（首匹配=段首角标；面板「正文」档另有同名徽标）（无选区）
    await tester.pumpAndSettle();
    await tester.tap(find.text('B')); // 点亮加粗（无选区分支）
    await tester.pumpAndSettle();
    final seg = state.segs.first as NoteTextSeg;
    expect(seg.spans.runs.where((r) => r.mark == InlineMark.bold).isEmpty, isTrue,
        reason: '无选区点B对已有"买菜"无效（先选后打语义保留）');
    await tester.enterText(find.byType(TextField).first, '买菜牛奶');
    await tester.pumpAndSettle();
    final bold = seg.spans.runs.where((r) => r.mark == InlineMark.bold).toList();
    expect(bold.isNotEmpty, isTrue, reason: '激活后输入的"牛奶"变粗');
  });

  Future<NoteComposerEditorState> openPanelAndPick(
    WidgetTester tester,
    NoteComposerEditorState state,
    String tileLabel,
  ) async {
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('T').first); // 开面板（首匹配=段首角标；面板「正文」档另有同名徽标）
    await tester.pumpAndSettle();
    await tester.tap(find.text(tileLabel)); // 选结构档
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('⑤ 删光重打仍保留列表格式（不再静默丢失）', (tester) async {
    final state = await pump(tester, '买菜');
    final seg = state.segs.first as NoteTextSeg;
    await openPanelAndPick(tester, state, '列表项'); // 变 bullet
    expect(seg.spans.plain.startsWith('- '), isTrue);
    await tester.enterText(find.byType(TextField).first, ''); // 删光
    await tester.pumpAndSettle();
    expect(seg.spans.plain.startsWith('- '), isTrue,
        reason: '删光后自动恢复空列表项，重打仍是列表');
  });

  testWidgets('⑤ 整体替换仍保留列表格式', (tester) async {
    final state = await pump(tester, '买菜');
    final seg = state.segs.first as NoteTextSeg;
    await openPanelAndPick(tester, state, '列表项');
    await tester.enterText(find.byType(TextField).first, '牛奶面包'); // 整体替换
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '- 牛奶面包',
        reason: '整体替换后仍是列表项，marker 不丢');
  });

  testWidgets('⑤ 浮层选「正文」主动退出列表不自动恢复', (tester) async {
    final state = await pump(tester, '买菜');
    final seg = state.segs.first as NoteTextSeg;
    await openPanelAndPick(tester, state, '列表项'); // 变 bullet（面板保持展开）
    await tester.tap(find.text('正文')); // 主动退出（⑥保持展开，无需先关面板）
    await tester.pumpAndSettle();
    expect(seg.spans.plain.startsWith('- '), isFalse,
        reason: '主动选正文退出列表，不应自动恢复');
    await tester.enterText(find.byType(TextField).first, 'x'); // 再编辑
    await tester.pumpAndSettle();
    expect(seg.spans.plain.startsWith('- '), isFalse,
        reason: '主动退出后编辑不再被恢复成列表');
  });

  testWidgets('⑥ 结构档选完面板保持展开（与 B/I 一致）', (tester) async {
    await pump(tester, '买菜');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('T').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题二')); // 选 H2
    await tester.pumpAndSettle();
    // 面板仍可见（标题二瓦片仍在），未选完即收
    expect(find.text('标题二'), findsWidgets,
        reason: '⑥ 结构档选完不收面板');
  });

  testWidgets('⑥⑦ 角标 toggle 关闭面板 + 返回直接退出', (tester) async {
    await pump(tester, '买菜');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('T').first); // 开面板（首匹配=段首角标；面板「正文」档另有同名徽标）
    await tester.pumpAndSettle();
    expect(find.text('标题二'), findsWidgets);
    await tester.tap(find.text('T').first); // 再点角标 = toggle 关
    await tester.pumpAndSettle();
    expect(find.text('标题二'), findsNothing, reason: '角标再点关闭面板');
    // ⑦ PopScope 不再拦截返回：canPop 应为 true
    final pop = tester.widget<PopScope>(find.byType(PopScope));
    expect(pop.canPop, isTrue, reason: '⑦ 返回直接退出，不先关面板');
  });
}
