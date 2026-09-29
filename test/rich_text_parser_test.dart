import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart';

void main() {
  const parser = MarkdownSubsetParser();

  group('块级解析', () {
    test('标题六档', () {
      final blocks = parser.parse('# 一级\n\n###### 六级');
      expect(blocks, hasLength(2));
      final h1 = blocks[0] as HeadingBlock;
      expect(h1.level, 1);
      expect((h1.inline.first as InlineText).text, '一级');
      expect((blocks[1] as HeadingBlock).level, 6);
    });

    test('段落与空行分隔', () {
      final blocks = parser.parse('第一段\n\n第二段');
      expect(blocks, hasLength(2));
      expect(blocks[0], isA<ParagraphBlock>());
      expect(blocks[1], isA<ParagraphBlock>());
    });

    test('单段内软换行保留为一段', () {
      final blocks = parser.parse('第一行\n第二行');
      expect(blocks, hasLength(1));
      final text = (blocks[0] as ParagraphBlock).inline
          .map((n) => n is InlineText ? n.text : '')
          .join();
      expect(text, contains('第一行'));
      expect(text, contains('第二行'));
    });

    test('引用块去标记并递归解析内部', () {
      final blocks = parser.parse('> 引用的话\n> 第二行');
      expect(blocks, hasLength(1));
      final q = blocks[0] as QuoteBlock;
      final flat = q.children.whereType<ParagraphBlock>().toList();
      expect(flat, isNotEmpty);
      final text = flat.first.inline.map((n) => n is InlineText ? n.text : '').join();
      expect(text, contains('引用的话'));
    });

    test('无序列表聚合为一个块', () {
      final blocks = parser.parse('- 甲\n- 乙\n- 丙');
      expect(blocks, hasLength(1));
      final list = blocks[0] as ListBlock;
      expect(list.ordered, isFalse);
      expect(list.items, hasLength(3));
    });

    test('有序列表识别', () {
      final list = parser.parse('1. 第一\n2. 第二').first as ListBlock;
      expect(list.ordered, isTrue);
      expect(list.items, hasLength(2));
    });

    test('待办项标记解析（未完成 / 已完成）', () {
      final list = parser.parse('- [ ] 待办一\n- [x] 已完成').first as ListBlock;
      expect(list.items[0].done, isFalse);
      expect(list.items[1].done, isTrue);
      expect((list.items[0].inline.first as InlineText).text, '待办一');
    });

    test('裸待办行（不在列表里）也能勾选', () {
      final blocks = parser.parse('[ ] 记得买牛奶');
      final list = blocks.first as ListBlock;
      expect(list.items.single.done, isFalse);
    });

    test('代码块原样保留，不解析行内', () {
      final blocks = parser.parse('```dart\n**not bold**\n```');
      final code = blocks.first as CodeBlock;
      expect(code.language, 'dart');
      expect(code.code, '**not bold**');
    });

    test('无语言标记的代码块 language 为 null', () {
      final code = parser.parse('```\nplain\n```').first as CodeBlock;
      expect(code.language, isNull);
      expect(code.code, 'plain');
    });

    test('分隔线', () {
      expect(parser.parse('---').first, isA<DividerBlock>());
    });

    test('表格等不认识的内容降级为段落且不丢内容', () {
      final blocks = parser.parse('| a | b |\n| --- | --- |');
      expect(blocks, isNotEmpty);
      final all = blocks.map(_plainOf).join();
      expect(all, contains('| a | b |'));
    });

    test('空输入不炸', () {
      expect(parser.parse(''), isEmpty);
      expect(parser.parse('\n\n\n'), isEmpty);
    });

    test('未闭合围栏不抛异常且保留内容', () {
      final blocks = parser.parse('```\n未闭合');
      expect(blocks, isNotEmpty);
      expect(blocks.map(_plainOf).join(), contains('未闭合'));
    });
  });

  group('行内解析', () {
    test('粗体优先于斜体', () {
      final nodes = parser.parseInline('这是**粗体**文本');
      expect(nodes.whereType<InlineStrong>(), hasLength(1));
      final strong = nodes.whereType<InlineStrong>().single;
      expect((strong.children.single as InlineText).text, '粗体');
    });

    test('斜体', () {
      final nodes = parser.parseInline('这是*斜体*');
      final em = nodes.whereType<InlineEm>().single;
      expect((em.children.single as InlineText).text, '斜体');
    });

    test('行内码', () {
      final nodes = parser.parseInline('用 `dart` 写');
      expect((nodes.whereType<InlineCode>().single).code, 'dart');
    });

    test('链接', () {
      final nodes = parser.parseInline('见[官网](https://a.com)');
      final link = nodes.whereType<InlineLink>().single;
      expect(link.label, '官网');
      expect(link.url, 'https://a.com');
    });

    test('混合行内且文本不丢', () {
      final text = _inlineText(parser.parseInline('前 **粗** 中 `码` 后'));
      expect(text, '前 粗 中 码 后');
    });

    test('无标记时退化为单个文本节点', () {
      final nodes = parser.parseInline('纯文本');
      expect(nodes, hasLength(1));
      expect(nodes.single, isA<InlineText>());
    });

    test('未闭合粗体不作为标记（原样保留）', () {
      final nodes = parser.parseInline('星号*没闭合');
      expect(nodes.whereType<InlineEm>(), isEmpty);
      expect(_inlineText(nodes), '星号*没闭合');
    });
  });
}

/// 块 → 纯文本（测试辅助）。
String _plainOf(RichBlock b) => switch (b) {
      HeadingBlock(:final inline) => _inlineText(inline),
      ParagraphBlock(:final inline) => _inlineText(inline),
      QuoteBlock(:final children) => children.map(_plainOf).join(),
      ListBlock(:final items) => items.map((i) => _inlineText(i.inline)).join(),
      CodeBlock(:final code) => code,
      DividerBlock() => '',
    };

String _inlineText(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => text,
      InlineStrong(:final children) => _inlineText(children),
      InlineEm(:final children) => _inlineText(children),
      InlineCode(:final code) => code,
      InlineLink(:final label) => label,
    }).join();
