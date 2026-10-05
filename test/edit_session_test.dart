import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/edit_session.dart';
import 'package:goodshare/doc/rich_text.dart';

void main() {
  const parser = MarkdownSubsetParser();

  group('blockEditText ↔ rebuildBlock（块 ↔ 编辑文本映射）', () {
    /// 重建后与原块序列化等价（结构逐节点一致）。
    void expectRebuildStable(String md) {
      final original = parser.parse(md);
      for (final b in original) {
        final rebuilt = rebuildBlock(b, blockEditText(b), todoDone: switch (b) {
          ListBlock(items: [ListItem(done: true)]) => true,
          ListBlock(items: [ListItem(done: false)]) => false,
          _ => null,
        });
        expect(rebuilt, isNotNull, reason: '块不应被判空删除：$md');
        expect(serializeBlock(rebuilt!), serializeBlock(b),
            reason: '重建后序列化变化：$md\n原: ${serializeBlock(b)}\n新: ${serializeBlock(rebuilt)}');
      }
    }

    test('普通段落（无样式）', () => expectRebuildStable('第一段普通文本'));
    test('含行内样式的段落（粗/斜/码/链接）', () => expectRebuildStable('**粗** 与 *斜* 与 `码` 与 [官网](https://a.com)'));
    test('含字面语法标记的段落（转义保持字面）', () => expectRebuildStable(r'乘法 5\*3\*2=30 与 下划线 snake\_case'));
    test('标题（级别保留）', () => expectRebuildStable('## 二级标题 **粗**'));
    test('引用块（内部重解析）', () => expectRebuildStable('> 引用内容 **粗**'));
    test('代码块（语言与缩进保留）', () => expectRebuildStable('```dart\nvoid main() {}\n  indent\n```'));
    test('单项待办（勾选态保留）', () => expectRebuildStable('- [ ] 买牛奶'));
    test('单项普通列表', () => expectRebuildStable('- 普通项'));
    test('多项列表（标记往返）', () => expectRebuildStable('- 甲\n- [ ] 乙\n- [x] 丙'));
    test('有序列表', () => expectRebuildStable('1. 甲\n2. 乙'));
    test('分隔线', () => expectRebuildStable('前段\n\n---\n\n后段'));
    test('媒体块（alt/label 编辑往返，rich-text-media.md §4）', () {
      expectRebuildStable('![说明图](https://a.com/x.jpg)');
      expectRebuildStable('[备注语音](https://a.com/y.mp3)');
      expectRebuildStable('[演示视频](https://a.com/z.mp4)');
    });

    test('编辑文本改动反映到重建块', () {
      final p = parser.parse('原始段落').first;
      final rebuilt = rebuildBlock(p, '改过的段落') as ParagraphBlock;
      expect(inlineToPlain(rebuilt.inline), '改过的段落');
    });

    test('编辑为空白 → 返回 null（删除块）', () {
      final p = parser.parse('原始段落').first;
      expect(rebuildBlock(p, '   '), isNull);
    });

    test('媒体块编辑 alt/label：清空文本不删块（url 是内容本体）', () {
      final audio = parser.parse('[备注语音](https://a.com/y.mp3)').first;
      final renamed = rebuildBlock(audio, '会议录音') as AudioBlock;
      expect(renamed.label, '会议录音');
      expect(renamed.url, 'https://a.com/y.mp3');
      final cleared = rebuildBlock(audio, '') as AudioBlock;
      expect(cleared.url, 'https://a.com/y.mp3'); // 块不因 label 清空而删除
      final img = parser.parse('![说明图](https://a.com/x.jpg)').first;
      final alt = rebuildBlock(img, '新说明') as ImageBlock;
      expect(alt.alt, '新说明');
      expect(alt.url, 'https://a.com/x.jpg');
    });

    test('单项待办勾选态可切换', () {
      final todo = parser.parse('- [ ] 买牛奶').first;
      final done = rebuildBlock(todo, '买牛奶', todoDone: true) as ListBlock;
      expect(done.items.single.done, isTrue);
      // 序列化落 md 为 [x]
      expect(serializeBlock(done), '- [x] 买牛奶');
    });

    test('多项列表：用户删掉标记的行仍是列表项', () {
      final list = parser.parse('- 甲\n- 乙').first as ListBlock;
      final rebuilt = rebuildBlock(list, '甲改\n乙改') as ListBlock;
      expect(rebuilt.items, hasLength(2));
      expect(inlineToPlain(rebuilt.items[0].inline), '甲改');
      expect(inlineToPlain(rebuilt.items[1].inline), '乙改');
    });

    test('多项列表：出现待办标记归为无序且状态保留', () {
      final list = parser.parse('1. 甲\n2. 乙').first as ListBlock;
      final rebuilt = rebuildBlock(list, '- [ ] 待办') as ListBlock;
      expect(rebuilt.ordered, isFalse);
      expect(rebuilt.items.single.done, isFalse);
    });

    test('引用块编辑空 → null；含标记文本重解析', () {
      final q = parser.parse('> 引用').first;
      expect(rebuildBlock(q, ''), isNull);
      final rebuilt = rebuildBlock(q, '**粗** 引用') as QuoteBlock;
      final inner = rebuilt.children.single as ParagraphBlock;
      expect(inner.inline.first, isA<InlineStrong>());
    });
  });

  group('EditSession 事务：解析 / 文本编辑 / 结构操作 / 日志', () {
    test('parse 出块数与结构一致', () {
      final s = EditSession('甲段\n\n乙段\n\n丙段');
      expect(s.blocks, hasLength(3));
    });

    test('markdown 出口幂等（parse→serialize→parse 稳定）', () {
      final md =
          '段\n\n## 标题 **粗**\n\n> 引\n\n- a\n- [x] b\n\n1. 一\n2. 二';
      final s = EditSession(md);
      final out = s.markdown;
      expect(EditSession(out).markdown, out);
    });

    test('editTextOf 等于块编辑文本，越界兜底空串', () {
      final s = EditSession('**粗** 段\n\n- 项');
      expect(s.editTextOf(0), '**粗** 段');
      expect(s.editTextOf(1), '项');
      expect(s.editTextOf(2), '');
    });

    test('CommitTextOp 改写文本并落 markdown', () {
      final s = EditSession('甲段');
      s.apply(CommitTextOp(0, '乙段'));
      expect(s.markdown, '乙段');
    });

    test('CommitTextOp 清空文本 → 删块', () {
      final s = EditSession('甲\n\n乙');
      s.apply(CommitTextOp(0, '   '));
      expect(s.blocks, hasLength(1));
      expect(s.markdown, '乙');
    });

    test('DeleteOp 删除指定块', () {
      final s = EditSession('甲\n\n乙\n\n丙');
      s.apply(DeleteOp(1));
      expect(s.markdown, '甲\n\n丙');
    });

    test('InsertAfterOp 在 index 后插入空段落', () {
      final s = EditSession('甲\n\n乙');
      s.apply(InsertAfterOp(0));
      expect(s.blocks, hasLength(3));
      final mid = s.blocks[1].block;
      expect(mid, isA<ParagraphBlock>());
      expect((mid as ParagraphBlock).inline, isEmpty);
    });

    test('AppendOp 末尾追加空段落', () {
      final s = EditSession('甲');
      s.apply(AppendOp());
      expect(s.blocks, hasLength(2));
    });

    test('MoveOp 上下移重排', () {
      final s = EditSession('甲\n\n乙\n\n丙');
      s.apply(MoveOp(2, -1)); // 丙上移 → 甲 丙 乙
      expect(s.markdown, '甲\n\n丙\n\n乙');
      s.apply(MoveOp(0, 1)); // 甲下移 → 丙 甲 乙
      expect(s.markdown, '丙\n\n甲\n\n乙');
    });

    test('越界操作静默忽略且不落日志', () {
      final s = EditSession('甲\n\n乙');
      s.apply(MoveOp(0, -1)); // 首块上移越界
      s.apply(DeleteOp(9));
      s.apply(CommitTextOp(9, 'x'));
      expect(s.markdown, '甲\n\n乙');
      expect(s.log, isEmpty);
    });

    test('isDirty 随事务翻转，日志记录操作类型', () {
      final s = EditSession('甲');
      expect(s.isDirty, isFalse);
      s.apply(CommitTextOp(0, '乙'));
      expect(s.isDirty, isTrue);
      expect(s.log, hasLength(1));
      expect(s.log.first, isA<CommitTextOp>());
    });

    test('结构性操作同样记入日志', () {
      final s = EditSession('甲\n\n乙');
      s.apply(InsertAfterOp(0));
      s.apply(DeleteOp(0));
      expect(s.log, hasLength(2));
      expect(s.log[0], isA<InsertAfterOp>());
      expect(s.log[1], isA<DeleteOp>());
    });

    test('SplitOp 段落粘贴含空行 → 拆成多块', () {
      final s = EditSession('甲');
      s.apply(SplitOp(0, '第一\n\n第二\n\n第三'));
      expect(s.blocks, hasLength(3));
      expect(s.markdown, '第一\n\n第二\n\n第三');
    });

    test('SplitOp 引用块按空行拆成多引用', () {
      final s = EditSession('> 引言');
      s.apply(SplitOp(0, '甲\n\n乙'));
      expect(s.blocks, hasLength(2));
    });

    test('SplitOp 无空行不拆、原样提交', () {
      final s = EditSession('甲');
      s.apply(SplitOp(0, '第一行\n第二行'));
      expect(s.blocks, hasLength(1));
      expect(s.editTextOf(0), contains('第一行'));
    });

    test('SplitOp 标题块不拆、文本原样提交', () {
      final s = EditSession('## 标题');
      s.apply(SplitOp(0, '标题段\n\n副段'));
      expect(s.blocks, hasLength(1));
      expect(s.editTextOf(0), contains('副段'));
    });

    test('SplitOp 空段被丢弃并记录入日志', () {
      final s = EditSession('甲');
      s.apply(SplitOp(0, 'a\n\n\n\nb')); // 双空行含空段
      expect(s.blocks, hasLength(2));
      expect(s.log.last, isA<SplitOp>());
    });

    test('ReplaceMediaOp 替换图片 url 保留 alt、身份不变、记日志', () {
      final s = EditSession('![图](local://shares/a.jpg)');
      final before = s.blocks.first.id;
      s.apply(ReplaceMediaOp(0, 'local://shares/b.jpg'));
      final img = s.blocks.first.block as ImageBlock;
      expect(img.url, 'local://shares/b.jpg');
      expect(img.alt, '图');
      expect(s.blocks.first.id, before); // 编辑态身份在替换后不变
      expect(s.log.last, isA<ReplaceMediaOp>());
    });

    test('ReplaceMediaOp 仅媒体块可替换、越界静默忽略', () {
      final s = EditSession('甲'); // 段落块，替换无效
      s.apply(ReplaceMediaOp(0, 'x'));
      expect(s.blocks.first.block, isA<ParagraphBlock>());
      final s2 = EditSession('![图](local://a.jpg)');
      s2.apply(ReplaceMediaOp(5, 'y')); // 越界
      expect(s2.blocks.first.block, isA<ImageBlock>());
    });

    test('EditBlock.id 唯一、文本改写/移动保留、新建块换新身份', () {
      final s = EditSession('甲\n\n乙\n\n丙');
      final ids = s.blocks.map((b) => b.id).toList();
      expect(ids.toSet().length, 3); // 三个块身份唯一
      final firstId = ids[0];
      s.apply(CommitTextOp(0, '甲改'));
      expect(s.blocks[0].id, firstId); // 文本改写保留身份
      s.apply(MoveOp(0, 1));
      expect(s.blocks[1].id, firstId); // 移动保留身份
      s.apply(InsertAfterOp(0));
      expect(s.blocks[1].id, isNot(firstId)); // 新块获新身份
    });
  });

    test('SetHeadingOp 段落→标题→正文互转，保留行内结构与块身份', () {
      final s = EditSession('你好 **粗**\n\n普通段');
      final headingId = s.blocks[0].id;
      s.apply(SetHeadingOp(0, 1));
      expect(s.blocks[0].block, isA<HeadingBlock>());
      final h = s.blocks[0].block as HeadingBlock;
      expect(h.level, 1);
      expect(inlineToPlain(h.inline), '你好 粗'); // 行内结构保留
      expect(s.blocks[0].id, headingId); // 块身份不变
      s.apply(SetHeadingOp(0, 2));
      expect((s.blocks[0].block as HeadingBlock).level, 2);
      s.apply(SetHeadingOp(0, 0));
      expect(s.blocks[0].block, isA<ParagraphBlock>());
      expect(s.blocks[0].id, headingId);
    });

    test('SetHeadingOp 仅段落/标题可互转：列表/媒体/代码块不变换', () {
      final s = EditSession('- 甲\n\n![图片](local://a.png)\n\n``````');
      s.apply(SetHeadingOp(0, 1));
      expect(s.blocks[0].block, isA<ListBlock>());
      s.apply(SetHeadingOp(1, 1));
      expect(s.blocks[1].block, isA<ImageBlock>());
      // 越界静默忽略（防呆下沉会话层）
      s.apply(SetHeadingOp(99, 1));
    });


  group('样式化输入 span 状态层（block-format-input §4 slice-2）', () {
    test('seedSpanBlock：播种纯文本与 runs，markdown 出口不变', () {
      final s = EditSession('前**粗**后\n\n普通段');
      s.seedSpanBlock(0);
      expect(s.isSpanBlock(0), isTrue);
      expect(s.spanEditTextOf(0), '前粗后');
      final b = s.blocks[0];
      final bold = b.inlineRuns!.where((r) => r.mark == InlineMark.bold).single;
      expect(b.inlinePlain!.substring(bold.start, bold.end), '粗');
      expect(s.markdown, '前**粗**后\n\n普通段'); // 播种不改序列化出口
      expect(s.isSpanBlock(1), isFalse); // 未播种块回落 md 路径
    });

    test('applySpanInput：run 内插入延展、run 边界外不越界', () {
      final s = EditSession('前**粗体**后');
      s.seedSpanBlock(0);
      // 「粗体」中间插入 X（严格 run 内）：run 延展涵盖
      s.applySpanInput(0, '前粗X体后', active: const {});
      var bold = s.blocks[0].inlineRuns!.where((r) => r.mark == InlineMark.bold).single;
      expect(s.blocks[0].inlinePlain!.substring(bold.start, bold.end), '粗X体');
      // run 末尾之后追加 Y（无激活样式）：不入 run（先选后打拍板——
      // 边界延续由激活态负责）
      s.applySpanInput(0, '前粗X体后Y', active: const {});
      bold = s.blocks[0].inlineRuns!.where((r) => r.mark == InlineMark.bold).single;
      expect(s.blocks[0].inlinePlain!.substring(bold.start, bold.end), '粗X体');
    });

    test('applySpanInput：激活样式先选后打（新插入段落 run）', () {
      final s = EditSession('前**粗**后');
      s.seedSpanBlock(0);
      s.applySpanInput(0, '前粗后X', active: const {InlineMark.underline});
      final under = s.blocks[0].inlineRuns!.where((r) => r.mark == InlineMark.underline).single;
      expect(s.blocks[0].inlinePlain!.substring(under.start, under.end), 'X');
      // 重建的 inline 树经序列化后下划线标记在位
      expect(s.markdown, contains('<u>X</u>'));
    });

    test('applySpanInput：删除裁剪 run，跨 run 删除不崩', () {
      final s = EditSession('前**粗**后');
      s.seedSpanBlock(0);
      s.applySpanInput(0, '前后', active: const {}); // 删掉「粗」（run 整体删空）
      expect(s.blocks[0].inlineRuns!.where((r) => r.mark == InlineMark.bold), isEmpty);
      expect(s.markdown, contains('前后'));
      s.applySpanInput(0, '前', active: const {}); // 继续删
      expect(s.blocks[0].inlinePlain, '前');
    });

    test('splitSpanBlock：runs 按光标区间分到两侧，标题档保持', () {
      final s = EditSession('# 前**粗**后');
      s.seedSpanBlock(0);
      // 光标在「前|粗后」= offset 1
      s.splitSpanBlock(0, 1);
      expect(s.blocks.length, 2);
      expect(s.blocks[0].block, isA<HeadingBlock>()); // 原块保标题
      expect(s.blocks[1].block, isA<ParagraphBlock>()); // 新块恒正文（拍板）
      expect(s.spanEditTextOf(0), '前');
      expect(s.spanEditTextOf(1), '粗后');
      final bold = s.blocks[1].inlineRuns!
          .where((r) => r.mark == InlineMark.bold).single;
      expect(s.blocks[1].inlinePlain!.substring(bold.start, bold.end), '粗');
      expect(s.markdown, contains('**粗**')); // 样式跨块保全
    });

    test('splitSpanBlock：光标落在 run 中间时两侧各得半段', () {
      final s = EditSession('前**粗体**后');
      s.seedSpanBlock(0);
      s.splitSpanBlock(0, 2); // 「前粗|体后」——粗体 run 从中间切开
      expect(s.spanEditTextOf(0), '前粗');
      expect(s.spanEditTextOf(1), '体后');
      expect(s.markdown, contains('前**粗**')); // 前半段：前缀 + 半段粗体
      expect(s.markdown, contains('**体**后')); // 后半段：半段粗体 + 后缀
    });

    test('span 块提交后 markdown 序列化往返一致（数据无损）', () {
      final s = EditSession('见[官网](https://a.com)即达');
      s.seedSpanBlock(0);
      // run 末尾之后插入（无激活样式）：X 落链接外，url 保全
      s.applySpanInput(0, '见官网X即达', active: const {});
      var md1 = s.markdown;
      expect(md1, contains('[官网](https://a.com)X'));
      // 字级替换（选中「网」打 X）：run 横跨替换窗保持连续，url 保全
      final s2 = EditSession('见[官网](https://a.com)即达');
      s2.seedSpanBlock(0);
      s2.applySpanInput(0, '见官X即达', active: const {});
      md1 = s2.markdown;
      expect(md1, contains('[官X](https://a.com)'), reason: '字级替换不打断链接');
      final s3 = EditSession(md1);
      expect(s3.markdown, md1); // 二次解析稳定
    });
  });
}