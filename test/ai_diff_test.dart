import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/ai_diff.dart';

/// Inline Diff 纯函数单测（ai-writeback-revert §7）。
void main() {
  group('computeAiDiff 基础', () {
    test('两侧完全一致：无差异、概览明说「与你的版本一致」', () {
      final r = computeAiDiff(before: 'a\nb\nc', after: 'a\nb\nc');
      expect(r.hasDiff, isFalse);
      expect(r.firstDiff, -1);
      expect(r.summary, '与你的版本一致');
      expect(r.added, 0);
      expect(r.deleted, 0);
    });

    test('纯新增一行：只有 insert 行，统计只记新增', () {
      final r = computeAiDiff(before: 'a\nb', after: 'a\nb\nc');
      expect(r.hasDiff, isTrue);
      expect(r.firstDiff, 2);
      expect(r.lines[2].kind, DiffKind.insert);
      expect(r.lines[2].spans.single.text, 'c');
      expect(r.added, 1);
      expect(r.deleted, 0);
    });

    test('纯删除一行：只有 delete 行，统计只记删除', () {
      final r = computeAiDiff(before: 'a\nb\nc', after: 'a\nc');
      expect(r.lines[1].kind, DiffKind.delete);
      expect(r.deleted, 1);
      expect(r.added, 0);
      expect(r.summary, '新增 0 字 · 删除 1 字');
    });

    test('改一行 = 成对的一删一增，行内只标真正动过的部分', () {
      final r = computeAiDiff(before: 'hello', after: 'hello world');
      final del = r.lines.where((l) => l.kind == DiffKind.delete).single;
      final ins = r.lines.where((l) => l.kind == DiffKind.insert).single;
      // 两侧都保留未改动的 "hello"，只把新增片段标成 insert
      expect(del.spans.any((s) => s.kind == DiffKind.equal), isTrue);
      expect(
        ins.spans.where((s) => s.kind == DiffKind.insert).map((s) => s.text).join(),
        contains('world'),
      );
      expect(r.added, greaterThan(0));
    });
  });

  group('中文与词元切分', () {
    test('中文按字切分：改一个字只标那一个字', () {
      final r = computeAiDiff(before: '你好世界', after: '你们好世界');
      final ins = r.lines.where((l) => l.kind == DiffKind.insert).single;
      final changed = ins.spans
          .where((s) => s.kind == DiffKind.insert)
          .map((s) => s.text)
          .join();
      expect(changed, '们');
    });

    test('多行中文：差异行下标可定位（供自动滚动到首个差异）', () {
      final r = computeAiDiff(before: '第一段\n第二段\n第三段', after: '第一段\n第二段改了\n第三段');
      expect(r.firstDiff, 1);
      expect(r.lines[1].kind, DiffKind.delete);
    });
  });

  group('性能防线', () {
    test('超阈值退化为粗粒度 diff：不卡死、仍给出结果', () {
      // 600×600 = 360000 > _kLcsCellCap(250000) → 走公共前后缀裁剪路径
      final before = List.generate(600, (i) => 'line $i').join('\n');
      final after = List.generate(600, (i) => i == 300 ? 'changed' : 'line $i')
          .join('\n');
      final r = computeAiDiff(before: before, after: after);
      expect(r.hasDiff, isTrue);
      expect(r.firstDiff, 300);
    });

    test('空文本不炸', () {
      final r = computeAiDiff(before: '', after: 'x');
      expect(r.hasDiff, isTrue);
    });
  });
}
