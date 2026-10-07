import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 输入阻碍审计 P3（作曲器侧）回归：
/// ①点正文下方空白 = 聚焦末段并把光标送到文末（此前必须精准点中某一行文字）；
/// ②悬浮球打字退隐——停球位会盖住文字与选择手柄，故打字期不仅要淡出，
///   还必须**不可命中**（IgnorePointer），否则仍吞正文点击与手柄长按。
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

  // 悬浮球是 240ms 淡出的那一个（转盘/滚动条另有 20ms 的 AnimatedOpacity，
  // 只按 opacity 匹配会撞车——用时长收窄到唯一）。
  const hubDuration = Duration(milliseconds: 240);

  Finder hubDimmed() => find.byWidgetPredicate(
    (w) => w is AnimatedOpacity && w.duration == hubDuration && w.opacity == 0.0,
  );

  Finder hubVisible() => find.byWidgetPredicate(
    (w) => w is AnimatedOpacity && w.duration == hubDuration && w.opacity == 1.0,
  );

  Finder hubIgnoring() =>
      find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring);

  testWidgets('打字即退隐：球淡到 0 且不可命中（不压字、不吞手柄）', (tester) async {
    await pump(tester, const [['t', '前']]);
    expect(hubVisible(), findsOneWidget);
    expect(hubIgnoring(), findsNothing);

    await tester.enterText(find.byType(TextField).first, '前言后语');
    await tester.pump();

    expect(hubDimmed(), findsOneWidget);
    expect(hubIgnoring(), findsOneWidget);
  });

  testWidgets('停笔 kHubDimRestoreDelay 后渐显回来（恢复可点）', (tester) async {
    await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前言');
    await tester.pump();
    expect(hubDimmed(), findsOneWidget);

    await tester.pump(kHubDimRestoreDelay + const Duration(milliseconds: 50));
    await tester.pump();

    expect(hubVisible(), findsOneWidget);
    expect(hubIgnoring(), findsNothing);
  });

  testWidgets('失焦立即恢复常显（不等停笔窗口）', (tester) async {
    await pump(tester, const [['t', '前']]);
    await tester.enterText(find.byType(TextField).first, '前言');
    await tester.pump();
    expect(hubDimmed(), findsOneWidget);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();

    expect(hubVisible(), findsOneWidget);
  });

  Finder hint() => find.textContaining('格式将作用于之后输入的文字');

  testWidgets('展开转盘：格式口径提示（塌缩=未来输入 / 选区=直接套）', (tester) async {
    final state = await pump(tester, const [['t', '前言后语']]);
    final seg = state.segs.first as NoteTextSeg;

    // 展开转盘 + 塌缩光标：明示「格式将作用于之后输入的文字」（先选后打模型）
    await tester.tap(find.text('Tt'));
    await tester.pumpAndSettle();
    expect(find.text('Tt'), findsNothing, reason: '转盘展开期藏球（确认转盘已展开）');
    expect(hint(), findsOneWidget);

    // 段内划选：选区直接套格式（高困惑 #2 已修复），无需提示 → 收起
    seg.ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();
    expect(hint(), findsNothing);

    // 选区塌缩 → 提示恢复
    seg.ctrl.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(hint(), findsOneWidget);
  });

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
