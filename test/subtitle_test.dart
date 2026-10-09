import 'package:goodshare/ai/subtitle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cues = [
    const AsrCue(start: 0.0, duration: 2.5, text: '你好世界'),
    const AsrCue(start: 3.2, duration: 4.8, text: '  '), // 空白：应被过滤
    const AsrCue(start: 65.0, duration: 1.0, text: 'second minute'),
    const AsrCue(start: 3671.5, duration: 2.0, text: 'end'),
  ];

  group('formatTimestamp', () {
    test('SRT 用逗号毫秒分隔', () {
      expect(formatTimestamp(0, decimal: ','), '00:00:00,000');
      expect(formatTimestamp(2.5, decimal: ','), '00:00:02,500');
      expect(formatTimestamp(65.0, decimal: ','), '00:01:05,000');
      // 3671.5s = 1:01:11.5 → 舍入为 3671500ms = 01:01:11,500
      expect(formatTimestamp(3671.5, decimal: ','), '01:01:11,500');
    });

    test('VTT 用点毫秒分隔', () {
      expect(formatTimestamp(2.5, decimal: '.'), '00:00:02.500');
      expect(formatTimestamp(3671.5, decimal: '.'), '01:01:11.500');
    });

    test('负值钳到 0', () {
      expect(formatTimestamp(-1, decimal: ','), '00:00:00,000');
    });

    test('毫秒进位不丢（0.9995s → 1000ms → 00:00:01,000）', () {
      expect(formatTimestamp(0.9995, decimal: ','), '00:00:01,000');
    });
  });

  group('translationLangOf（译文文件识别）', () {
    test('主文件不是译文文件', () {
      expect(translationLangOf('id1', 'id1.srt'), isNull);
      expect(translationLangOf('id1', 'id1.vtt'), isNull);
    });

    test('译文文件解析出目标语言', () {
      expect(translationLangOf('id1', 'id1.zh.srt'), 'zh');
      expect(translationLangOf('id1', 'id1.ja.vtt'), 'ja');
    });

    test('别的条目 / 别的扩展名不算', () {
      expect(translationLangOf('id1', 'id2.zh.srt'), isNull);
      expect(translationLangOf('id1', 'id1.zh.txt'), isNull);
    });
  });

  group('usableCues', () {
    test('过滤 trim 后为空的 cue', () {
      final r = usableCues(cues);
      expect(r.length, 3);
      expect(r.every((c) => c.text.trim().isNotEmpty), isTrue);
    });

    test('过滤纯标点 cue（ASR 无语音段只吐标点，如单个 .）', () {
      const dotCues = [
        AsrCue(start: 0.0, duration: 1.0, text: '.'),
        AsrCue(start: 1.5, duration: 1.0, text: '。。。'),
        AsrCue(start: 3.0, duration: 1.0, text: '！？…“”'),
        AsrCue(start: 4.0, duration: 1.0, text: '好'),
      ];
      final r = usableCues(dotCues);
      expect(r.single.text, '好');
    });

    test('含字母/数字的 cue 保留（含标点包裹）', () {
      const mixed = [
        AsrCue(start: 0.0, duration: 1.0, text: '3 个'),
        AsrCue(start: 1.0, duration: 1.0, text: '(a)'),
        AsrCue(start: 2.0, duration: 1.0, text: '👍'), // 无字母数字：纯符号
      ];
      final r = usableCues(mixed);
      expect(r.map((c) => c.text), ['3 个', '(a)']);
    });
  });

  group('parseSrtVtt', () {
    test('纯标点 cue 块被丢弃（与 usableCues 同口径，序号对齐）', () {
      const srt = '''
1
00:00:00,000 --> 00:00:01,000
.

2
00:00:01,000 --> 00:00:02,000
你好
''';
      final r = parseSrtVtt(srt);
      expect(r.single.text, '你好');
    });

    test('与 serializeSrt 往返一致', () {
      const src = [
        AsrCue(start: 0.0, duration: 1.0, text: '.'),
        AsrCue(start: 1.0, duration: 1.0, text: 'end'),
      ];
      final r = parseSrtVtt(serializeSrt(src));
      expect(r.map((c) => c.text), ['end']);
    });
  });

  group('serializeSrt', () {
    test('序号从 1 起、条目间空行、时间戳逗号', () {
      final s = serializeSrt(cues);
      expect(s, '''
1
00:00:00,000 --> 00:00:02,500
你好世界

2
00:01:05,000 --> 00:01:06,000
second minute

3
01:01:11,500 --> 01:01:13,500
end

''');
    });

    test('空输入产出空文件内容', () {
      expect(serializeSrt(const []), isEmpty);
    });
  });

  group('serializeVtt', () {
    test('首行 WEBVTT、无序号、时间戳点、条目间空行', () {
      final s = serializeVtt(cues);
      expect(s, '''
WEBVTT

00:00:00.000 --> 00:00:02.500
你好世界

00:01:05.000 --> 00:01:06.000
second minute

01:01:11.500 --> 01:01:13.500
end
''');
    });

    test('空输入仅含头行', () {
      expect(serializeVtt(const []), 'WEBVTT\n');
    });
  });

  group('AsrCue JSON 往返', () {
    test('toJson/fromJson 保真', () {
      const c = AsrCue(start: 1.5, duration: 2.25, text: 'x');
      final r = AsrCue.fromJson(c.toJson());
      expect(r.start, c.start);
      expect(r.duration, c.duration);
      expect(r.text, c.text);
    });
  });
}
