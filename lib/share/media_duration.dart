import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../models/item.dart';

/// 摄入时探测音视频时长（毫秒），供渲染处秒显进度条总时长、省去播放前临时探测。
///
/// 镜像 image_aspect.probeImageAspect 的口径：探测失败（文件缺失/格式不支持/
/// 解码器不认）返回 null——**不挡摄入**；失败原因打日志可观测。
/// 远程 http(s) 源摄入时无本地文件可解，也返回 null（行内远程媒体改由播放时按需探测）。
Future<int?> probeMediaDuration(String path, String itemType) async {
  if (itemType != InboxItem.typeAudio && itemType != InboxItem.typeVideo) {
    return null;
  }
  final isRemote = path.startsWith('http://') || path.startsWith('https://');
  if (itemType == InboxItem.typeAudio) {
    final player = AudioPlayer();
    try {
      final dur = isRemote
          ? await player.setUrl(path)
          : await player.setFilePath(path);
      return dur?.inMilliseconds;
    } catch (e) {
      debugPrint('[DEGRADE] audio_duration_probe_failed path=$path error=$e');
      return null;
    } finally {
      await player.dispose();
    }
  }
  final controller = isRemote
      ? VideoPlayerController.networkUrl(Uri.parse(path))
      : VideoPlayerController.file(File(path));
  try {
    await controller.initialize();
    final d = controller.value.duration;
    return d.inMilliseconds > 0 ? d.inMilliseconds : null;
  } catch (e) {
    debugPrint('[DEGRADE] video_duration_probe_failed path=$path error=$e');
    return null;
  } finally {
    await controller.dispose();
  }
}
