import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/share/quick_note_text_actions.dart'
    show seedTextTruth, serializeTextTruthSpans;
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 列表输入优雅化（2026-10-07 拍板）回归：
/// - 打字 `- 甲` / `[ ] 甲` 即时成列表项/待办（此前只有粘贴导入才行）；
/// - 列表行回车**不拆段**、就地起新项——物理键盘与软键盘（IME 文本变更）两路同源；
/// - 空项再回车退出列表；勾选不继承；非列表行回车与多行粘贴行为零变更。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<NoteComposerEditorState> pump(
    WidgetTester tester,
    List<List<String>> rows,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: NoteComposerEditor(initialRows: rows),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return tester.state(find.byType(NoteComposerEditor))
        as NoteComposerEditorState;
  }

  NoteTextSeg textSeg(NoteComposerEditorState state, [int i = 0]) =>
      state.segs[i] as NoteTextSeg;

  Future<void> pressEnter(
    WidgetTester tester,
    NoteTextSeg seg, {
    required int caret,
  }) async {
    seg.focus.requestFocus();
    seg.ctrl.selection = TextSelection.collapsed(offset: caret);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets('B3：空列表项段首退格 = 出列摘圆点，不并入上一段', (tester) async {
    // 两段：前段有正文，后段是空列表项（用户敲完 `- ` 还没打字）
    final state = await pump(tester, const [
      ['t', '前一段'],
      ['t', ''],
    ]);
    final seg = textSeg(state, 1);
    await tester.enterText(find.byType(TextField).at(1), '- ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '- ', reason: 'S3 文本真相：标记保留在 buffer');
    expect(seg.spans.listRuns.single.kind, SpanListKind.bullet);

    // 段首退格：出列（摘 run），绝不能触发段合并
    seg.focus.requestFocus();
    seg.ctrl.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(state.segs.length, 2, reason: '不并段：段数不变');
    expect((state.segs[0] as NoteTextSeg).spans.plain, '前一段',
        reason: '前段内容不被吞并');
    expect(seg.spans.listRuns, isEmpty, reason: '占位 run 已摘除');
  });

  testWidgets('B3：多行项首行段首退格不走出列（有续行，保持并段语义）',
      (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);
    // 文本真相播种多行列表项（标记留在 buffer，enterText 多行会拆段故直灌）
    final seeded = seedTextTruth('- 甲\n  续行');
    seg.spans
      ..plain = seeded.plain
      ..runs = seeded.runs
      ..levelRuns = seeded.levelRuns
      ..listRuns = seeded.listRuns;
    seg.ctrl.text = seeded.plain;
    await tester.pumpAndSettle();
    expect(seg.spans.listRuns.single.end, greaterThan(2),
        reason: '续行被吞入同一 run');

    seg.focus.requestFocus();
    seg.ctrl.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    // S3 文本真相：行首退格 = 删标记出列（B3 同语义，多行项首行不再特判并段
    // ——续行按缩进自判归属，标记删除后续行自然脱离列表）
    expect(seg.spans.listRuns, isEmpty, reason: '标记已删：本行回正文');
    expect(seg.spans.plain, '甲\n  续行');
  });

  testWidgets('逐字打 `- 甲`：即时成列表项（文本真相：标记留在 buffer）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);

    await tester.enterText(find.byType(TextField).first, '-');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '-', reason: '标记未完整（- 后无空格）→ 不落定');
    expect(seg.spans.listRuns, isEmpty);

    await tester.enterText(find.byType(TextField).first, '- ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '- ', reason: 'S3 文本真相：标记保留在 buffer');
    expect(seg.spans.listRuns.single.kind, SpanListKind.bullet);

    // 之后每敲一个字，派生视图随行生长
    await tester.enterText(find.byType(TextField).first, '- 甲');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '- 甲');
    expect(seg.spans.listRuns.length, 1);
    expect(seg.spans.listRuns.single.start, 0);
    expect(seg.spans.listRuns.single.end, 3);
    expect(serializeTextTruthSpans(seg.spans), '- 甲');
  });

  testWidgets('逐字打 `[ ] 甲`：即时成未勾选待办（裸待办也认）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);

    await tester.enterText(find.byType(TextField).first, '[ ] ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '[ ] ', reason: 'S3 文本真相：标记保留在 buffer');
    expect(seg.spans.listRuns.single.kind, SpanListKind.todo);
    expect(seg.spans.listRuns.single.done, false);

    await tester.enterText(find.byType(TextField).first, '[ ] 甲');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '[ ] 甲', reason: 'S3 文本真相：所打即所存（裸写不含 - 前缀）');
    expect(seg.spans.listRuns.length, 1);
    expect(serializeTextTruthSpans(seg.spans), '[ ] 甲');
  });

  testWidgets('列表项行尾回车（物理键盘）：不拆段，就地起新项', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length);

    expect(state.segs.length, 1, reason: '拆段会把列表切成互不相干的独立段');
    expect(seg.spans.plain, '- 甲\n- ');
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].start, 4);
    expect(seg.ctrl.selection.extentOffset, seg.spans.plain.length);
  });

  testWidgets('列表项行尾回车（软键盘/IME 文本变更）：同样不拆段', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    // 软键盘无按键事件可依：IME 提交「单 \n 插入」文本变更 → enterWithMarker
    // 续标记重写为 `- 甲\n- `（与物理回车同源）。
    await tester.enterText(find.byType(TextField).first, '- 甲\n');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.plain, '- 甲\n- ');
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].start, 4);
  });

  testWidgets('新项打字：占位项贴合新行（序列化出两个列表项）',
      (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length);
    await tester.enterText(find.byType(TextField).first, '- 甲\n- 乙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.plain, '- 甲\n- 乙');
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].start, 4);
    expect(seg.spans.listRuns[1].end, 7);
    expect(serializeTextTruthSpans(seg.spans), '- 甲\n- 乙');
  });

  testWidgets('连打三个列表项：回车 → 打字序列产出三项 md', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length);
    await tester.enterText(
        find.byType(TextField).first, '- 甲\n- 乙');
    await tester.pumpAndSettle();
    await pressEnter(tester, seg, caret: seg.spans.plain.length);
    await tester.enterText(
        find.byType(TextField).first, '- 甲\n- 乙\n- 丙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.listRuns.length, 3);
    expect(serializeTextTruthSpans(seg.spans), '- 甲\n- 乙\n- 丙');
  });

  testWidgets('空列表项再回车：退出列表（回到普通段落）', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length); // 起空新项
    expect(seg.spans.listRuns.length, 2);
    await pressEnter(tester, seg, caret: seg.spans.plain.length); // 空项上再回车

    expect(state.segs.length, 1);
    expect(seg.spans.plain, '- 甲\n\n', reason: '空项标记被删（退出列表）');
    expect(seg.spans.listRuns.length, 1, reason: '只剩首行项——不再是两项');
    expect(serializeTextTruthSpans(seg.spans), '- 甲\n\n');
  });

  testWidgets('待办项回车：新项同为 todo 但未勾选（勾选不继承）', (tester) async {
    final state = await pump(tester, const [['t', '- [x] 已完成']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length);

    final runs = seg.spans.listRuns;
    expect(runs.length, 2);
    expect(runs[0].kind, SpanListKind.todo);
    expect(runs[0].done, true);
    expect(runs[1].kind, SpanListKind.todo);
    expect(runs[1].done, false);
  });

  testWidgets('逐字打 `1. 甲`：即时成有序项（序号在 buffer，凹槽渲染）',
      (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);

    await tester.enterText(find.byType(TextField).first, '1. ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '1. ', reason: 'S3 文本真相：字面序号保留');
    expect(seg.spans.listRuns.single.kind, SpanListKind.ordered);

    await tester.enterText(find.byType(TextField).first, '1. 甲');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '1. 甲');
    expect(serializeTextTruthSpans(seg.spans), '1. 甲');
    expect(find.text('1.'), findsOneWidget, reason: '序号画在凹槽里');
  });

  testWidgets('有序项回车：新项同为有序，字面序号自动续排', (tester) async {
    final state = await pump(tester, const [['t', '1. 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length);
    await tester.enterText(
        find.byType(TextField).first, '1. 甲\n2. 乙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].kind, SpanListKind.ordered);
    expect(serializeTextTruthSpans(seg.spans), '1. 甲\n2. 乙');
    expect(find.text('2.'), findsOneWidget);
  });

  testWidgets('多行列表项首行末尾回车：续行归新项（不沦为孤儿正文）',
      (tester) async {
    final state = await pump(tester, const [['t', '- 甲\n  续行']]);
    final seg = textSeg(state);
    expect(seg.spans.listRuns.length, 1, reason: '续行不新建 run');

    await pressEnter(tester, seg, caret: 4); // 首行（"甲"）末尾
    expect(state.segs.length, 1);
    // S3：新行起 `- ` 空项，`  续行` 按缩进续行语义吞入**新项**（run 1 个、
    // end 覆盖到续行尾）——续行不沦为孤儿正文，由派生视图几何表达。
    expect(seg.spans.listRuns.length, 1);
    expect(seg.spans.listRuns.single.end, seg.spans.plain.length,
        reason: '续行吞入新项 run（几何延伸）');

    final blocks =
        const MarkdownSubsetParser().parse(serializeTextTruthSpans(seg.spans));
    final list = blocks.whereType<ListBlock>().first;
    expect(list.items, isNotEmpty, reason: '结构未在回车中丢失');
  });

  testWidgets('非列表行回车：行为零变更（照旧拆段）', (tester) async {
    final state = await pump(tester, const [['t', '普通']]);
    await tester.enterText(find.byType(TextField).first, '普通\n');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2);
    expect(textSeg(state).spans.plain, '普通');
    expect(textSeg(state, 1).spans.plain, isEmpty);
  });

  testWidgets('多行粘贴：仍逐行拆段（列表粘贴不被误并为一段）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await tester.enterText(find.byType(TextField).first, '- 甲\n- 乙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2, reason: '粘贴走既有拆段口径，与本次改动无关');
    expect(serializeTextTruthSpans(textSeg(state).spans), '- 甲');
    expect(serializeTextTruthSpans(textSeg(state, 1).spans), '- 乙');
  });
}
