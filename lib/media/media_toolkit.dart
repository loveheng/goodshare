import 'package:flutter/services.dart';

/// 跨端媒体能力接口（media-native P1，ADR：decisions.md「media-native」节）。
///
/// 目标：以平台原生 API（Android MediaMetadataRetriever / MediaExtractor，
/// iOS 对应 AVFoundation）替换 FFprobeKit 的**只读元数据**探测——probe 不解码
/// 不转码，开销同读文件头，符合「抛弃 FFmpeg 软编软解」拍板。
///
/// 失败契约（与原 FFprobeKit 版一致）：探测失败返回 **null 非阻断**，调用方自行
/// 降级（时长未知 = 跳过长视频提示；编码未知 = 走默认容器 + 重编码回落）。
/// iOS 未适配（无原生 handler）经 MissingPluginException 同走 null。
abstract class MediaToolkit {
  /// 探测视频/音频时长（毫秒）；失败 null。
  Future<int?> videoDurationMs(String path);

  /// 提取视频封面帧（2026-10-03「视频加封面」）：JPEG 字节（宽 ≤720）；
  /// 失败 / 格式解不了返回 null（调用方图标占位降级）。
  Future<Uint8List?> videoCover(String path);

  /// 探测首条音轨的编码标识（Android 侧为 MIME，如 `audio/mp4a-latm`；
  /// 经 [audioCodecNameFromMime] 归一后使用）。失败或无音轨返回 null。
  Future<String?> audioCodec(String path);

  /// 解码首条音轨为 **raw s16le 单声道** PCM 文件（不带头，供
  /// resamplePcmFileToWav16k 续接 WAV 封装；media-native P2）。
  /// [startMs]/[endMs] 毫秒区间（null = 整段）。失败 / 无音轨 / 格式解不了
  /// 返回 null。流式解码内存有界，原始多声道不落盘。
  Future<DecodedPcmInfo?> decodeMonoPcm(
    String path,
    String outFile, {
    int? startMs,
    int? endMs,
  });

  /// 区间 trim 导出 mp4（media-native P3，media3 Transformer 硬编，
  /// 替代 libx264 精确重编码）。[startMs] < [endMs] 毫秒。失败返回 null。
  Future<TrimResult?> trimVideo(
    String path,
    String outFile, {
    required int startMs,
    required int endMs,
  });

  /// 音轨导出（media-native P4，替代 ffmpeg 提取链路）。[format] ∈
  /// `copy`（按源编码选容器流复制）/`m4a`/`flac`/`wav`（解码重编码）。
  /// 失败（无音轨/容器装不下/编码器缺失）返回 null，调用方按 R1 给文案。
  Future<int?> exportAudio(
    String path,
    String outFile, {
    required String format,
  });
}

/// [MediaToolkit.decodeMonoPcm] 产物元数据：源采样率（重采样入参）与
/// 实际写出的单声道帧数。
class DecodedPcmInfo {
  const DecodedPcmInfo({required this.sampleRate, required this.frames});

  final int sampleRate;
  final int frames;
}

/// [MediaToolkit.trimVideo] 产物元数据。
class TrimResult {
  const TrimResult({required this.path, required this.bytes});

  final String path;
  final int bytes;
}

class MethodChannelMediaToolkit implements MediaToolkit {
  MethodChannelMediaToolkit({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('goodshare/media');

  final MethodChannel _channel;

  @override
  Future<int?> videoDurationMs(String path) async {
    try {
      return await _channel.invokeMethod<int>('videoDurationMs', path);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<Uint8List?> videoCover(String path) async {
    try {
      return await _channel.invokeMethod<Uint8List>('videoCover', path);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<String?> audioCodec(String path) async {
    try {
      return await _channel.invokeMethod<String>('audioCodec', path);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<DecodedPcmInfo?> decodeMonoPcm(
    String path,
    String outFile, {
    int? startMs,
    int? endMs,
  }) async {
    try {
      final r = await _channel.invokeMethod<Object?>('decodeMonoPcm', {
        'path': path,
        'out': outFile,
        'startMs': startMs,
        'endMs': endMs,
      });
      if (r is! Map) return null;
      final rate = (r['sampleRate'] as num?)?.toInt() ?? 0;
      final frames = (r['frames'] as num?)?.toInt() ?? 0;
      if (rate <= 0 || frames <= 0) return null;
      return DecodedPcmInfo(sampleRate: rate, frames: frames);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<TrimResult?> trimVideo(
    String path,
    String outFile, {
    required int startMs,
    required int endMs,
  }) async {
    try {
      final r = await _channel.invokeMethod<Object?>('trimVideo', {
        'path': path,
        'out': outFile,
        'startMs': startMs,
        'endMs': endMs,
      });
      if (r is! Map) return null;
      final bytes = (r['bytes'] as num?)?.toInt() ?? 0;
      if (bytes <= 0) return null;
      return TrimResult(path: outFile, bytes: bytes);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<int?> exportAudio(
    String path,
    String outFile, {
    required String format,
  }) async {
    try {
      return await _channel.invokeMethod<int>('exportAudio', {
        'path': path,
        'out': outFile,
        'format': format,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// 全局实例（Android 首发；iOS/鸿蒙实现同一接口后经此处替换注入）。
final MediaToolkit mediaToolkit = MethodChannelMediaToolkit();

/// 平台 MIME → ffmpeg 风格 codec 名（`extensionForCodec` 的入参域，其 SSOT 地位不变）。
///
/// 未知 MIME **原样透传**而非返回 null——返回 null 会被上游当作「无音轨」拦截，
/// 而未知编码的音轨是真实存在的（如 amr/ac3），应走 extensionForCodec 默认 m4a
/// 容器 + 重编码回落，与 FFprobe codec_name 未命中默认分支的行为一致。
String audioCodecNameFromMime(String mime) => switch (mime.toLowerCase()) {
      'audio/mp4a-latm' || 'audio/aac' => 'aac',
      'audio/mpeg' => 'mp3',
      'audio/opus' => 'opus',
      'audio/vorbis' => 'vorbis',
      'audio/flac' => 'flac',
      'audio/alac' => 'alac',
      'audio/raw' || 'audio/wav' || 'audio/x-wav' => 'pcm_s16le',
      _ => mime,
    };
