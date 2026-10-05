import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/share/note_composer.dart';

void main() {
  const parser = MarkdownSubsetParser();
  const appDir = 'local://shares';

  group('速记段模型与序列化', () {
    test('纯文本段序列化为原文', () {
      final md = serializeNoteMd([
        const NoteTextSegment('第一段想法'),
        const NoteTextSegment('第二段'),
      ]);
      expect(md, '第一段想法\n\n第二段');
    });

    test('图片段序列化为整行 ![alt](绝对路径)，音频段为 [label](绝对路径)', () {
      final md = serializeNoteMd([
        const NoteTextSegment('看这个'),
        NoteImageSegment('$appDir/1727.jpg', alt: '拍照'),
        const NoteAudioSegment('$appDir/1728.m4a'),
      ]);
      expect(
          md,
          '看这个\n\n'
          '![拍照]($appDir/1727.jpg)\n\n'
          '[录音]($appDir/1728.m4a)');
    });

    test('待办模式：文本段逐行转 - [ ]，媒体段不参与转换', () {
      final md = serializeNoteMd(
        [
          const NoteTextSegment('买牛奶\n\n叫快递'),
          NoteImageSegment('$appDir/1.jpg'),
        ],
        todoMode: true,
      );
      expect(md, '- [ ] 买牛奶\n- [ ] 叫快递\n\n![]($appDir/1.jpg)');
    });

    test('alt/label 的 ] 与 \\ 被转义，不破坏媒体行结构', () {
      final md = serializeNoteMd([
        const NoteAudioSegment('$appDir/a.m4a', label: r'备注]一下\x'),
      ]);
      expect(md, r'[备注\]一下\\x](local://shares/a.m4a)');
    });

    test('空文本段与空路径媒体段不产生噪声行', () {
      final md = serializeNoteMd([
        const NoteTextSegment('   '),
        const NoteImageSegment(''),
        const NoteAudioSegment('$appDir/a.m4a'),
      ]);
      expect(md, '[录音]($appDir/a.m4a)');
    });

    test('全空序列化为空串（调用方按「内容为空」拒绝保存）', () {
      expect(serializeNoteMd([const NoteTextSegment('')]), '');
    });

    test('hasMedia：纯文本 false；图/音/视频任一 true', () {
      expect(noteHasMedia([const NoteTextSegment('x')]), isFalse);
      expect(noteHasMedia([NoteImageSegment('/tmp/a.jpg')]), isTrue);
      expect(noteHasMedia([NoteAudioSegment('/tmp/a.m4a')]), isTrue);
      expect(noteHasMedia([const NoteVideoSegment('/tmp/a.mp4')]), isTrue);
    });

    test('视频段序列化为整行 [label](local://…)，默认 label「视频」', () {
      final md = serializeNoteMd([
        const NoteTextSegment('看这段'),
        const NoteVideoSegment('$appDir/1730.mp4'),
      ]);
      expect(md, '看这段\n\n[视频]($appDir/1730.mp4)');
      // label 原话
      final md2 = serializeNoteMd(
          [const NoteVideoSegment('$appDir/a.mov', label: '现场记录')]);
      expect(md2, '[现场记录]($appDir/a.mov)');
    });

    test('标题取第一个一级标题行（剥 md 标记）；无一级标题返回 null（时间兜底）', () {
      expect(
        noteTitleOf([
          const NoteTextSegment('普通段落不算'),
          const NoteTextSegment('# 真标题\n正文'),
        ]),
        '真标题',
      );
      // 二级标题不算一级
      expect(noteTitleOf([const NoteTextSegment('## 二级')]), isNull);
      // 前置空行/缩进容忍，纯标记行跳过
      expect(
        noteTitleOf([const NoteTextSegment('#  带空格的标题')]),
        '带空格的标题',
      );
      expect(noteTitleOf([NoteImageSegment('/tmp/a.jpg')]), isNull);
      expect(noteTitleOf(const []), isNull);
      // 一级标题行含行内标记（如 `<u>`）须原样保留——标记由渲染层决定样式
      // （详情页标题栏渲染下划线、列表预览剥壳），此处不得剥壳，否则详情页
      // 标题下划线丢失（契约见 note_composer.noteTitleOf 注释）
      expect(
        noteTitleOf([const NoteTextSegment('# <u>重要</u>')]),
        '<u>重要</u>',
      );
    });
  });

  group('与规则层三出口对齐（rich-text-media.md §2）', () {
    test('序列化产物 parse 回块树：文本段→Paragraph，图→ImageBlock，音→AudioBlock，视频→VideoBlock', () {
      final md = serializeNoteMd([
        const NoteTextSegment('前文'),
        NoteImageSegment('$appDir/pic.jpg', alt: '白板'),
        const NoteAudioSegment('$appDir/rec.m4a'),
        const NoteVideoSegment('$appDir/clip.mp4'),
        const NoteTextSegment('后文'),
      ]);
      final blocks = parser.parse(md);
      expect(blocks, hasLength(5));
      final img = blocks[1] as ImageBlock;
      expect(img.url, '$appDir/pic.jpg');
      expect(img.alt, '白板');
      final audio = blocks[2] as AudioBlock;
      expect(audio.url, '$appDir/rec.m4a');
      expect(audio.label, '录音');
      final video = blocks[3] as VideoBlock;
      expect(video.url, '$appDir/clip.mp4');
      expect(video.label, '视频');
    });

    test('local:// 媒体命中后缀白名单（classify 取 Uri.path 后缀）', () {
      expect(classifyMediaUrl('$appDir/rec.m4a'), MediaSuffix.audioPlayable);
      expect(classifyMediaUrl('$appDir/rec.mp4'), MediaSuffix.video);
      expect(classifyMediaUrl('$appDir/rec.amr'), MediaSuffix.audioDegrade);
    });

    test('parse→serialize 往返：alt/label 原话不变（幂等护栏，走规则层 serializeBlocks）', () {
      final md = serializeNoteMd([
        NoteImageSegment('$appDir/pic.jpg', alt: '原话说明'),
        const NoteAudioSegment('$appDir/rec.m4a'),
      ]);
      final blocks = parser.parse(md);
      final out = serializeBlocks(blocks);
      final reparsed = parser.parse(out);
      expect((reparsed[0] as ImageBlock).alt, '原话说明');
      expect((reparsed[1] as AudioBlock).label, '录音');
    });
  });

  group('human_md → 草稿行（编辑器统一，2026-10-03）', () {
    // 全链路往返：段 → md → 草稿行 →（seed/serialize 模拟编辑器进出）→ 段语义等价
    List<NoteSegment> rowsToSegments(List<List<String>> rows) => [
          for (final r in rows)
            switch (r.first) {
              'i' => NoteImageSegment(r[1], alt: r.length > 2 ? r[2] : ''),
              'a' => NoteAudioSegment(r[1], label: r.length > 2 ? r[2] : '录音'),
              'v' => NoteVideoSegment(r[1], label: r.length > 2 ? r[2] : '视频'),
              _ => NoteTextSegment(r.length > 1 ? r[1] : ''),
            },
        ];

    test('文本+媒体混合往返幂等（含转义 alt/label）', () {
      final original = <NoteSegment>[
        const NoteTextSegment('看这个\n第二行'),
        NoteImageSegment('$appDir/p.jpg', alt: '含]转义'),
        const NoteAudioSegment('$appDir/r.m4a', label: '会议录音'),
        const NoteVideoSegment('$appDir/v.mp4'),
      ];
      final md = serializeNoteMd(original);
      final rows = noteMdToDraftRows(md);
      expect(rows[0], ['t', '看这个\n第二行']);
      expect(rows[1], ['i', '$appDir/p.jpg', '含]转义']);
      expect(rows[2], ['a', '$appDir/r.m4a', '会议录音']);
      expect(rows[3], ['v', '$appDir/v.mp4', '视频']);
      // 段语义往返：媒体行回到媒体段，文本段经编辑器 seed/serialize 逆变换后等价
      final roundTripped = rowsToSegments(rows);
      expect(noteHasMedia(roundTripped), isTrue);
      expect(
        serializeNoteMd(roundTripped),
        serializeNoteMd([
          const NoteTextSegment('看这个\n第二行'),
          NoteImageSegment('$appDir/p.jpg', alt: '含]转义'),
          const NoteAudioSegment('$appDir/r.m4a', label: '会议录音'),
          const NoteVideoSegment('$appDir/v.mp4'),
        ]),
      );
    });

    test('标题/行内样式行保留原文（seed/serialize 由编辑器 codec 逆变换）', () {
      final rows = noteMdToDraftRows('# 标题\n\n正文有 **粗体**');
      expect(rows, [
        ['t', '# 标题'],
        ['t', '正文有 **粗体**'],
      ]);
    });

    test('列表/引用/代码块/分隔线整块字面保留（段模型不认识的结构）', () {
      const md = '- 第一项\n- 第二项\n\n> 引用一句\n\n```dart\ncode()\n```\n\n---';
      final rows = noteMdToDraftRows(md);
      expect(rows, [
        ['t', '- 第一项\n- 第二项'],
        ['t', '> 引用一句'],
        ['t', '```dart\ncode()\n```'],
        ['t', '---'],
      ]);
      // 字面保留 = 保存原样回写
      final segments = rowsToSegments(rows);
      expect(serializeNoteMd(segments), md);
    });

    test('外链图片行/纯链接行不误吞（非 local:// 保持文本段）', () {
      final rows = noteMdToDraftRows('![封面](https://example.com/a.png)\n\n[某站](https://b.site)');
      expect(rows, [
        ['t', '![封面](https://example.com/a.png)'],
        ['t', '[某站](https://b.site)'],
      ]);
    });

    test('待办序列化产物按字面文本段保留（查看态仍渲染勾选行）', () {
      final md = serializeNoteMd([const NoteTextSegment('买牛奶\n取快递')], todoMode: true);
      expect(md, '- [ ] 买牛奶\n- [ ] 取快递');
      final rows = noteMdToDraftRows(md);
      expect(rows, [
        ['t', '- [ ] 买牛奶\n- [ ] 取快递'],
      ]);
    });

    test('空 md → 空行表（编辑器起手一段文本）', () {
      expect(noteMdToDraftRows(''), isEmpty);
      expect(noteMdToDraftRows('  \n\n  '), isEmpty);
    });
  });
}
