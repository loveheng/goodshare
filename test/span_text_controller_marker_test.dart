import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/span_text_controller.dart'
    show SpanTextEditingController;

// 标记区显隐判据回归（S1 显示变换）：「buffer 含标记、display 看不见」的
// 单一判据点。2026-10-08 拍板标题与列表同口径走透明隐藏（中困惑 #G 淡显废弃）。
void main() {
  (List<(int, int)>, List<(int, int)>) ranges(String text, int caret) =>
      SpanTextEditingController.hiddenMarkerRangesFor(text, caret);

  group('标记区显隐判据', () {
    test('标题行（有正文、光标在正文区）：标记进 hidden，faint 恒空', () {
      final (hidden, faint) = ranges('# 甲', 3);
      expect(hidden, const [(0, 2)]);
      expect(faint, isEmpty); // 2026-10-08：标题不再淡显
    });

    test('列表行：标记进 hidden（与标题同口径）', () {
      final (hidden, faint) = ranges('- 甲', 3);
      expect(hidden, const [(0, 2)]);
      expect(faint, isEmpty);
    });

    test('待办行：整段 `- [ ] ` 标记区进 hidden', () {
      final (hidden, faint) = ranges('- [ ] 甲', 7);
      expect(hidden, const [(0, 6)]);
      expect(faint, isEmpty);
    });

    test('引用行：标记进 hidden', () {
      final (hidden, faint) = ranges('> 甲', 3);
      expect(hidden, const [(0, 2)]);
      expect(faint, isEmpty);
    });

    test('空标题行（标记后无正文）：恒显不隐藏（防看不见/点不到/删不掉）', () {
      final (hidden, faint) = ranges('# ', 2);
      expect(hidden, isEmpty);
      expect(faint, isEmpty);
    });

    test('多行：光标在别行时，标题行标记仍隐藏', () {
      final (hidden, faint) = ranges('# 甲\n乙', 5);
      expect(hidden, const [(0, 2)]); // 仅标题行有标记
      expect(faint, isEmpty);
    });

    test('纯文本行：无任何显隐区间', () {
      final (hidden, faint) = ranges('甲乙', 2);
      expect(hidden, isEmpty);
      expect(faint, isEmpty);
    });
  });
}
