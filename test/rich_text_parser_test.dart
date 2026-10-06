import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/models/item.dart' show TodoMark;

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
      final blocks = parser.parse('| a | b |');
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

    test('下划线 <u> 解析（扩展语法，支持嵌套）', () {
      final nodes = parser.parseInline('这是<u>下划线</u>文本');
      final u = nodes.whereType<InlineUnderline>().single;
      expect(_inlineText(u.children), '下划线');
      // 嵌套粗体
      final nested = parser.parseInline('<u>下**划**线</u>');
      final u2 = nested.whereType<InlineUnderline>().single;
      expect(u2.children.whereType<InlineStrong>(), hasLength(1));
    });

    test('未闭合 <u> 原样保留（降级铁律：不丢内容）', () {
      final nodes = parser.parseInline('开始<u>没闭合');
      expect(nodes.whereType<InlineUnderline>(), isEmpty);
      expect(_inlineText(nodes), '开始<u>没闭合');
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
          TableBlock(:final header, :final rows) =>
            'TABLE{${header.join(',')}|${rows.map((r) => r.join(',')).join(';')}}',
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

    test('下划线 <u> 往返（解析↔序列化互逆）', () {
      expectRoundtrip('段落含<u>下划线</u>与 **粗** 混排\n\n<u>整段下划线</u>');
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

  group('行内样式 run 提取（block-format-input §4 地基）', () {
    const parser = MarkdownSubsetParser();

    /// 同源护栏：plain 必须与 inlineToPlain(parseInline(source)) 逐字符一致
    void expectPlainConsistent(String source) {
      final spans = inlineSpansOf(source);
      final expected = inlineToPlain(parser.parseInline(source));
      expect(spans.plain, expected, reason: 'plain 漂移: $source');
    }

    test('同源护栏：全语料 plain 与 inlineToPlain 一致', () {
      const corpus = [
        '这是**粗体**文本',
        '这是*斜体*',
        '<u>下划线</u>与<u>下**划**线嵌套</u>',
        '用 `dart` 写',
        '见[官网](https://a.com)',
        '乘法 5*3*2=30 与 snake_case_name 与 伪链接 [不是链接](真的不是)',
        '星号\\*没闭合',
        '混合 **粗*斜*体** 与 `码` 混排',
        '纯文本无标记',
        '这是~~删除~~文本',
        '这是==高亮==文本',
        '***粗斜体***',
        '访问 https://a.com 看看',
        '',
      ];
      for (final src in corpus) {
        expectPlainConsistent(src);
      }
    });

    test('run 坐标：粗体/斜体/下划线覆盖预期纯文本区间', () {
      final spans = inlineSpansOf('前**粗体**中<u>下划</u>尾');
      expect(spans.plain, '前粗体中下划尾');
      final bold = spans.runs.where((r) => r.mark == InlineMark.bold).single;
      expect(spans.plain.substring(bold.start, bold.end), '粗体');
      final under = spans.runs.where((r) => r.mark == InlineMark.underline).single;
      expect(spans.plain.substring(under.start, under.end), '下划');
    });

    test('嵌套以重叠 run 表达：下划线含粗体', () {
      final spans = inlineSpansOf('<u>下**划**线</u>');
      expect(spans.plain, '下划线');
      final bold = spans.runs.where((r) => r.mark == InlineMark.bold).single;
      expect(spans.plain.substring(bold.start, bold.end), '划');
      // 下划线 run 被嵌套粗体切段（重叠模型），但区间并集须覆盖整个下划线内容
      final underRuns =
          spans.runs.where((r) => r.mark == InlineMark.underline).toList();
      bool covered(int i) =>
          underRuns.any((r) => r.start <= i && i < r.end);
      for (var i = 0; i < spans.plain.length; i++) {
        expect(covered(i), isTrue, reason: '字符 ${spans.plain[i]} 未被下划线覆盖');
      }
    });

    test('链接 run 覆盖 label（转义后纯文本）', () {
      final spans = inlineSpansOf('见[官网](https://a.com)即达');
      expect(spans.plain, '见官网即达');
      final link = spans.runs.where((r) => r.mark == InlineMark.link).single;
      expect(spans.plain.substring(link.start, link.end), '官网');
    });

    test('未闭合标记原样落 plain 且无 run', () {
      const src = '星号*没闭合 与 <u>没闭合';
      final spans = inlineSpansOf(src);
      expect(spans.runs, isEmpty);
      expect(spans.plain, inlineToPlain(parser.parseInline(src)));
    });
  });

  group('GFM 收编（删除线/高亮/粗斜/自动链接/行内码反引号）', () {
    test('删除线 ~~x~~ 解析为 InlineStrikethrough', () {
      final s = parser.parseInline('这是~~删掉~~文本').whereType<InlineStrikethrough>().single;
      expect(_inlineText(s.children), '删掉');
    });

    test('高亮 ==x== 解析为 InlineHighlight', () {
      final h = parser.parseInline('这是==高亮==文本').whereType<InlineHighlight>().single;
      expect(_inlineText(h.children), '高亮');
    });

    test('高亮收紧：a == b / == a== 不触发；x==y==z 命中 ==y==', () {
      expect(parser.parseInline('a == b').whereType<InlineHighlight>(), isEmpty);
      expect(parser.parseInline('== a==').whereType<InlineHighlight>(), isEmpty);
      final h = parser.parseInline('x==y==z').whereType<InlineHighlight>().single;
      expect(_inlineText(h.children), 'y');
    });

    test('粗斜体 ***x*** 双激活（bold+italic，非字面残壳）', () {
      final strong = parser.parseInline('***粗斜***').whereType<InlineStrong>().single;
      final em = strong.children.whereType<InlineEm>().single;
      expect(_inlineText(em.children), '粗斜');
    });

    test('自动链接：裸 https/www/mailto 成链（autolink=true），显式链接=false', () {
      final link = parser.parseInline('访问 https://a.com 结束').whereType<InlineLink>().single;
      expect(link.autolink, isTrue);
      expect(link.url, 'https://a.com');
      final explicit = parser.parseInline('见[官网](https://b.com)').whereType<InlineLink>().single;
      expect(explicit.autolink, isFalse);
    });

    test('行内码含反引号（双扫描预处理，无回溯）', () {
      final code = parser.parseInline(r'用 ``a ` b`` 写').whereType<InlineCode>().single;
      expect(code.code, 'a ` b');
    });

    test('超长连续反引号不卡顿（无灾难性回溯）', () {
      final big = '`' * 20000;
      final sw = Stopwatch()..start();
      parser.parseInline(big);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('GFM 收编 serialize 往返', () {
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
          TableBlock(:final header, :final rows) =>
            'TABLE{${header.join(',')}|${rows.map((r) => r.join(',')).join(';')}}',
        }).join('\n');

    void expectRoundtrip(String markdown) {
      final first = parser.parse(markdown);
      final md2 = serializeBlocks(first);
      final second = parser.parse(md2);
      expect(treeOf(second), treeOf(first), reason: '往返后块树变化：\n$md2');
    }

    test('删除线 + 高亮 + 粗斜 + 自动链接 混排', () {
      expectRoundtrip('~~删除~~ 与 ==高亮== 与 ***粗斜*** 与 访问 https://a.com');
    });

    test('自动链接序列化回裸 url 且往返稳定', () {
      expect(serializeBlocks(parser.parse('见 https://a.com 尾')), contains('https://a.com'));
      expectRoundtrip('见 https://a.com 尾');
    });
  });

  group('表格块（GFM §3.6 ④）', () {
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
          TableBlock(:final header, :final rows) =>
            'TABLE{${header.join(',')}|${rows.map((r) => r.join(',')).join(';')}}',
        }).join('\n');

    test('解析：表头 + 分隔线 + 数据行 → TableBlock', () {
      final table = parser
          .parse('| 名字 | 年龄 |\n|---|---|\n| 张三 | 12 |\n| 李四 | 15 |')
          .whereType<TableBlock>()
          .single;
      expect(table.header, ['名字', '年龄']);
      expect(table.rows, [['张三', '12'], ['李四', '15']]);
    });

    test('分隔线对齐解析：:--- / :--: / ---:', () {
      final table = parser
          .parse('| a | b | c |\n|:---|:--:|:---:|\n| 1 | 2 | 3 |')
          .whereType<TableBlock>()
          .single;
      expect(table.align, [TableAlign.left, TableAlign.center, TableAlign.center]);
    });

    test('无分隔线不识别为表格（降级段落，防误检）', () {
      final blocks = parser.parse('| a | b |');
      expect(blocks, hasLength(1));
      expect(blocks.single, isA<ParagraphBlock>());
    });

    test('表格 serialize 往返稳定', () {
      const md = '| 名字 | 年龄 |\n|---|---|\n| 张三 | 12 |';
      final second = parser.parse(serializeBlocks(parser.parse(md)));
      expect(treeOf(second), treeOf(parser.parse(md)));
    });

    test('表格后紧跟普通段落不吞行', () {
      final blocks = parser.parse('| a | b |\n|---|---|\n| 1 | 2 |\n\n普通段落');
      expect(blocks.whereType<TableBlock>(), hasLength(1));
      expect(blocks.whereType<ParagraphBlock>().single.inline, isNotEmpty);
    });
  });

  group('R3 引用链接（§2 / §3.6 ⑥）', () {
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
          TableBlock(:final header, :final rows) =>
            'TABLE{${header.join(',')}|${rows.map((r) => r.join(',')).join(';')}}',
        }).join('\n');

    test('定义行剥离且 [text][id] 重写为 [text](url)', () {
      final blocks = parser.parse('[docs]: https://ex.com\n\n见 [文档][docs] 结尾');
      final all = blocks.map(blockToPlain).join(' ');
      expect(all, isNot(contains('[docs]:'))); // 定义行已剥离
      final link = blocks
          .whereType<ParagraphBlock>()
          .expand((p) => p.inline)
          .whereType<InlineLink>()
          .single;
      expect(link.label, '文档');
      expect(link.url, 'https://ex.com');
    });

    test('孤立引用链接（id 无定义）留字面，不静默吞', () {
      final blocks = parser.parse('见 [文档][missing] 结尾');
      final all = blocks.map(blockToPlain).join(' ');
      expect(all, contains('[文档][missing]')); // 留字面（R1 由动作层标注）
    });

    test('引用链接 serialize 往返稳定且无 ]: 残壳', () {
      const src = '[docs]: https://ex.com\n\n见 [文档][docs]';
      final first = parser.parse(src);
      final md2 = serializeBlocks(first);
      expect(md2, isNot(contains(']:'))); // 定义行已归一化掉
      final second = parser.parse(md2);
      expect(treeOf(second), treeOf(first));
    });
  });

  group('AI 写入归一层（rich-text-gfm.md §2 层2）', () {
    test('全集内语法零映射：原样透传且空 note', () {
      const md = '## 标题\n\n支持 **粗** *斜* ~~删~~ ==高亮== 与 `码` 与 [链](https://a.com)';
      final r = normalizeAiMarkdown(md);
      expect(r.markdown, md); // 一字未改
      expect(r.notes, isEmpty); // 无降级
    });

    test('脚注定义 + 内联 → 括号注 + R1 note，无 ^ 残壳', () {
      const md = '正文有脚注[^1]。\n\n[^1]: 这是注释';
      final r = normalizeAiMarkdown(md);
      expect(r.markdown, contains('（这是注释）'));
      expect(r.markdown, isNot(contains('[^1]:'))); // 定义行剥离
      expect(r.markdown, isNot(contains('[^1]'))); // 内联已替换
      expect(r.notes, contains('脚注已转为括号注'));
    });

    test('未定义脚注留字面 + 单独 note（禁止静默丢）', () {
      const md = '正文有孤立脚注[^x]。';
      final r = normalizeAiMarkdown(md);
      expect(r.markdown, contains('[^x]')); // 留字面
      expect(r.notes, contains('存在未定义脚注标记，已保留原样'));
    });

    test('脚注与全集内语法共存：子集零映射、脚注映射', () {
      const md = '支持 ==高亮==[^1]。\n\n[^1]: 注';
      final r = normalizeAiMarkdown(md);
      expect(r.markdown, contains('==高亮==')); // 高亮零映射
      expect(r.markdown, contains('（注）'));
      expect(r.notes, ['脚注已转为括号注']);
    });

    test('脚注多行续行并入括号注（定义行+续行无残壳）', () {
      const md = '正文有脚注[^1]。\n\n[^1]: 第一句。\n  第二句补充。\n  第三行。';
      final r = normalizeAiMarkdown(md);
      expect(r.markdown, contains('（第一句。 第二句补充。 第三行。）'));
      expect(r.markdown, isNot(contains('[^1]:')));
      expect(r.markdown, isNot(contains('[^1]')));
      expect(r.notes, ['脚注已转为括号注']);
    });

    test('子集外结构（数学式/HTML）触发 R1 降级告知，且归一层不改写', () {
      const md = r'公式 $$\int x\,dx$$ 与 <div>块</div>';
      final r = normalizeAiMarkdown(md);
      expect(r.markdown, md); // 归一层只告知、不改写内容
      expect(r.notes, contains(startsWith('检测到未支持的 GFM 语法')));
    });

    test('角括号自动链接不误报为不支持 HTML', () {
      const md = '见 <https://a.com> 与 <mailto:b@c.com>';
      final r = normalizeAiMarkdown(md);
      expect(r.notes, isNot(contains(startsWith('检测到未支持的 GFM 语法'))));
    });
  });
  // ───────── 待办勾选批次（2026-10-05）：scanTodoTexts 与 hash 口径 ─────────

  test('scanTodoTexts：列表式 / 裸待办 / 行内标记剥壳 / 引用块递归', () {
    final md = [
      '- [ ] 买牛奶',
      '- [x] 缴房租',
      '* [ ] 星号列表待办',
      '1. [x] 有序列表待办',
      '[ ] 裸待办行',
      '普通列表项不算',
      '正常段落',
      '> - [ ] 引用块里的待办',
      '- [ ] 带**行内标记**和`代码`的待办',
    ].join('\n');
    expect(scanTodoTexts(md), [
      '买牛奶',
      '缴房租',
      '星号列表待办',
      '有序列表待办',
      '裸待办行',
      '引用块里的待办',
      '带行内标记和代码的待办',
    ]);
  });

  test('TodoMark.hashOf：内容寻址口径——重排不变、改文即新键、trim 稳定', () {
    // 与位置无关：同一文本任意顺序 hash 恒定
    expect(TodoMark.hashOf('买牛奶'), TodoMark.hashOf('买牛奶'));
    // trim：前后空白不改变身份
    expect(TodoMark.hashOf('买牛奶'), TodoMark.hashOf(' 买牛奶 '));
    // 改文即新键
    expect(TodoMark.hashOf('买牛奶'), isNot(TodoMark.hashOf('买牛奶 去掉')));
    // 不用 String.hashCode（按进程随机化）——同值跨实例稳定
    expect(TodoMark.hashOf('买牛奶'), TodoMark.hashOf('买牛奶'));
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
      TableBlock(:final header, :final rows) =>
        [...header, for (final r in rows) ...r].join(' '),
    };

String _inlineText(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => text,
      InlineStrong(:final children) => _inlineText(children),
      InlineEm(:final children) => _inlineText(children),
      InlineUnderline(:final children) => _inlineText(children),
      InlineStrikethrough(:final children) => _inlineText(children),
      InlineHighlight(:final children) => _inlineText(children),
      InlineCode(:final code) => code,
      InlineLink(:final label) => label,
    }).join();

/// 行内树 → 规范形（含节点类型，保证往返后节点类型也一致）。
String _treeInline(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => 'T($text)',
      InlineStrong(:final children) => 'S[${_treeInline(children)}]',
      InlineEm(:final children) => 'E[${_treeInline(children)}]',
      InlineUnderline(:final children) => 'U[${_treeInline(children)}]',
      InlineStrikethrough(:final children) => 'X[${_treeInline(children)}]',
      InlineHighlight(:final children) => 'H[${_treeInline(children)}]',
      InlineCode(:final code) => 'C($code)',
      InlineLink(:final label, :final url) => 'L($label|$url)',
    }).join(',');
