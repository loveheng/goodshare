import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/doc/rich_text.dart' show InlineMark, InlineRun;
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 段首退格跨段合并（输入阻碍审计 P1-1）回归。
///
/// 键序模拟真实路径：requestFocus 落段 → arrowLeft 移光标到段首（框架原生
/// 处理）→ backspace（Android 嵌入层对「删无可删」转发平台键事件，与真机
/// 软键盘同路）。
void main() {
  late Directory tmp;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('composer_backspace_test');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<NoteComposerEditorState> pump(
    WidgetTester tester,
    List<List<String>> rows,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: NoteComposerEditor(initialRows: rows),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(NoteComposerEditor))
        as NoteComposerEditorState;
  }

  /// 聚焦第 i 段并把光标塌缩到段首。
  Future<void> focusAtStart(
    WidgetTester tester,
    NoteComposerEditorState state,
    int i,
  ) async {
    final seg = state.segs[i] as NoteTextSeg;
    seg.focus.requestFocus();
    await tester.pump();
    // 聚焦后光标在段尾：循环左移到段首（超出长度自动钳在 0）
    for (var k = 0; k < 32; k++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.pump();
    expect(
      seg.ctrl.selection.isCollapsed && seg.ctrl.selection.extentOffset == 0,
      isTrue,
      reason: '前置：光标已在段首',
    );
  }

  testWidgets('段首退格：并入上一文本段，光标落合并点', (tester) async {
    final state = await pump(tester, const [
      ['t', '第一段'],
      ['t', '第二段'],
    ]);
    await focusAtStart(tester, state, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(state.segs.length, 1);
    final merged = state.segs.single as NoteTextSeg;
    expect(merged.spans.plain, '第一段第二段');
    expect(
      merged.ctrl.selection.extentOffset,
      '第一段第二段'.length,
      reason: '光标落合并点（原段首位置）',
    );
  });

  testWidgets('段首退格：runs 随段平移拼接（样式零丢失）', (tester) async {
    final state = await pump(tester, const [
      ['t', '第一段'],
      ['t', '第二段'],
    ]);
    final b = state.segs[1] as NoteTextSeg;
    b.spans.runs.add(const InlineRun(0, 3, InlineMark.bold));
    await focusAtStart(tester, state, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    final merged = state.segs.single as NoteTextSeg;
    expect(
      merged.spans.runs.map((r) => '${r.start}:${r.end}'),
      contains('3:6'),
      reason: '原段 [0,3) 的 run 平移到合并后坐标 [3,6)',
    );
  });

  testWidgets('非段首退格不拦截（段内原生删除）', (tester) async {
    final state = await pump(tester, const [
      ['t', '第一段'],
      ['t', '第二段'],
    ]);
    final seg = state.segs[1] as NoteTextSeg;
    seg.focus.requestFocus();
    await tester.pump();
    // 光标在末尾（默认）：原生删除删「段」字，不触发跨段
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(state.segs.length, 2);
    expect(seg.spans.plain, '第二');
  });

  testWidgets('首段段首退格：无处可并，原样放行', (tester) async {
    final state = await pump(tester, const [
      ['t', '第一段'],
      ['t', '第二段'],
    ]);
    await focusAtStart(tester, state, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(state.segs.length, 2);
    expect((state.segs[0] as NoteTextSeg).spans.plain, '第一段');
  });

  testWidgets('上一段是媒体卡：不拦截（无 undo 前退格不删媒体）', (tester) async {
    final img = File('${tmp.path}/x.jpg')..writeAsBytesSync(<int>[0, 1]);
    final state = await pump(tester, [
      ['t', '前'],
      ['i', img.path],
      ['t', '后'],
    ]);
    await focusAtStart(tester, state, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(state.segs.length, 3, reason: '媒体卡与文本段结构不变');
  });

  testWidgets('空段段首退格：并入上一段（退格删掉空段）', (tester) async {
    final state = await pump(tester, const [
      ['t', '前'],
      ['t', ''],
    ]);
    await focusAtStart(tester, state, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(state.segs.length, 1);
    expect((state.segs.single as NoteTextSeg).spans.plain, '前');
  });
}
