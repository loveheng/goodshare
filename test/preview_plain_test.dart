import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/share/text_parse.dart';

void main() {
  group('titleToPlain（标题剥壳出口）', () {
    test('剥行内标记', () {
      expect(titleToPlain('<u>重要</u>'), '重要');
      expect(titleToPlain('**粗体**与*斜体*'), '粗体与斜体');
      expect(titleToPlain('==高亮==与~~删除~~'), '高亮与删除');
      expect(titleToPlain('`行内码`'), '行内码');
    });

    test('剥行首 # 前缀（存量 humanTitle 派生兜底）', () {
      expect(titleToPlain('# 一级标题'), '一级标题');
      expect(titleToPlain('### 三级标题'), '三级标题');
      expect(titleToPlain('## <u>带标记</u>'), '带标记');
    });

    test('普通文本原样', () {
      expect(titleToPlain('普通标题'), '普通标题');
    });
  });

  group('markdownToPlain（整篇剥壳出口）', () {
    test('标题/粗体/图片标记剥除，媒体行降级可读', () {
      expect(markdownToPlain('# 标题\n\n正文 **粗体**'), '标题\n\n正文 粗体');
      expect(markdownToPlain('![拍照](local://shares/a.jpg)'), '[图片: 拍照]');
      expect(markdownToPlain('[录音](local://shares/a.m4a)'), '[音频: 录音]');
      expect(markdownToPlain('- 第一项\n- 第二项'), '第一项\n第二项');
    });
  });

  group('InboxItem.preview 纯文本口径（列表卡片不出 md 标记）', () {
    final now = DateTime.now().millisecondsSinceEpoch;

    test('标题分支：一级标题派生的 humanTitle 剥 # 与行内标记', () {
      final it = InboxItem(
        itemType: InboxItem.typeNote,
        humanTitle: '# <u>重要</u>',
        rawContent: '# <u>重要</u>\n\n正文内容',
        createdAt: now,
      );
      expect(it.preview, '重要');
    });

    test('rawContent 分支：速记 md 原文剥壳（无标题/无 TLDR 回退路径）', () {
      final it = InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: '# 今日计划\n\n- [ ] 买牛奶\n\n**重点**：带伞',
        createdAt: now,
      );
      final p = it.preview;
      expect(p.contains('#'), isFalse, reason: '不出 # 残壳：$p');
      expect(p.contains('**'), isFalse, reason: '不出粗体残壳：$p');
      expect(p.contains('买牛奶'), isTrue);
      expect(p.contains('重点：带伞'), isTrue);
    });

    test('行内媒体占位符不进预览文本（2026-10-06：卡面渲染真图/封面）', () {
      final it = InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: '看这个\n\n![](local://shares/pic.jpg)',
        createdAt: now,
      );
      expect(it.preview, contains('看这个'));
      expect(it.preview.contains('[图片]'), isFalse, reason: '占位符由卡面真图替代');
      expect(it.preview.contains('!['), isFalse);
    });

    test('带 alt 的图片/视频占位符同样剔除', () {
      final it = InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: '![截图](local://shares/a.jpg)\n\n[](local://shares/b.mp4)',
        createdAt: now,
      );
      expect(it.preview.contains('[图片: 截图]'), isFalse);
      expect(it.preview.contains('[视频'), isFalse);
    });

    test('TL;DR 分支优先且不二次剥壳（纯文本透传）', () {
      final it = InboxItem(
        itemType: InboxItem.typeNote,
        humanTldr: '三句话摘要',
        rawContent: '# 标题',
        createdAt: now,
      );
      expect(it.preview, '三句话摘要');
    });
  });

  group('parseCollectedText 摄入标题剥壳', () {
    test('note 首行为一级标题 → humanTitle 不带 #', () {
      final r = parseCollectedText('# 购物清单\n\n- [ ] 买牛奶');
      expect(r.type, InboxItem.typeNote);
      expect(r.title, '购物清单');
      expect(r.title!.startsWith('#'), isFalse);
    });

    test('「标题\nURL」首行带 md 标记 → 剥壳', () {
      final r = parseCollectedText('# 好文章\nhttps://example.com/a');
      expect(r.type, InboxItem.typeUrl);
      expect(r.title, '好文章');
    });

    test('纯 URL 无标题；普通首行不受影响', () {
      expect(parseCollectedText('https://example.com').title, isNull);
      expect(parseCollectedText('随手记一笔').title, '随手记一笔');
    });
  });
}
