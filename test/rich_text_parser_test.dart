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

  group('serialize 往返（rich-text-component.md §7 验收）', () {
    /// 块树 → 规范形字符串（逐节点结构化，比 == 严格）。
    String treeOf(List<RichBlock> blocks) => blocks.map((b) => switch (b) {
          HeadingBlock(:final level, :final inline) =>
            'H$level[${_treeInline(inline)}]',
          ParagraphBlock(:final inline) => 'P[${_treeInline(inline)}]',
          QuoteBlock(:final children) =>
            'Q{${children.map((c) => treeOf([c])).join('|')}}',
          ListBlock(:final ordered, :final items) =>
            '${ordered ? 'OL' : 'UL'}{${items.map((i) => '${i.done == null ? '' : i.done! ? '[x]' : '[ ]'}(${_treeInline(i.inline)})').join(',')}}',
          CodeBlock(:final code, :final language) =>
            'CODE<$language>[$code]',
          DividerBlock() => 'HR',
          ImageBlock(:final url, :final alt) => 'IMG($alt|$url)',
          AudioBlock(:final url, :final label) => 'AUD($label|$url)',
          VideoBlock(:final url, :final label) => 'VID($label|$url)',
        }).join('\n');

    /// parse→serialize→parse 块树逐节点相等（幂等）。
    void expectRoundtrip(String markdown) {
      final first = parser.parse(markdown);
      final md2 = serializeBlocks(first);
      final second = parser.parse(md2);
      expect(treeOf(second), treeOf(first), reason: '往返后块树变化：\n$md2');
    }

    test('标题/段落/分隔线', () {
      expectRoundtrip('# 标题一\n\n## 二级 **加粗**\n\n正文段落。\n\n---\n\n尾段');
    });

    test('无序列表 + 待办（勾选/未勾选混合）', () {
      expectRoundtrip('- 普通项\n- [ ] 待办甲\n- [x] 待办乙\n- 尾项');
    });

    test('有序列表', () {
      expectRoundtrip('1. 第一\n2. 第二 **粗**\n3. 第三');
    });

    test('引用（多段 + 嵌套列表）', () {
      expectRoundtrip('> 引用第一段\n> 第二行\n>\n> 第二段\n> - 列表甲\n> - 列表乙');
    });

    test('引用嵌套引用', () {
      expectRoundtrip('> 外层\n> > 内层\n> > 第二行');
    });

    test('代码块（带语言/无语言/多行）', () {
      expectRoundtrip('```dart\nvoid main() {}\n// 注释\n```\n\n前段\n\n```\n纯文本代码\n```');
    });

    test('行内全家桶（粗/斜/码/链接）', () {
      expectRoundtrip('**粗** 与 *斜* 与 `码` 与 [官网](https://a.com) 混排');
    });

    test('字面语法标记不丢不变形（转义往返）', () {
      expectRoundtrip('乘法 5*3*2=30 与 下划线 snake_case_name 与 伪链接 [不是链接](真的不是)');
    });

    test('字面反斜杠与反引号', () {
      expectRoundtrip(r'路径 C:\Users\test 与 反引号 ` 出现在文中');
    });

    test('serializeBlocks 输出可被二次 parse 稳定（二次幂等）', () {
      final md1 = serializeBlocks(parser.parse('- [ ] 甲\n\n段 **粗**'));
      final md2 = serializeBlocks(parser.parse(md1));
      expect(md2, md1);
    });

    test('媒体块往返（rich-text-media.md §7）', () {
      expectRoundtrip(
          '![说明图](https://a.com/x.jpg)\n\n[备注语音](https://a.com/y.mp3)\n\n[演示视频](https://a.com/z.mp4)');
    });

    test('媒体块 label/alt 原话往返不变（无前缀注入）', () {
      final blocks = parser.parse('[🎤 会议录音](https://a.com/meet.m4a)');
      final audio = blocks.single as AudioBlock;
      expect(audio.label, '🎤 会议录音'); // 输入自带 emoji 原样保留
      final out = serializeBlock(audio);
      expect(out, '[🎤 会议录音](https://a.com/meet.m4a)'); // 不新增前缀
      final reparsed = parser.parse(out).single as AudioBlock;
      expect(reparsed.label, audio.label);
      expect(reparsed.url, audio.url);
    });
  });

  group('媒体块解析（rich-text-media.md §2）', () {
    test('整行图片 → ImageBlock', () {
      final blocks = parser.parse('![界面截图](https://a.com/shot.png)');
      final img = blocks.single as ImageBlock;
      expect(img.url, 'https://a.com/shot.png');
      expect(img.alt, '界面截图');
    });

    test('音频后缀 → AudioBlock；视频后缀 → VideoBlock', () {
      expect(parser.parse('[听](https://a.com/a.mp3)').single, isA<AudioBlock>());
      expect(parser.parse('[听](https://a.com/a.opus)').single, isA<AudioBlock>());
      expect(parser.parse('[看](https://a.com/v.mp4)').single, isA<VideoBlock>());
      expect(parser.parse('[看](https://a.com/v.m3u8)').single, isA<VideoBlock>());
    });

    test('amr 归 AudioBlock 且后缀归类为降级档（呈现层降级，AST 不携带能力）', () {
      final block = parser.parse('[录音](https://a.com/r.amr)').single;
      expect(block, isA<AudioBlock>());
      expect(classifyMediaUrl('https://a.com/r.amr'), MediaSuffix.audioDegrade);
    });

    test('后缀边界：query 参数 / 大写 / fragment 均正确归类', () {
      expect(parser.parse('[x](https://a.com/v.MP4?token=1&x=2)').single, isA<VideoBlock>());
      expect(parser.parse('[x](https://a.com/a.WAV#t=30)').single, isA<AudioBlock>());
      expect(classifyMediaUrl('HTTPS://EXAMPLE.COM/A.MP3?version=1'), MediaSuffix.audioPlayable);
    });

    test('非媒体链接整行走段落 InlineLink，不丢内容', () {
      final blocks = parser.parse('[官网](https://a.com)\n\n正文');
      expect(blocks, hasLength(2));
      final p = blocks[0] as ParagraphBlock;
      expect(p.inline.whereType<InlineLink>(), hasLength(1));
      expect(_plainOf(blocks[0]), contains('官网'));
    });

    test('段落中间混排图片降级 InlineLink，无「!+链接」残留', () {
      final blocks = parser.parse('前文 ![配图](https://a.com/x.jpg) 后文');
      final p = blocks.single as ParagraphBlock;
      expect(p.inline.whereType<InlineLink>(), hasLength(1));
      final joined = _inlineText(p.inline);
      expect(joined, '前文 配图 后文'); // `!` 被吞掉（现状 bug 修复）
    });

    test('文本行后紧跟媒体行（无空行）也能拆块', () {
      final blocks = parser.parse('先写一句\n![图](https://a.com/x.jpg)');
      expect(blocks, hasLength(2));
      expect(blocks[1], isA<ImageBlock>());
    });

    test('QuoteBlock 内嵌 ImageBlock（嵌套递归）', () {
      final blocks = parser.parse('> ![photo](https://a.com/a.jpg)\n> 引用文字');
      final q = blocks.single as QuoteBlock;
      expect(q.children.whereType<ImageBlock>(), hasLength(1));
      expect(serializeBlock(q), '> ![photo](https://a.com/a.jpg)\n>\n> 引用文字');
    });

    test('file:// url 不拒绝不崩溃（写路径才约束 http(s)）', () {
      final block = parser.parse('[本地](file:///data/user/0/rec.m4a)').single;
      expect(block, isA<AudioBlock>());
    });

    test('blockToPlain 降级：检索/分享可用', () {
      final plain = parser
          .parse('![截图](https://a.com/x.png)\n\n[录音](https://a.com/y.mp3)\n\n[视频](https://a.com/z.mp4)')
          .map(blockToPlain)
          .join('\n\n');
      expect(plain, contains('[图片: 截图]'));
      expect(plain, contains('[音频: 录音]'));
      expect(plain, contains('[视频: 视频]'));
    });
  });

  group('AI 防冲刷护城河 lostMediaUrls（rich-text-media.md §7）', () {
    const original = '前文\n\n![拍照](local://shares/a.jpg)\n\n[录音](local://shares/a.m4a)';
    test('产出丢失媒体 url → 返回丢失集合', () {
      expect(lostMediaUrls(original, 'AI 润色纯文本'), {'local://shares/a.jpg', 'local://shares/a.m4a'});
      expect(lostMediaUrls(original, '前文\n\n![拍照](local://shares/a.jpg)'),
          {'local://shares/a.m4a'});
    });
    test('产出保留全部媒体（可增文字）→ 空', () {
      expect(lostMediaUrls(original, '\n\n$original\n\n补充'), isEmpty);
    });
    test('原文无媒体 → 恒空（纯文本条目不受护城河约束）', () {
      expect(lostMediaUrls('纯文本', 'AI 版'), isEmpty);
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
      ImageBlock(:final alt) => '[图片: $alt]',
      AudioBlock(:final label) => '[音频: $label]',
      VideoBlock(:final label) => '[视频: $label]',
    };

String _inlineText(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => text,
      InlineStrong(:final children) => _inlineText(children),
      InlineEm(:final children) => _inlineText(children),
      InlineCode(:final code) => code,
      InlineLink(:final label) => label,
    }).join();

/// 行内树 → 规范形（含节点类型，保证往返后节点类型也一致）。
String _treeInline(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => 'T($text)',
      InlineStrong(:final children) => 'S[${_treeInline(children)}]',
      InlineEm(:final children) => 'E[${_treeInline(children)}]',
      InlineCode(:final code) => 'C($code)',
      InlineLink(:final label, :final url) => 'L($label|$url)',
    }).join(',');
