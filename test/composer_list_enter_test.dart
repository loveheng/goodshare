import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/share/quick_note_span_codec.dart';
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

  testWidgets('逐字打 `- 甲`：即时成列表项（标记不在正文可见）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);

    await tester.enterText(find.byType(TextField).first, '-');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '-', reason: '标记未完整（- 后无空格）→ 不落定');
    expect(seg.spans.listRuns, isEmpty);

    await tester.enterText(find.byType(TextField).first, '- ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, isEmpty, reason: '打完 `- ` 即落定为空列表项');
    expect(seg.spans.listRuns.single.kind, SpanListKind.bullet);

    // 之后每敲一个字，run 随行生长（可见文本只是正文）
    await tester.enterText(find.byType(TextField).first, '甲');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '甲');
    expect(seg.spans.listRuns.length, 1);
    expect(seg.spans.listRuns.single.start, 0);
    expect(seg.spans.listRuns.single.end, 1);
    expect(serializeQuickNoteSpans(seg.spans), '- 甲');
  });

  testWidgets('逐字打 `[ ] 甲`：即时成未勾选待办（裸待办也认）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);

    await tester.enterText(find.byType(TextField).first, '[ ] ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, isEmpty);
    expect(seg.spans.listRuns.single.kind, SpanListKind.todo);
    expect(seg.spans.listRuns.single.done, false);

    await tester.enterText(find.byType(TextField).first, '甲');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '甲');
    expect(seg.spans.listRuns.length, 1);
    expect(serializeQuickNoteSpans(seg.spans), '- [ ] 甲');
  });

  testWidgets('列表项行尾回车（物理键盘）：不拆段，就地起新项', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: seg.spans.plain.length);

    expect(state.segs.length, 1, reason: '拆段会把列表切成互不相干的独立段');
    expect(seg.spans.plain, '甲\n');
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].start, 2);
    expect(seg.spans.listRuns[1].end, 2); // 空占位项
    expect(seg.ctrl.selection.extentOffset, 2);
  });

  testWidgets('列表项行尾回车（软键盘/IME 文本变更）：同样不拆段', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    // 软键盘无按键事件可依：IME 提交含 \n 的文本变更（既有 suite 同口径）
    await tester.enterText(find.byType(TextField).first, '甲\n');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.plain, '甲\n');
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].start, 2);
  });

  testWidgets('新项打字：占位 run 存活并贴合整行（序列化出两个列表项）',
      (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: 1);
    await tester.enterText(find.byType(TextField).first, '甲\n乙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.plain, '甲\n乙');
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].start, 2);
    expect(seg.spans.listRuns[1].end, 3);
    expect(serializeQuickNoteSpans(seg.spans), '- 甲\n- 乙');
  });

  testWidgets('连打三个列表项：回车 → 打字序列产出三项 md', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: 1);
    await tester.enterText(find.byType(TextField).first, '甲\n乙');
    await tester.pumpAndSettle();
    await pressEnter(tester, seg, caret: seg.spans.plain.length);
    await tester.enterText(find.byType(TextField).first, '甲\n乙\n丙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.listRuns.length, 3);
    expect(serializeQuickNoteSpans(seg.spans), '- 甲\n- 乙\n- 丙');
  });

  testWidgets('空列表项再回车：退出列表（回到普通段落）', (tester) async {
    final state = await pump(tester, const [['t', '- 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: 1); // 起空新项
    expect(seg.spans.listRuns.length, 2);
    await pressEnter(tester, seg, caret: 2); // 空项上再回车

    expect(state.segs.length, 1);
    expect(seg.spans.plain, '甲\n\n');
    expect(seg.spans.listRuns.length, 1, reason: '占位 run 被摘除——不再是列表项');
    expect(serializeQuickNoteSpans(seg.spans), '- 甲\n\n');
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

  testWidgets('逐字打 `1. 甲`：即时成有序项（序号由凹槽渲染，不进正文）',
      (tester) async {
    final state = await pump(tester, const [['t', '']]);
    final seg = textSeg(state);

    await tester.enterText(find.byType(TextField).first, '1. ');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, isEmpty);
    expect(seg.spans.listRuns.single.kind, SpanListKind.ordered);

    await tester.enterText(find.byType(TextField).first, '甲');
    await tester.pumpAndSettle();
    expect(seg.spans.plain, '甲', reason: '所见即所得：正文里没有 "1."');
    expect(serializeQuickNoteSpans(seg.spans), '1. 甲');
    expect(find.text('1.'), findsOneWidget, reason: '序号画在凹槽里');
  });

  testWidgets('有序项回车：新项同为有序，序号自动续排', (tester) async {
    final state = await pump(tester, const [['t', '1. 甲']]);
    final seg = textSeg(state);
    await pressEnter(tester, seg, caret: 1);
    await tester.enterText(find.byType(TextField).first, '甲\n乙');
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(seg.spans.listRuns.length, 2);
    expect(seg.spans.listRuns[1].kind, SpanListKind.ordered);
    expect(serializeQuickNoteSpans(seg.spans), '1. 甲\n2. 乙');
    expect(find.text('2.'), findsOneWidget);
  });

  testWidgets('多行列表项首行末尾回车：续行过继给新项（不沦为孤儿正文）',
      (tester) async {
    final state = await pump(tester, const [['t', '- 甲\n  续行']]);
    final seg = textSeg(state);
    expect(seg.spans.listRuns.length, 1, reason: '续行不新建 run');

    await pressEnter(tester, seg, caret: 1); // 首行（"甲"）末尾
    final runs = seg.spans.listRuns;
    expect(state.segs.length, 1);
    expect(runs.length, 2);
    expect(runs[0].end, 1, reason: '老项 end 收到本行行尾');
    expect(runs[1].start, 2);
    expect(runs[1].end, seg.spans.plain.length, reason: '续行归入新项');

    final blocks =
        const MarkdownSubsetParser().parse(serializeQuickNoteSpans(seg.spans));
    final list = blocks.single as ListBlock;
    expect(list.items.length, 2, reason: '结构未在回车中丢失');
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
    expect(serializeQuickNoteSpans(textSeg(state).spans), '- 甲');
    expect(serializeQuickNoteSpans(textSeg(state, 1).spans), '- 乙');
  });
}
