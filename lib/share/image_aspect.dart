import 'dart:io';

import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;

/// 摄入时探测图片宽高比（rich-text-component.md §6.1 V1 尺寸前置）。
///
/// 只解析图片头拿宽高（[ui.ImageDescriptor.encodedBuffer] 不触发像素解码），
/// 不整图解码、不落额外内存；渲染处拿这个比例提前摆好版面，消灭加载抖动。
/// 探测失败（文件缺失/非图片/解码器不认）返回 null——渲染退回无占位旧路径，
/// **不挡摄入**；失败原因打日志可观测。
Future<double?> probeImageAspect(String path) async {
  ui.ImmutableBuffer? buffer;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final ratio = descriptor.height == 0 ? null : descriptor.width / descriptor.height;
    descriptor.dispose();
    return ratio;
  } catch (e) {
    debugPrint('[DEGRADE] image_aspect_probe_failed path=$path error=$e');
    return null;
  } finally {
    buffer?.dispose();
  }
}
