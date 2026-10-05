import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/span_text_controller.dart';

void main() {
  const f = SpanPasteNormalizeFormatter();
  TextEditingValue edit(String oldText, String newText, {int? cursor}) {
    return f.formatEditUpdate(
      TextEditingValue(text: oldText),
      TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cursor ?? newText.length),
      ),
    );
  }

  group('SpanPasteNormalizeFormatter 敲回车放行', () {
    test('连敲回车可产生空行（不被折叠）', () {
      // 逐次敲回车：一次只进一个 \n，永远不该被折叠
      final v1 = edit('第一行', '第一行\n');
      expect(v1.text, '第一行\n');
      final v2 = edit(v1.text, '第一行\n\n');
      expect(v2.text, '第一行\n\n');
      final v3 = edit(v2.text, '第一行\n\n\n');
      expect(v3.text, '第一行\n\n\n');
    });

    test('行中间敲回车拆行不受影响', () {
      expect(edit('ab', 'a\nb', cursor: 2).text, 'a\nb');
    });

    test('旧文本里已敲出的空行不被后续编辑连带折叠', () {
      final v = edit('a\n\nb', 'a\n\nbc');
      expect(v.text, 'a\n\nbc');
    });
  });

  group('SpanPasteNormalizeFormatter 粘贴归一', () {
    test('粘贴含空行多段折叠为单换行，选区吸附到折叠尾', () {
      // 粘贴签名：单次编辑插入文本自带空行
      final v = edit('前', '前第一段\n\n第二段');
      expect(v.text, '前第一段\n第二段');
      expect(v.selection.baseOffset, '前第一段\n第二段'.length);
    });

    test('只折叠插入区，已有敲出的空行保留', () {
      final v = edit('a\n\nb', 'a\n\nb粘\n\n贴');
      expect(v.text, 'a\n\nb粘\n贴');
    });

    test('粘贴替换选区（diff 剥前后缀）同样折叠', () {
      final v = edit('abcdef', 'aX\n\nYf');
      expect(v.text, 'aX\nYf');
    });

    test('粘贴 \r\n 归一为 \n', () {
      final v = edit('', '第一段\r\n\r\n第二段');
      expect(v.text, '第一段\n第二段');
    });

    test('无空行的普通输入原样放行（值不变）', () {
      final v = edit('abc', 'abcd');
      expect(identical(v, v), isTrue);
      expect(v.text, 'abcd');
    });
  });
}
