import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/item_normalizer.dart';
import 'package:goodshare/doc/normalizer.dart';

void main() {
  const n = ItemDocNormalizer();

  NormalizedDoc doc(NormalizeMeta meta) =>
      NormalizedDoc(markdown: '# 标题\n\n正文', meta: meta);

  group('归一化落库', () {
    test('富文本写 human_md，元信息写 doc_meta_json', () {
      final fields = n.fieldsFor(doc(const NormalizeMeta(chars: 120)));
      expect(fields['human_md'], contains('# 标题'));
      final meta = jsonDecode(fields['doc_meta_json'] as String) as Map;
      expect(meta['chars'], 120);
      expect(meta['truncated'], isFalse);
    });

    test('不新增列：字段只有 human_md 与 doc_meta_json', () {
      expect(n.fieldsFor(doc(const NormalizeMeta(chars: 1))).keys.toSet(),
          {'human_md', 'doc_meta_json'});
    });
  });

  group('分级确认', () {
    test('转换干净 → 静默，不打扰', () {
      expect(n.needsConfirmation(doc(const NormalizeMeta(chars: 500))), isFalse);
    });

    test('截断 → 需确认', () {
      expect(
        n.needsConfirmation(doc(const NormalizeMeta(chars: 1, truncated: true))),
        isTrue,
      );
    });

    test('有降级块 → 需确认', () {
      expect(
        n.needsConfirmation(
            doc(const NormalizeMeta(chars: 1, degradedBlocks: 3))),
        isTrue,
      );
    });

    test('带 note（失败/降级原因）→ 需确认', () {
      expect(
        n.needsConfirmation(
            doc(const NormalizeMeta(chars: 1, note: '页面无正文'))),
        isTrue,
      );
    });
  });

  group('覆盖率文案', () {
    test('干净时只给字数', () {
      expect(n.coverageText(const NormalizeMeta(chars: 8432)), '共提取 8432 字');
    });

    test('降级与截断都说明', () {
      final text = n.coverageText(
        const NormalizeMeta(chars: 100, degradedBlocks: 3, truncated: true),
      );
      expect(text, contains('3 处结构已降级为纯文本'));
      expect(text, contains('超出上限已截断'));
    });

    test('note 原样带出（不自行编造兜底文案）', () {
      expect(
        n.coverageText(const NormalizeMeta(chars: 1, note: '页面无正文')),
        contains('页面无正文'),
      );
    });
  });

  test('确认后写回 confirmed 与时间戳', () {
    final meta = n.confirmedMetaJson(const NormalizeMeta(chars: 10));
    final m = jsonDecode(meta) as Map;
    expect(m['confirmed'], isTrue);
    expect(m['confirmed_at'], isA<int>());
  });
}
