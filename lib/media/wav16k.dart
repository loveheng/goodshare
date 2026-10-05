import 'dart:io';

import 'pcm_resample.dart';
import 'media_toolkit.dart';

/// 把任意音频/视频输入解码为 16kHz 单声道 WAV（media-native P2，替代 ffmpeg
/// `-ar 16000 -ac 1 -c:a pcm_s16le` 转码链路）。
///
/// 分工：原生（MediaExtractor+MediaCodec）解码并下混单声道落 raw PCM 临时文件；
/// Dart 在 isolate 内做 16k 重采样 + WAV 封装（纯函数可单测，见 pcm_resample.dart）。
/// 产物契约与 ffmpeg 版一致（44 字节标准头 / s16le / mono / 16000Hz），
/// sherpa `readWave` 侧零改动。
///
/// 失败（无音轨 / 格式原生解不了 / IO 异常）返回 false，调用方按 R1 给
/// 「格式不支持或文件损坏」类可行动文案，不做静默成功。冷门格式云端处理
/// 为后续规划（todos goodshare·候），现阶段一律降级。
Future<bool> extractWav16k(
  String input,
  String outputWav, {
  int? startMs,
  int? endMs,
  MediaToolkit? toolkit,
}) async {
  final raw = File('$outputWav.raw');
  try {
    final info = await (toolkit ?? mediaToolkit)
        .decodeMonoPcm(input, raw.path, startMs: startMs, endMs: endMs);
    if (info == null || !await raw.exists() || await raw.length() < 2) {
      return false;
    }
    return await resamplePcmFileToWav16k(raw.path, outputWav, info.sampleRate);
  } catch (_) {
    return false;
  } finally {
    try {
      if (await raw.exists()) await raw.delete();
    } catch (_) {
      // 临时文件清理失败不阻断主流程
    }
  }
}
