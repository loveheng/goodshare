import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rich_text/markdown_subset.dart' show InlineMark;
import 'package:goodshare/ui/note_composer_editor.dart';

/// 行内格式（B/I）回归：2026-10-08 拍板浮层新增两档，位置在「标题二」之后。
///
/// 语义口径受 pending-confirm D5 约束（格式模型＝**先选后打**）：激活 mark 后
/// 作用于**之后输入**的文字，不做「给已有文字套格式」；**单选制**（B/I 互斥，
/// 新选替换旧选，再点同项关闭）；切换后浮层保持展开（开关型，与档位型区分）。
void main() {
  Future<NoteComposerEditorState> pump(WidgetTester tester, String text) async {
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

  /// 聚焦首段 → 点侧轨角标（正文档徽标 T）拉起贴键浮层。
  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('T'));
    await tester.pumpAndSettle();
  }

  testWidgets('浮层含 B/I 行内档（位于标题二之后）', (tester) async {
    await pump(tester, 'abc');
    await openPanel(tester);
    expect(find.text('B'), findsOneWidget, reason: '行内加粗档存在');
    expect(find.text('I'), findsOneWidget, reason: '行内斜体档存在');
  });

  testWidgets('点 B 后打字：落粗体 run，编辑区无 ** 标记（先选后打）',
      (tester) async {
    final state = await pump(tester, 'abc');
    await openPanel(tester);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'abc重点');
    await tester.pumpAndSettle();

    final seg = state.segs.first as NoteTextSeg;
    expect(
      seg.spans.runs.any((r) => r.mark == InlineMark.bold),
      isTrue,
      reason: '激活 B 后输入的文字必须带 bold run',
    );
    expect(seg.ctrl.text, 'abc重点', reason: '所见即所得：编辑区不得出现 ** 标记');
  });

  testWidgets('单选制：B 激活中再点 I → I 替换 B（不叠加）', (tester) async {
    final state = await pump(tester, 'abc');
    await openPanel(tester);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'abc重点');
    await tester.pumpAndSettle();

    final seg = state.segs.first as NoteTextSeg;
    final marks = {for (final r in seg.spans.runs) r.mark};
    expect(marks, {InlineMark.italic}, reason: '单选制：I 替换 B，不得叠加');
  });

  testWidgets('再点同项关闭：B 点两次即熄灭（之后打字不带 mark）', (tester) async {
    final state = await pump(tester, 'abc');
    await openPanel(tester);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'abc重点');
    await tester.pumpAndSettle();

    final seg = state.segs.first as NoteTextSeg;
    expect(seg.spans.runs, isEmpty, reason: '再点同项 = 关闭，不落任何 mark');
  });
}
