import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/share/quick_note_span_codec.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回车拆块（2026-10-04 拍板：Enter=新块 / Shift+Enter=块内软换行 / 空块
/// 保存折叠）回归：软键盘路径（文本变更含 \n）、物理 Shift+Enter、多行
/// 粘贴拆段、undo 连击。
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

  String textOf(NoteComposerEditorState state, [int i = 0]) =>
      (state.segs[i] as NoteTextSeg).spans.plain;

  testWidgets('软键盘回车：文本变更含 \\n → 拆为两段，焦点落尾段', (tester) async {
    final state = await pump(tester, const [['t', '前半']]);
    // 软键盘口径：IME 提交「\n后半」的文本变更（无按键事件可依）
    await tester.enterText(find.byType(TextField).first, '前半\n后半');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2);
    expect(textOf(state), '前半');
    expect(textOf(state, 1), '后半');
    final tail = state.segs[1] as NoteTextSeg;
    expect(tail.focus.hasFocus, isTrue);
    expect(tail.ctrl.selection.extentOffset, '后半'.length);
  });

  testWidgets('回车在段首/空段：产生空段边界（会话内可敲出空行）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await tester.enterText(find.byType(TextField).first, '\n');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2, reason: '空段+回车=两个空段（会话内空行）');
    expect(textOf(state), isEmpty);
    expect(textOf(state, 1), isEmpty);
  });

  testWidgets('多行粘贴：逐行拆段，行内不残留 \\n（粘贴结构保全）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await tester.enterText(find.byType(TextField).first, '一段\n二段\n三段');
    await tester.pumpAndSettle();

    expect(state.segs.length, 3);
    expect(textOf(state), '一段');
    expect(textOf(state, 1), '二段');
    expect(textOf(state, 2), '三段');
  });

  testWidgets('Shift+Enter 软换行不拆段；随后回车照常拆段', (tester) async {
    final state = await pump(tester, const [['t', '行一']]);
    final seg = state.segs[0] as NoteTextSeg;
    seg.focus.requestFocus();
    await tester.pump();
    // 软换行：按住 Shift 敲回车
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(state.segs.length, 1, reason: 'Shift+Enter 不拆段');
    expect(textOf(state), '行一\n');
    // 段内软换行上再敲普通回车：真机走 IME（与软键盘同路）→ 文本变更含
    // \n → 在插点拆段；测试用文本路径驱动（sendKeyEvent 不产生 IME 变更）
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.enterText(find.byType(TextField).first, '行一\n\n尾');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2, reason: '无修饰回车拆段');
    expect(textOf(state), '行一\n', reason: '软换行留在上段');
    expect(textOf(state, 1), '尾');
  });

  testWidgets('回车拆段并入打字连击：连打带敲回车=一步撤销', (tester) async {
    final state = await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前中');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '前中\n后');
    await tester.pumpAndSettle();
    expect(state.segs.length, 2);

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pumpAndSettle();
    expect(textOf(state), '前', reason: '打字+回车连击合并为一步撤销');
    expect(state.segs.length, 1);
  });

  testWidgets('标题档位随拆段留上侧：标题行回车后新段回正文', (tester) async {
    final state = await pump(tester, const [['t', '标题']]);
    final seg = state.segs[0] as NoteTextSeg;
    seg.focus.requestFocus();
    await tester.pump();
    setQuickNoteLevel(seg.spans, 1, caret: 2);
    await tester.pumpAndSettle();

    // 在标题行末尾回车 → 标题档留上段，新段回正文档
    await tester.enterText(find.byType(TextField).first, '标题\n正文');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2);
    expect(
      (state.segs[0] as NoteTextSeg).spans.levelRuns.map((r) => r.level),
      contains(1),
      reason: '标题档留上侧',
    );
    expect(
      (state.segs[1] as NoteTextSeg).spans.levelRuns,
      isEmpty,
      reason: '新段回正文档（换行熄灭语义）',
    );
  });
}
