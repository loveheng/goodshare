import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rich_text/markdown_subset.dart'
    show InlineMark, InlineRun, adjustRuns;
import 'package:goodshare/share/quick_note_span_codec.dart';
import 'package:goodshare/share/quick_note_text_actions.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:goodshare/ui/span_text_controller.dart';

/// 击键路径性能基准（输入阻碍审计 P2 防线）：10k 字符段上模拟连续击键，
/// 量测「输入随动 + 渲染合成 + 草稿序列化」三段耗时。上限断言从宽（CI 机器
/// 差异），print 数字用于优化前后对比——收紧阈值须以本机两次测量为据。
void main() {
  const segLen = 10000;
  const keystrokes = 50;

  QuickNoteSpans bigSeg() {
    final s = seedTextTruth('字' * segLen);
    s.runs
      ..add(const InlineRun(0, 500, InlineMark.bold))
      ..add(InlineRun(segLen - 500, segLen, InlineMark.italic));
    return s;
  }

  test('基准①输入随动：adjustRuns + deriveLineRuns × $keystrokes @10k 字符',
      () {
    final s = bigSeg();
    final sw = Stopwatch()..start();
    for (var i = 0; i < keystrokes; i++) {
      // 现役击键路径（编辑器 _syncSegFromCtrl）：行内 runs 字符级随动 +
      // 行级身份整段重派生——后者是文本真相下的新增成本，必须量进基准。
      final at = s.plain.length;
      s.runs = adjustRuns(s.runs, at, at, 1);
      s.plain = '${s.plain}字';
      deriveLineRuns(s);
    }
    sw.stop();
    // ignore: avoid_print
    print('BENCH syncSegFromCtrl: '
        '${(sw.elapsedMicroseconds / keystrokes).toStringAsFixed(1)}us/击键');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });

  testWidgets('基准②渲染合成：buildSpanTextSpan × $keystrokes @10k 字符',
      (tester) async {
    final spans = bigSeg();
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    final ctrl = SpanTextEditingController(
      text: spans.plain,
      runsProvider: () => spans.runs,
      levelRunsProvider: () => spans.levelRuns,
    );
    final sw = Stopwatch()..start();
    for (var i = 0; i < keystrokes; i++) {
      ctrl.buildTextSpan(context: ctx, style: null, withComposing: false);
    }
    sw.stop();
    // ignore: avoid_print
    print('BENCH buildSpanTextSpan: '
        '${(sw.elapsedMicroseconds / keystrokes).toStringAsFixed(1)}us/击键');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('基准③草稿序列化：noteSegsToDraftRows × $keystrokes @10k 单段', () {
    final segs = <NoteSeg>[NoteTextSeg('字' * segLen)];
    final sw = Stopwatch()..start();
    for (var i = 0; i < keystrokes; i++) {
      noteSegsToDraftRows(segs);
    }
    sw.stop();
    // ignore: avoid_print
    print('BENCH noteSegsToDraftRows: '
        '${(sw.elapsedMicroseconds / keystrokes).toStringAsFixed(1)}us/次');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
