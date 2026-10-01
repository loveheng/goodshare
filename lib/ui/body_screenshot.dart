import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 正文离屏渲染截图（detail-two-zone.md §6 分享分流：无音视频走 PNG）。
///
/// 实现红线（预警补丁）：
/// - **复用页面既有 `RepaintBoundary`**（页面上已渲染的边界，天然继承
///   Theme/MediaQuery/Directionality）——严禁重建离屏组件树（全 App 恒
///   暗色，上下文丢失会导出白底图）；
/// - **8000px 等效高度硬阈值**：超过强制降级 PDF（1080×15000 的 ARGB
///   位图约 62MB，低端机必 OOM；内存数学确定，不等真机调参）；
/// - 渲染宽度固定设计宽度，接收方清晰度与设备无关。
///
/// 先例：annotation_export.dart（图片标注导出同机制）。
class BodyScreenshotRenderer {
  BodyScreenshotRenderer._();

  /// 超过此等效高度（逻辑 px）放弃截图，调用方降级 PDF。
  static const double kMaxRenderHeight = 8000;

  /// 渲染 [boundary] 为 PNG 落临时目录，返回文件路径。
  ///
  /// [designWidth] = 设计宽度（逻辑 px）；实际输出按 boundary 宽度与
  /// 设计宽度的比值放大 pixelRatio，保证接收方清晰度与设备无关。
  /// 超阈值抛 [_TooTallException]，由调用方降级 PDF。
  static Future<String> renderToFile(
    GlobalKey boundaryKey, {
    double designWidth = 1080,
  }) async {
    final ctx = boundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      throw StateError('分享渲染失败：未找到正文渲染边界');
    }
    final logicalSize = ro.size;
    final heightAtDesign =
        logicalSize.height * (designWidth / logicalSize.width);
    if (heightAtDesign > kMaxRenderHeight) {
      throw const TooTallException();
    }
    final pixelRatio = designWidth / logicalSize.width;
    final ui.Image image = await ro.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('分享渲染失败：PNG 编码为空');
    }
    final dir = await Directory.systemTemp.createTemp('goodshare_share');
    final file = File(
      '${dir.path}/shibei_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes.buffer.asUint8List());
    return file.path;
  }
}

/// 内容超长：调用方应降级走 PDF 分享。
class TooTallException implements Exception {
  const TooTallException();

  @override
  String toString() => '内容过长，不适合生成图片';
}
