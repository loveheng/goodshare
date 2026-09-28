import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 音轨提取（2026-09-28）：把音频 / 视频条目的音轨导出成独立音频文件。
///
/// **硬约束**：当前 ffmpeg 是 **min 变体**，README 包表的 min 列「external libraries」= `-`
/// ——没有任何外部库，因此**不能凭空编码** mp3 / vorbis / opus（分别需要
/// lame / libvorbis / libopus，只在 audio 及以上变体才有）。
///
/// 出路有两条，组合起来就是本期支持的全部格式：
/// ① **流复制**（`-c:a copy`）：不需要任何编码器，源是什么编码就原样搬进目标容器，
///    无损、秒出——源为 mp3 / opus / vorbis 时照样能导出 mp3 / ogg；
/// ② **内置编码器**：ffmpeg 自带 `aac` / `flac` / `pcm_s16le`，可重编码为 m4a / flac / wav。
///
/// 因此默认策略是「跟随原格式无损复制」，转码只作为用户显式选择（兼容性 / 无损归档）。

/// 导出目标格式。[encoder] 为 null 表示**流复制**（无损、不需要编码器）。
enum AudioExportFormat {
  copy('跟随原格式（无损复制，最快）', null),
  m4a('M4A / AAC（通用性最好）', 'aac'),
  flac('FLAC（无损压缩）', 'flac'),
  wav('WAV（无损，体积最大）', 'pcm_s16le');

  const AudioExportFormat(this.label, this.encoder);

  final String label;

  /// ffmpeg 编码器名；null = `-c:a copy`。
  final String? encoder;
}

/// 源音频编码 → 目标扩展名（流复制时据此选容器）。
///
/// 纯函数（不碰文件系统），便于单测；未知编码回落 `m4a`（mp4 容器能装 aac，
/// 且 ffmpeg 内置 aac 编码器可兜底重编码）。
String extensionForCodec(String? codec) => switch ((codec ?? '').toLowerCase()) {
      'aac' || 'alac' => 'm4a',
      'mp3' => 'mp3',
      'opus' || 'vorbis' => 'ogg', // 两者都以 ogg 为容器
      'flac' => 'flac',
      'pcm_s16le' || 'pcm_s24le' || 'pcm_s32le' || 'pcm_u8' => 'wav',
      _ => 'm4a',
    };

/// 构造提取命令参数（纯函数，便于单测）。
/// `-vn` 丢视频轨、`-map 0:a:0` 只取首条音轨（多语言音轨场景取默认那条）。
List<String> buildExtractArgs(String input, String output, String encoder) =>
    ['-y', '-i', input, '-vn', '-map', '0:a:0', '-c:a', encoder, output];

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
      final session = await FFprobeKit.execute(
        '-v error -select_streams a:0 -show_entries stream=codec_name '
        '-of default=noprint_wrappers=1:nokey=1 "$input"',
      );
      final out = (await session.getOutput())?.trim() ?? '';
      if (out.isEmpty) return null;
      return out.split('\n').first.trim();
    } catch (e) {
      debugPrint('[AudioExtractor] probe failed: $e');
      return null;
    }
  }

  /// 提取音轨。**失败必须带回具体原因**（2026-09-28 决策：错误要被用户感知），
  /// 调用方直接展示 [AudioExtractResult.error]，不要自己猜一句通用文案。
  ///
  /// [format] = [AudioExportFormat.copy] 时按源编码选容器并走 `-c:a copy`；
  /// 其余用内置编码器重编码。
  static Future<AudioExtractResult> extract(
    String input, {
    AudioExportFormat format = AudioExportFormat.copy,
    String? itemId,
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
    final stem = itemId ?? p.basenameWithoutExtension(input);
    final ext = format == AudioExportFormat.copy ? extensionForCodec(codec) : format.name;
    final out = File(p.join(dir.path, '$stem.$ext'));
    final encoder = format.encoder ?? 'copy';
    final args = buildExtractArgs(input, out.path, encoder);
    final session = await FFmpegKit.executeWithArguments(args);
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      // 流复制失败（容器装不下该编码，如 opus → mp4）时兜底重编码为 aac
      if (format == AudioExportFormat.copy) {
        debugPrint('[AudioExtractor] copy failed, fallback to aac: $input');
        final fallback = File(p.join(dir.path, '$stem.m4a'));
        final s2 = await FFmpegKit.executeWithArguments(
          buildExtractArgs(input, fallback.path, 'aac'),
        );
        if (ReturnCode.isSuccess(await s2.getReturnCode())) {
          return AudioExtractResult.ok(fallback.path);
        }
      }
      debugPrint('[AudioExtractor] extract failed: $input');
      return AudioExtractResult.error(
        '导出失败：源编码 $codec 无法写入所选格式'
        '${format == AudioExportFormat.copy ? '（已尝试回落 M4A 仍失败）' : ''}，可换 M4A / WAV 重试',
      );
    }
    debugPrint('[AudioExtractor] -> ${out.path} ($encoder)');
    return AudioExtractResult.ok(out.path);
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
