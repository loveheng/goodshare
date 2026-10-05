import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/media/pcm_resample.dart';

void main() {
  // 源生 s16le mono PCM 文件
  File writeRaw(String path, List<int> samples) {
    final b = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(i * 2, samples[i], Endian.little);
    }
    return File(path)..writeAsBytesSync(b.buffer.asUint8List());
  }

  List<int> readWavSamples(String path, {int headerBytes = 44}) {
    final bytes = File(path).readAsBytesSync();
    final b = ByteData.sublistView(Uint8List.fromList(bytes));
    final dataBytes = b.getUint32(40, Endian.little);
    return [
      for (var i = 0; i < dataBytes ~/ 2; i++)
        b.getInt16(44 + i * 2, Endian.little),
    ];
  }

  double rms(Iterable<int> s) {
    var acc = 0.0;
    for (final v in s) {
      acc += v * v;
    }
    return math.sqrt(acc / s.length);
  }

  /// 过零率估频（对正弦有效）：freq = crossings/2 * rate / n
  double estimateFreqHz(List<int> s, int rate) {
    var crossings = 0;
    for (var i = 1; i < s.length; i++) {
      if ((s[i - 1] < 0) != (s[i] < 0)) crossings++;
    }
    return crossings / 2 * rate / s.length;
  }

  List<int> sineSamples(double freqHz, int rate, double seconds,
      {int amp = 12000}) {
    final n = (rate * seconds).round();
    return List.generate(
        n, (i) => (amp * math.sin(2 * math.pi * freqHz * i / rate)).round());
  }

  final tmp = Directory.systemTemp;
  late File raw;
  late File wav;

  setUp(() {
    raw = File('${tmp.path}/resample_test_${DateTime.now().microsecondsSinceEpoch}.raw');
    wav = File('${raw.path}.wav');
  });

  tearDown(() {
    if (raw.existsSync()) raw.deleteSync();
    if (wav.existsSync()) wav.deleteSync();
  });

  group('resamplePcmFileToWav16k', () {
    test('48k 正弦 1kHz → 16k：频率保持、幅度保持（整数倍抽取路径）', () async {
      writeRaw(raw.path, sineSamples(1000, 48000, 1.0));
      final ok = await resamplePcmFileToWav16k(raw.path, wav.path, 48000);
      expect(ok, isTrue);
      final out = readWavSamples(wav.path);
      final head = parseWavHeader(wav.readAsBytesSync());
      expect(head['sampleRate'], 16000);
      expect(head['channels'], 1);
      expect(head['bits'], 16);
      expect(out.length, inInclusiveRange(16000 - 40, 16000 + 160),
          reason: '1s 输入应产出 ≈16k 输出帧（含滤波尾差）');
      expect(estimateFreqHz(out, 16000), closeTo(1000, 15),
          reason: '频率不得漂移（ASR 时间轴依赖）');
      expect(rms(out), closeTo(12000 / math.sqrt2, 12000 * 0.05),
          reason: '带内增益须接近 1');
    });

    test('44.1k 正弦 1kHz → 16k：分数比路径频率保持', () async {
      writeRaw(raw.path, sineSamples(1000, 44100, 1.0));
      final ok = await resamplePcmFileToWav16k(raw.path, wav.path, 44100);
      expect(ok, isTrue);
      final out = readWavSamples(wav.path);
      expect(out.length, inInclusiveRange(16000 - 40, 16000 + 160));
      expect(estimateFreqHz(out, 16000), closeTo(1000, 15));
    });

    test('48k 正弦 12kHz（超新奈奎斯特）→ 16k：抗混叠（残差能量 <1%）', () async {
      writeRaw(raw.path, sineSamples(12000, 48000, 0.5));
      await resamplePcmFileToWav16k(raw.path, wav.path, 48000);
      final out = readWavSamples(wav.path);
      expect(rms(out), lessThan(12000 / math.sqrt2 * 0.01),
          reason: '超带分量须被阻带抑制，防混叠污染识别输入');
    });

    test('8k → 16k 上采样：带内正弦保持（插值路径）', () async {
      writeRaw(raw.path, sineSamples(500, 8000, 1.0));
      final ok = await resamplePcmFileToWav16k(raw.path, wav.path, 8000);
      expect(ok, isTrue);
      final out = readWavSamples(wav.path);
      expect(out.length, inInclusiveRange(16000 - 40, 16000 + 160));
      expect(estimateFreqHz(out, 16000), closeTo(500, 10));
      expect(rms(out), closeTo(12000 / math.sqrt2, 12000 * 0.05));
    });

    test('DC 常量：增益精确为 1（逐相归一 Σh=1）', () async {
      writeRaw(raw.path, List.filled(4800, 1000));
      await resamplePcmFileToWav16k(raw.path, wav.path, 48000);
      final out = readWavSamples(wav.path);
      final mid = out.sublist(out.length ~/ 4, out.length * 3 ~/ 4);
      for (final v in mid) {
        expect(v, 1000, reason: '直流不得偏置（时间轴零点漂移）');
      }
    });

    test('静音输入产出全零 WAV', () async {
      writeRaw(raw.path, List.filled(48000, 0));
      final ok = await resamplePcmFileToWav16k(raw.path, wav.path, 48000);
      expect(ok, isTrue);
      final out = readWavSamples(wav.path);
      expect(out.every((v) => v == 0), isTrue);
    });

    test('异常入参：采样率非法 / 文件缺失 / 空文件 → false', () async {
      writeRaw(raw.path, [1, 2, 3]);
      expect(await resamplePcmFileToWav16k(raw.path, wav.path, 0), isFalse);
      expect(
          await resamplePcmFileToWav16k('${raw.path}.missing', wav.path, 48000),
          isFalse);
      File('${raw.path}.empty').writeAsBytesSync([]);
      expect(await resamplePcmFileToWav16k('${raw.path}.empty', wav.path, 48000),
          isFalse);
    });

    test('16k 同率直通：仅补 WAV 头不重采样', () async {
      writeRaw(raw.path, sineSamples(1000, 16000, 0.5));
      final ok = await resamplePcmFileToWav16k(raw.path, wav.path, 16000);
      expect(ok, isTrue);
      final out = readWavSamples(wav.path);
      expect(out.length, 8000);
      expect(parseWavHeader(wav.readAsBytesSync())['sampleRate'], 16000);
    });
  });
}
