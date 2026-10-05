import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 粘贴拆段策略（回车拆块拍板的粘贴侧，block-format-input.md §7.1）回归：
/// 多段（空行分隔）逐段拆块、段中粘贴两侧分裂、尾随换行、CRLF 归一、
/// 单行不拆。
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

  /// 模拟粘贴：光标塌缩在段首（arrowLeft 循环归零），替换整段文本——
  /// 与真机粘贴同路（IME updateEditingValue → onChanged）。
  Future<void> pasteAtStart(
    WidgetTester tester,
    NoteComposerEditorState state,
    int i,
    String content,
  ) async {
    final seg = state.segs[i] as NoteTextSeg;
    seg.focus.requestFocus();
    await tester.pump();
    for (var k = 0; k < 32; k++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(i), content);
    await tester.pumpAndSettle();
  }

  testWidgets('多段粘贴（空行分隔）：逐段拆块，段内不残留 \\n', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await pasteAtStart(tester, state, 0, '第一段\n\n第二段\n\n第三段');

    expect(state.segs.length, 3);
    expect(textOf(state), '第一段');
    expect(textOf(state, 1), '第二段');
    expect(textOf(state, 2), '第三段');
  });

  testWidgets('段中粘贴：两侧文本分裂到各自段', (tester) async {
    final state = await pump(tester, const [['t', '前|后']]);
    // 光标定位到 | 处：enterText 整段替换模拟「前A\nB后」的粘贴结果
    await tester.enterText(find.byType(TextField).first, '前A\nB后');
    await tester.pumpAndSettle();

    expect(state.segs.length, 2);
    expect(textOf(state), '前A');
    expect(textOf(state, 1), 'B后');
  });

  testWidgets('尾随换行粘贴：末尾产生空段边界（保存时折叠）', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await pasteAtStart(tester, state, 0, '内容\n');

    expect(state.segs.length, 2);
    expect(textOf(state), '内容');
    expect(textOf(state, 1), isEmpty);
  });

  testWidgets('CRLF 粘贴：\\r 归一无残留，逐行拆段', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await pasteAtStart(tester, state, 0, '一段\r\n二段\r\n\r\n三段');

    expect(state.segs.length, 3);
    expect(textOf(state), '一段');
    expect(textOf(state, 1), '二段');
    expect(textOf(state, 2), '三段');
    expect(
      state.segs.every((s) => s is! NoteTextSeg || !s.spans.plain.contains('\r')),
      isTrue,
      reason: '无 \\r 杂字符残留',
    );
  });

  testWidgets('单行粘贴：不拆段', (tester) async {
    final state = await pump(tester, const [['t', '']]);
    await pasteAtStart(tester, state, 0, '只是一行');

    expect(state.segs.length, 1);
    expect(textOf(state), '只是一行');
  });
}
