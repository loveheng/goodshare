import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart' show SpanListKind;
import 'package:goodshare/share/quick_note_line_shape.dart';
import 'package:goodshare/share/quick_note_span_codec.dart' show seedQuickNote;

/// S0 `parseLine` 单行纯解析原语单测（note-editor-source-of-truth.md §6 S0）。
///
/// 验收口径：与既有正则同口径（codec `_headingRe`/`_listRe` 迁入前行为），
/// 覆盖标记行 / 非标记行 / 边界行三类。
void main() {
  group('标题行（headingRe：^(#{1,6})\\s+）', () {
    test('一至六级全部识别，档位 = # 个数', () {
      for (var i = 1; i <= 6; i++) {
        final s = parseLine('${'#' * i} 甲');
        expect(s.isHeading, isTrue, reason: '#$i 应识别为标题');
        expect(s.level, i);
        expect(s.markerEnd, i + 1, reason: '标记区末端 = #串 + 单空格');
      }
    });

    test('七级 # 不是标题（降级正文/列表口径）', () {
      final s = parseLine('####### 甲');
      expect(s.isHeading, isFalse);
    });

    test('无空格的 # 不是标题（#甲 走正文）', () {
      final s = parseLine('#甲');
      expect(s.isHeading, isFalse);
      expect(s.isPlain, isTrue);
    });

    test('正文中的 #（非行首）不是标题', () {
      final s = parseLine('甲 #乙');
      expect(s.isPlain, isTrue);
    });
  });

  group('无序列表（[-*] + 空白）', () {
    test('- 与 * 均识别为 bullet', () {
      for (final mk in ['- 甲', '* 甲']) {
        final s = parseLine(mk);
        expect(s.isList, isTrue);
        expect(s.listKind, SpanListKind.bullet);
        expect(s.markerEnd, 2);
        expect(s.bodyOf(mk), '甲');
      }
    });

    test('+ 不是 bullet（与解析器 _bullet [-*] 同口径，不含 +）', () {
      final s = parseLine('+ 甲');
      expect(s.isList, isFalse, reason: 'codec _listRe 只认 [-*]');
    });

    test('空列表项 - 后无正文：markerEnd 吞尾随空白，body 为空', () {
      final s = parseLine('- ');
      expect(s.isList, isTrue);
      expect(s.markerEnd, 2);
      expect(s.bodyOf('- '), '');
    });
  });

  group('有序列表（数字 + [.)] + 空白）', () {
    test('1. 与 1) 均识别为 ordered', () {
      for (final mk in ['12. 甲', '3) 甲']) {
        final s = parseLine(mk);
        expect(s.isList, isTrue);
        expect(s.listKind, SpanListKind.ordered);
      }
    });

    test('数字后无 . 或 ) 不是有序项', () {
      final s = parseLine('12 甲');
      expect(s.isList, isFalse);
    });
  });

  group('待办（勾选框）', () {
    test('- [ ] 未勾 / - [x] 已勾 / - [X] 大写已勾', () {
      expect(parseLine('- [ ] 甲').listKind, SpanListKind.todo);
      expect(parseLine('- [ ] 甲').done, isFalse);
      expect(parseLine('- [x] 甲').done, isTrue);
      expect(parseLine('- [X] 甲').done, isTrue);
    });

    test('裸勾选框（无 - 前缀）识别为 todo（2026-10-07 裸写拍板）', () {
      final s = parseLine('[ ] 甲');
      expect(s.isList, isTrue);
      expect(s.listKind, SpanListKind.todo);
      expect(s.done, isFalse);
      expect(s.bodyOf('[ ] 甲'), '甲');
    });

    test('混合写法 1. [ ] 甲 取待办（勾选框 > 有序 优先级）', () {
      final s = parseLine('1. [ ] 甲');
      expect(s.listKind, SpanListKind.todo);
    });
  });

  group('非标记行与边界', () {
    test('普通正文、空串、缩进正文 → plain，markerEnd=0', () {
      for (final line in ['甲乙丙', '', '  甲', '> 引用', '---', '```dart']) {
        final s = parseLine(line);
        expect(s.isPlain, isTrue, reason: '"$line" 应为 plain');
        expect(s.markerEnd, 0);
        expect(s.bodyOf(line), line);
      }
    });

    test('引用/代码块/分隔线本版不认（S4 扩 kind），落 plain', () {
      expect(parseLine('> 甲').isPlain, isTrue);
      expect(parseLine('```').isPlain, isTrue);
      expect(parseLine('***').isPlain, isTrue);
    });

    test('标题与列表互斥：标题优先（# 后带 - 前缀内容仍归标题）', () {
      final s = parseLine('# - 甲');
      expect(s.isHeading, isTrue);
      expect(s.level, 1);
    });

    test('纯函数性：同输入两次求值结果一致', () {
      const line = '- [x] 甲';
      final a = parseLine(line);
      final b = parseLine(line);
      expect(a.kind, b.kind);
      expect(a.markerEnd, b.markerEnd);
      expect(a.done, b.done);
    });
  });

  group('与 codec 同口径（迁移零漂移回归）', () {
    test('parseLine 的 markerEnd 与 listMarkerOf 的 end 一致', () {
      for (final line in ['- 甲', '* [x] 乙', '2) 丙', '[ ] 丁', '- ']) {
        final shape = parseLine(line);
        final marker = listMarkerOf(line)!;
        expect(shape.markerEnd, marker.end, reason: line);
      }
    });

    test('seedQuickNote 的列表/标题剥离长度与 parseLine.markerEnd 一致', () {
      // codec 播种（迁移后走同一正则）与 parseLine 必须同口径——防迁移漂移。
      for (final line in ['# 甲', '- 乙', '- [x] 丙', '3) 丁']) {
        final shape = parseLine(line);
        final body = line.substring(shape.markerEnd);
        // 剥完后的剩余内容即正文：播种后 plain 的该行应等于 body
        final seeded = seedQuickNote(line);
        expect(seeded.plain, body, reason: '"$line" 播种剥离口径应一致');
      }
    });
  });
}
