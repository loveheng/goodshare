import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// 16k 单声道 PCM→WAV 重采样（media-native P2，纯 Dart 零 Flutter 依赖——
/// 可在 VM 单测；设计 ADR 见 decisions.md「media-native」节）。
///
/// Android 无系统重采样 API（iOS AVAudioConverter 白送），故在 Dart 侧实现
/// windowed-sinc 多相重采样：黑曼窗 + 逐相归一（Σh=1 保证 DC 增益精确），
/// 相位量化到 1024 bank（残差 ≤ 1/2048 输入样本，对 ASR 无感）。
/// 64 taps @ 输出率 16k ≈ 1M MAC/s 音频，AOT 下 1 小时音源秒级完成，
/// 且必须经 [resamplePcmFileToWav16k] 在 isolate 中跑（主 isolate 禁重活）。

const int kWav16kSampleRate = 16000;
const int _taps = 64;
const int _half = _taps ~/ 2;
const int _phases = 1024;

/// raw s16le 单声道 PCM 文件 → 16kHz 单声道 WAV 文件。
/// 在独立 isolate 执行（IO + 数值重活均不占主 isolate）；失败返回 false。
Future<bool> resamplePcmFileToWav16k(String rawPath, String wavPath, int srcRate) =>
    Isolate.run(() => _resampleSync(rawPath, wavPath, srcRate));

Future<bool> _resampleSync(String rawPath, String wavPath, int srcRate) async {
  final raw = File(rawPath);
  if (srcRate <= 0 || !raw.existsSync()) return false;
  final inLen = raw.lengthSync();
  if (inLen < 2 || inLen.isOdd) return false;

  final out = File(wavPath).openSync(mode: FileMode.write);
  try {
    _writeWavHeaderPlaceholder(out);
    var outFrames = 0;
    if (srcRate == kWav16kSampleRate) {
      // 同率直通：免重采样，仅补 WAV 头
      var copied = 0;
      await for (final List<int> chunk in raw.openRead()) {
        copied += chunk.length;
        out.writeFromSync(chunk);
      }
      outFrames = copied ~/ 2;
    } else {
      final rs = _StreamingResampler(srcRate, kWav16kSampleRate);
      final bytes = BytesBuilder(copy: false);
      var pending = <int>[];
      void drain({bool flush = false}) {
        final produced = flush ? rs.flush() : rs.push(pending);
        pending = <int>[];
        if (produced.isEmpty) return;
        final b = ByteData(produced.length * 2);
        for (var i = 0; i < produced.length; i++) {
          b.setInt16(i * 2, produced[i], Endian.little);
        }
        out.writeFromSync(b.buffer.asUint8List());
        outFrames += produced.length;
      }

      await for (final List<int> chunk in raw.openRead()) {
        bytes.add(chunk);
        final data = bytes.toBytes();
        bytes.clear();
        final usable = data.length & ~1; // 留半个样本给下一块
        if (usable > 0) {
          final shorts = Int16List.view(
              data.buffer, data.offsetInBytes, usable ~/ 2);
          pending.addAll(shorts);
        }
        if (data.length.isOdd) bytes.addByte(data.last);
        drain();
      }
      // 收尾：把留存的半个样本并入
      final tail = bytes.toBytes();
      if (tail.length >= 2) {
        pending.add(ByteData.view(tail.buffer, tail.offsetInBytes, 1)
            .getInt16(0, Endian.little));
      }
      drain(flush: true);
    }
    _patchWavHeader(out, outFrames * 2);
    return outFrames > 0;
  } finally {
    out.closeSync();
  }
}

// ---------------------------------------------------------------------------
// 流式多相重采样器
// ---------------------------------------------------------------------------

class _StreamingResampler {
  _StreamingResampler(this.srcRate, this.dstRate)
      : _banks = _buildBanks(srcRate, dstRate);

  final int srcRate;
  final int dstRate;
  final List<Float64List> _banks;

  final List<int> _buf = <int>[]; // 待消费输入（s16 数值域）
  int _consumed = 0; // _buf[0] 的绝对输入索引
  int _nextOut = 0; // 下一个输出样本索引

