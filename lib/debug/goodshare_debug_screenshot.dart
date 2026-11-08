import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 整屏截图锚点：main.dart 包住 `GoodShareApp` 的 `RepaintBoundary` 全局 key。
final GlobalKey goodshareScreenshotBoundaryKey = GlobalKey();

/// 整屏截图：取 [goodshareScreenshotBoundaryKey] 渲染边界 → PNG 字节。
///
/// 供调试桥 `/debug/screenshot` 端点（视觉概况）调用；边界未挂载即抛错，由
/// 端点回 500（不冒充空图）。
Future<List<int>> goodshareCaptureScreenshot() async {
  final ro = goodshareScreenshotBoundaryKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('截图失败：整屏渲染边界未挂载');
  }
  final views = WidgetsBinding.instance.platformDispatcher.views;
  final pixelRatio = views.isNotEmpty ? views.first.devicePixelRatio : 1.0;
  final image = await ro.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) throw StateError('截图失败：PNG 编码为空');
  return bytes.buffer.asUint8List();
}
