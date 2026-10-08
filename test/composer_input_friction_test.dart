import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 输入阻碍审计 P3（作曲器侧）回归：点正文下方空白 = 聚焦末段并把光标送到
/// 文末（此前必须精准点中某一行文字）。
///
/// 2026-10-08 清理：悬浮球退隐 / 渐显 / 失焦恢复 / 转盘展开口径提示 4 条随悬浮球
/// 三级径向盘（format_dial.dart + smart_floating_hub.dart）退役一并删除。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<NoteComposerEditorState> pump(
    WidgetTester tester,
    List<List<String>> rows,
  ) async {
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
    return tester.state(find.byType(NoteComposerEditor)) as NoteComposerEditorState;
  }

  testWidgets('点正文下方空白：聚焦末段并把光标送到文末', (tester) async {
    final state = await pump(tester, const [['t', '前言']]);
    final seg = state.segs.last as NoteTextSeg;
    expect(seg.focus.hasFocus, isFalse);

    // 空白区（正文之外的写作区）：ListView 命中不到，由垫底命中层接住
    await tester.tapAt(const Offset(100, 400));
    await tester.pump();
    await tester.pump();

    expect(seg.focus.hasFocus, isTrue);
    expect(seg.ctrl.selection.extentOffset, seg.spans.plain.length);
  });
}
