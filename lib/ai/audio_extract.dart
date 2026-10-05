import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../media/media_toolkit.dart';

/// 音轨提取（2026-09-28 建，media-native P4 起走原生导出）：
/// 把音频 / 视频条目的音轨导出成独立音频文件。
///
/// **原生能力分派**（MediaBridge.exportAudio，详见其注释）：
/// - **流复制**（copy）：按源编码选容器——aac/alac→m4a、opus/vorbis→ogg 走
///   MediaMuxer 逐样本搬移（无损、秒出）；mp3→原始流拼接；flac→「fLaC」+csd
///   封装；pcm→WAV 头封装；装不下的编码回落重编码 m4a（与旧 ffmpeg 行为一致）。
/// - **重编码**（m4a/flac/wav）：解码 → 系统编码器（AAC-LC / FLAC）→ 容器。
///   重编码能力受设备编码器表约束（flac 编码器缺失时明确报错，R1）。
///
/// 「源编码 → 目标容器」映射 [extensionForCodec] 仍是 SSOT（MIME 归一由
/// media_toolkit.audioCodecNameFromMime 供给）。

/// 导出目标格式。
enum AudioExportFormat {
  copy('跟随原格式（无损复制，最快）'),
  m4a('M4A / AAC（通用性最好）'),
  flac('FLAC（无损压缩）'),
  wav('WAV（无损，体积最大）');

  const AudioExportFormat(this.label);

  final String label;
}

/// 源音频编码 → 目标扩展名（流复制时据此选容器）。
///
/// 纯函数（不碰文件系统），便于单测；未知编码回落 `m4a`（mp4 容器能装 aac，
/// 且系统 aac 编码器可兜底重编码）。
String extensionForCodec(String? codec) => switch ((codec ?? '').toLowerCase()) {
      'aac' || 'alac' => 'm4a',
      'mp3' => 'mp3',
      'opus' || 'vorbis' => 'ogg', // 两者都以 ogg 为容器
      'flac' => 'flac',
      'pcm_s16le' || 'pcm_s24le' || 'pcm_s32le' || 'pcm_u8' => 'wav',
      _ => 'm4a',
    };

/// 音轨提取器：`documents/exports/` 下产出文件，返回路径供分享。
class AudioExtractor {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'exports'));
    await d.create(recursive: true);
    return d;
  }

  /// 探测首条音轨的编码（供流复制选容器）。探测失败返回 null，由调用方兜底。
  static Future<String?> probeAudioCodec(String input) async {
    try {
      final mime = await mediaToolkit.audioCodec(input);
      if (mime == null) return null;
      return audioCodecNameFromMime(mime);
    } catch (e) {
      debugPrint('[AudioExtractor] probe failed: $e');
      return null;
    }
  }

  /// 提取音轨。**失败必须带回具体原因**（2026-09-28 决策：错误要被用户感知），
  /// 调用方直接展示 [AudioExtractResult.error]，不要自己猜一句通用文案。
  ///
  /// [format] = [AudioExportFormat.copy] 时按源编码选容器并走流复制；
  /// 其余走系统编码器重编码。
  ///
  /// [fileStem] 输出文件名 stem 覆盖（块附件通道必传 [blockFileStem(blockKey)]
  /// 产物 stem——2026-10-05 碰撞修复：缺省 stem=itemId 时同一便签内多个视频块
  /// 的音轨互相覆盖，叠加「删行必删盘」会误删其他块正在引用的物理文件）。
  static Future<AudioExtractResult> extract(
    String input, {
    AudioExportFormat format = AudioExportFormat.copy,
    String? itemId,
    String? fileStem,
  }) async {
    final src = File(input);
    if (!src.existsSync()) {
      return const AudioExtractResult.error('源文件不存在或已被清理');
    }
    final codec = await probeAudioCodec(input);
    if (codec == null) {
      // 视频无音轨 / 探测失败：明确失败好过产出空文件
      return const AudioExtractResult.error('文件里没有可提取的音轨（可能是纯视频或已损坏）');
    }
    final dir = await _dir();
    final stem = fileStem ?? itemId ?? p.basenameWithoutExtension(input);
    final ext = format == AudioExportFormat.copy ? extensionForCodec(codec) : format.name;
    final out = File(p.join(dir.path, '$stem.$ext'));
    final bytes = await mediaToolkit.exportAudio(input, out.path, format: format.name);
    if (bytes != null) {
      debugPrint('[AudioExtractor] -> ${out.path} ($format, $bytes bytes)');
      return AudioExtractResult.ok(out.path);
    }
    // 流复制失败（容器装不下该编码，如 amr → m4a）时兜底重编码为 aac
    if (format == AudioExportFormat.copy) {
      debugPrint('[AudioExtractor] copy failed, fallback to aac: $input');
      final fallback = File(p.join(dir.path, '$stem.m4a'));
      final r2 =
          await mediaToolkit.exportAudio(input, fallback.path, format: 'm4a');
      if (r2 != null) {
        return AudioExtractResult.ok(fallback.path);
      }
      return AudioExtractResult.error(
        '导出失败：源编码 $codec 无法写入所选格式（已尝试回落 M4A 仍失败），可换 M4A / WAV 重试',
      );
    }
    final hint = format == AudioExportFormat.flac
        ? '该设备可能缺少 FLAC 编码器，可换 M4A / WAV'
        : '可换 M4A / WAV 重试';
    return AudioExtractResult.error(
      '导出失败：源编码 $codec 无法写入所选格式（${format.name}），$hint',
    );
  }
}

/// 提取结果：成功给路径，失败给**具体原因**（供 UI 原样展示）。
class AudioExtractResult {
  const AudioExtractResult._({this.path, this.error});

  const AudioExtractResult.ok(String path) : this._(path: path);

  const AudioExtractResult.error(String message) : this._(error: message);

  final String? path;
  final String? error;

  bool get ok => path != null;
}
