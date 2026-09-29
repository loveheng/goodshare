import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/models/item.dart';
import 'package:goodshare/share/note_composer.dart';

void main() {
  const composer = DefaultNoteComposer();

  group('速记段模型', () {
    test('文本段与语音段来源标记不同', () {
      final t = composer.textSegment('想到一个点子', ts: 1);
      final v = composer.voiceSegment('/tmp/a.m4a', ts: 2);
      expect(t.source, kSegmentText);
      expect(v.source, kSegmentVoice);
      expect(t.isVoice, isFalse);
      expect(v.isVoice, isTrue);
    });

    test('段级音频路径往返序列化不丢', () {
      final v = composer.voiceSegment('/tmp/a.m4a', ts: 7);
      final back = AppendixEntry.fromJson(v.toJson());
      expect(back.path, '/tmp/a.m4a');
      expect(back.isVoice, isTrue);
      expect(back.ts, 7);
    });

    test('旧段（无 path 字段）解析不受影响', () {
      final old = AppendixEntry.fromJson({'ts': 1, 'text': 'x', 'source': '微信'});
      expect(old.path, isNull);
      expect(old.isVoice, isFalse);
    });
  });

  group('速记组装', () {
    test('文本段拼接进 raw_content，未转写语音段不产生占位噪声', () {
      final segs = [
        composer.textSegment('第一段', ts: 1),
        composer.voiceSegment('/tmp/a.m4a', ts: 2), // 未转写，text 为空
        composer.textSegment('第二段', ts: 3),
      ];
      expect(composer.rawContentOf(segs), '第一段\n\n第二段');
    });

    test('主附件取首个语音段', () {
      final segs = [
        composer.textSegment('x', ts: 1),
        composer.voiceSegment('/tmp/first.m4a', ts: 2),
        composer.voiceSegment('/tmp/second.m4a', ts: 3),
      ];
      expect(composer.primaryPathOf(segs), '/tmp/first.m4a');
    });

    test('纯文本速记无主附件、无语音', () {
      final segs = [composer.textSegment('a', ts: 1)];
      expect(composer.primaryPathOf(segs), isNull);
      expect(composer.hasVoice(segs), isFalse);
    });

    test('语音段转写回填后进入 raw_content', () {
      final segs = [
        composer.textSegment('开头', ts: 1),
        AppendixEntry(ts: 2, text: '这是转写出来的话', source: kSegmentVoice, path: '/tmp/a.m4a'),
      ];
      expect(composer.rawContentOf(segs), '开头\n\n这是转写出来的话');
      expect(composer.hasVoice(segs), isTrue);
    });

    test('空段列表不炸', () {
      expect(composer.rawContentOf(const <AppendixEntry>[]), '');
      expect(composer.primaryPathOf(const <AppendixEntry>[]), isNull);
      expect(composer.hasVoice(const <AppendixEntry>[]), isFalse);
    });
  });
}
