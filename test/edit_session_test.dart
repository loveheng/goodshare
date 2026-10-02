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
}
