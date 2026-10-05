import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 快照制撤销/重做（输入阻碍审计 P1-2）回归：文字连击合并、结构操作独立
/// 步、redo 语义、恢复后光标落点。
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

  /// 按钮定位用图标（byTooltip 会命中 Tooltip 浮层而非 IconButton 本体）。
  IconButton undoBtn(WidgetTester t) => t.widget<IconButton>(
        find
            .ancestor(
              of: find.byIcon(Icons.undo_outlined),
              matching: find.byType(IconButton),
            )
            .first,
      );

  IconButton redoBtn(WidgetTester t) => t.widget<IconButton>(
        find
            .ancestor(
              of: find.byIcon(Icons.redo_outlined),
              matching: find.byType(IconButton),
            )
            .first,
      );

  testWidgets('初始态：撤销/重做按钮均禁用', (tester) async {
    await pump(tester, const [['t', '前']]);
    expect(undoBtn(tester).onPressed, isNull);
    expect(redoBtn(tester).onPressed, isNull);
  });

  testWidgets('打字后撤销回到初始文本，光标落恢复点', (tester) async {
    final state = await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前言后语');
    await tester.pump();
    expect(textOf(state), '前言后语');

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pump();
    expect(textOf(state), '前');
    // 初始快照时无焦点（enterText 不聚焦）→ 恢复光标=0
    expect((state.segs[0] as NoteTextSeg).ctrl.selection.extentOffset, 0);
  });

  testWidgets('连击合并：合并窗内的连续输入只记一步', (tester) async {
    final state = await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前言');
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '前言后语');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pump();
    expect(textOf(state), '前', reason: '两步打字合并为一步撤销');
    expect(
      undoBtn(tester).onPressed,
      isNull,
      reason: '初始态即栈底，再无可撤销',
    );
  });

  testWidgets('结构操作：段首退格合并后撤销恢复两段', (tester) async {
    final state = await pump(tester, const [
      ['t', '第一段'],
      ['t', '第二段'],
    ]);
    final seg = state.segs[1] as NoteTextSeg;
    seg.focus.requestFocus();
    await tester.pump();
    for (var k = 0; k < 32; k++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(state.segs.length, 1);

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pumpAndSettle(); // 焦点请求挂 postFrame，settle 推进到位
    expect(state.segs.length, 2);
    expect(textOf(state), '第一段');
    expect(textOf(state, 1), '第二段');
    // 撤销恢复焦点段/光标：退格时刻焦点在第二段段首 → 恢复后仍在该位
    final restored = state.segs[1] as NoteTextSeg;
    expect(restored.focus.hasFocus, isTrue);
    expect(restored.ctrl.selection.extentOffset, 0);
  });

  testWidgets('撤销后重做恢复，重做后撤销再回', (tester) async {
    final state = await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前言');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pump();
    expect(textOf(state), '前');

    await tester.tap(find.byIcon(Icons.redo_outlined));
    await tester.pump();
    expect(textOf(state), '前言');

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pump();
    expect(textOf(state), '前');
  });

  testWidgets('撤销后新输入清空重做栈', (tester) async {
    final state = await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前言');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pump();

    expect(redoBtn(tester).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField).first, '新内容');
    await tester.pump();
    expect(
      redoBtn(tester).onPressed,
      isNull,
      reason: '撤销后打字=新分支，重做栈必须清空',
    );

    // 新分支打字后撤销只回一步（不会窜进旧分支的「前言」）
    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pump();
    expect(textOf(state), '前');
  });
}
