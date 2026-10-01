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

    test('标题取首个非空文本行，折叠空白截 30 字；无文字返回 null', () {
      expect(
        noteTitleOf([
          const NoteTextSegment('  \n'),
          const NoteTextSegment('这是   标题行\n第二行'),
        ]),
        '这是 标题行 第二行',
      );
      final long = noteTitleOf([NoteTextSegment('长' * 40)]);
      expect(long!.length, 31); // 30 字 + 省略号
      expect(long.endsWith('…'), isTrue);
      expect(noteTitleOf([NoteImageSegment('/tmp/a.jpg')]), isNull);
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
}