  /// 追加输入，返回「支撑窗口已齐」的输出样本。
  List<int> push(List<int> samples) {
    _buf.addAll(samples);
    return _drain(finalFlush: false);
  }

  /// 输入结束，返回剩余输出（右补零至支撑窗完全滑出数据域），此后不得再 push。
  List<int> flush() => _drain(finalFlush: true);

  List<int> _drain({required bool finalFlush}) {
    final out = <int>[];
    while (true) {
      final pos = _nextOut * srcRate / dstRate;
      final c = pos.floor();
      final lastAvail = _consumed + _buf.length - 1;
      final supportComplete = c + _half <= lastAvail;
      if (!supportComplete) {
        // flush 时右侧零补：支撑窗与数据域不再相交才停，否则等待更多输入
        if (!finalFlush || c - _half > lastAvail) break;
      }

      final frac = pos - c;
      final bank = _banks[((frac * _phases).round() % _phases)];
      var acc = 0.0;
      for (var k = 0; k < _taps; k++) {
        final idx = c - _half + k;
        if (idx >= _consumed && idx <= lastAvail) {
          acc += bank[k] * _buf[idx - _consumed];
        } // 窗外（开头/结尾）按零填充
      }
      out.add(acc.round().clamp(-32768, 32767));
      _nextOut++;
    }
    // 回收头部：下一个输出所需的最小输入索引之前的数据可丢弃
    final minNeeded =
        (_nextOut * srcRate ~/ dstRate) - _half - 1;
    final drop = (minNeeded - _consumed).clamp(0, _buf.length);
    if (drop > 0) {
      _buf.removeRange(0, drop);
      _consumed += drop;
    }
    return out;
  }
}

/// 黑曼窗 sinc 多相滤波器组，逐相归一 Σh=1（DC 增益精确为 1）。
List<Float64List> _buildBanks(int srcRate, int dstRate) {
  // 截止频率（输入样本率归一）：抗混叠下采样时压到目标奈奎斯特的 0.9；
  // 上/同采样时只做平滑插值，不压带。
  final fc = 0.9 * 0.5 * math.min(1.0, dstRate / srcRate);
  return List<Float64List>.generate(_phases, (m) {
    final frac = m / _phases;
    final h = Float64List(_taps);
    for (var k = 0; k < _taps; k++) {
      final t = (k - _half) - frac;
      final x = math.pi * fc * t;
      final sinc = x == 0 ? 1.0 : math.sin(x) / x;
      final wN = (t + _half) / _taps;
      final w = 0.42 -
          0.5 * math.cos(2 * math.pi * wN) +
          0.08 * math.cos(4 * math.pi * wN);
      h[k] = fc * sinc * w;
    }
    final sum = h.fold<double>(0, (a, b) => a + b);
    if (sum != 0) {
      for (var k = 0; k < _taps; k++) {
        h[k] /= sum;
      }
    }
    return h;
  });
}

// ---------------------------------------------------------------------------
// WAV 容器（44 字节标准头，PCM s16le mono）
// ---------------------------------------------------------------------------

void _writeWavHeaderPlaceholder(RandomAccessFile out) {
  out.writeFromSync(Uint8List(44));
}

void _patchWavHeader(RandomAccessFile out, int dataBytes) {
  final h = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      h.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  h.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // mono
  h.setUint32(24, kWav16kSampleRate, Endian.little);
  h.setUint32(28, kWav16kSampleRate * 2, Endian.little); // byte rate
  h.setUint16(32, 2, Endian.little); // block align
  h.setUint16(34, 16, Endian.little); // bits
  ascii(36, 'data');
  h.setUint32(40, dataBytes, Endian.little);
  out.setPositionSync(0);
  out.writeFromSync(h.buffer.asUint8List());
}

/// 解析 WAV 头（单测辅助）：返回 {sampleRate, channels, bits, dataBytes}。
Map<String, int> parseWavHeader(List<int> bytes) {
  final b = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 44)));
  return {
    'sampleRate': b.getUint32(24, Endian.little),
    'channels': b.getUint16(22, Endian.little),
    'bits': b.getUint16(34, Endian.little),
    'dataBytes': b.getUint32(40, Endian.little),
  };
}
