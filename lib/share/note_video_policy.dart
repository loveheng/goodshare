/// 便签内嵌视频（附件态）门槛策略常量 + 后置校验。
///
/// SSOT：docs/design/note-video.md §2（2026-10-01 用户拍板）：
/// - 用户只感知时长不感知字节；同一条规则两条路径不同时机——拍摄前置限制、
///   选择后置校验。
/// - 格式白名单 **mp4/mov**（双端原生可播，不转码直接入库）；.webm/.avi/.mkv
///   等边缘格式**硬拦截提示**「暂不支持该格式」。彻底不用 FFmpeg 转码
///   （如需压缩走系统硬件编码器，另期）。
/// - 阈值常量集中于此，不散在 UI 判断里——几乎必然随真机数据调整。
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';

/// 相机直拍时长上限（image_picker maxDuration，到时自动停止，无感中断）。
const Duration noteVideoCaptureMaxDuration = Duration(seconds: 60);

/// 相册选择的时长提示阈值：超限**非阻断**提示（长视频归档是合法诉求）。
const Duration noteVideoAlbumDurationWarn = Duration(minutes: 5);

/// 相册选择的大小拦截阈值：超限提示「视频过大」，建议剪短（阻断）。
const int noteVideoAlbumMaxBytes = 100 * 1024 * 1024;

/// 附件态格式白名单（双端原生可播；不含 m3u8——附件态不做流媒体概念）。
const Set<String> noteVideoAllowedExt = {'.mp4', '.mov'};

String _extOf(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot).toLowerCase();
}

/// 后置校验（相册选择路径）：返回 null = 通过；非 null = 拦截/提示文案。
/// 调用方按 [noteVideoAlbumDurationWarn] 与硬拦截两类文案区分交互。
Future<NoteVideoCheck?> checkNoteVideoAlbum(String path) async {
  final ext = _extOf(path);
  if (!noteVideoAllowedExt.contains(ext)) {
    return const NoteVideoCheck(
        kind: NoteVideoCheckKind.unsupportedFormat);
  }
  final f = File(path);
  try {
    if (await f.length() > noteVideoAlbumMaxBytes) {
      return const NoteVideoCheck(kind: NoteVideoCheckKind.tooLarge);
    }
  } catch (_) {
    return const NoteVideoCheck(kind: NoteVideoCheckKind.unreadable);
  }
  final duration = await probeVideoDurationMs(path);
  if (duration != null && duration > noteVideoAlbumDurationWarn.inMilliseconds) {
    return const NoteVideoCheck(kind: NoteVideoCheckKind.tooLong);
  }
  return null;
}

enum NoteVideoCheckKind { unsupportedFormat, tooLarge, tooLong, unreadable }

class NoteVideoCheck {
  const NoteVideoCheck({required this.kind});

  final NoteVideoCheckKind kind;

  bool get blocking =>
      kind == NoteVideoCheckKind.unsupportedFormat ||
      kind == NoteVideoCheckKind.tooLarge ||
      kind == NoteVideoCheckKind.unreadable;
}

/// 探测视频时长（毫秒；失败返回 null 不阻断）。
/// 用 FFprobeKit **只读元数据**（不解码不转码，开销同读文件头），
/// 符合「抛弃 FFmpeg 软编软解」拍板——那条禁的是转码链路。
Future<int?> probeVideoDurationMs(String path) async {
  try {
    final session = await FFprobeKit.getMediaInformation(path);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) return null;
    final s = session.getMediaInformation()?.getDuration();
    if (s == null) return null;
    return ((double.tryParse(s) ?? 0) * 1000).round();
  } catch (_) {
    return null;
  }
}
