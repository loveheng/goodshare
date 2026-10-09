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
/// **分段滚动拼接（2026-10-09 修长文本分享）**：`RepaintBoundary.toImage()`
/// 只能捕获视口内已绘制内容——滚动视图惰性布局，屏外块未参与绘制，直接
/// 截只会得到一张屏幕截图（长文本被截断、8000px 阈值永不触发、PDF 兜底
/// 成死代码）。改为：驱动页面真实滚动 → 逐屏 `toImage` → 纵向拼接长图；
/// 总高以稳定后的 `maxScrollExtent + viewportDimension` 实测，阈值真正生效。
class BodyScreenshotRenderer {
  BodyScreenshotRenderer._();

  /// 超过此等效高度（逻辑 px）放弃截图，调用方降级 PDF。
  static const double kMaxRenderHeight = 8000;

  /// 懒加载 maxExtent 稳定判定容差（逻辑 px）。
  static const double _extentEps = 0.5;

  /// 驱动 [controller] 分段滚动，逐屏截图后纵向拼接为完整长图落临时目录。
  ///
  /// [boundaryKey] 须指向包住整个滚动视图的 RepaintBoundary；调用方负责
  /// 截图窗口内隐藏浮动 AppBar/底栏（否则悬浮层会烙进每屏截图顶部）。
  /// 总高超 [kMaxRenderHeight] 抛 [TooTallException]，由调用方降级 PDF。
  /// 完成后滚动位置停在底部，调用方自行还原。
  static Future<String> renderScrollableToFile(
    GlobalKey boundaryKey,
    ScrollController controller, {
    double designWidth = 1080,
  }) async {
    final ctx = boundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      throw StateError('分享渲染失败：未找到正文渲染边界');
    }
    if (!controller.hasClients) {
      throw StateError('分享渲染失败：滚动视图未挂载');
    }
    final logicalWidth = ro.size.width;
    if (logicalWidth <= 0) throw StateError('分享渲染失败：正文宽度异常');
    final scale = designWidth / logicalWidth;

    // 预探总高：跳到底部反复等懒加载 sliver 把 extent 补全，直到稳定。
    double maxExtent = await _stabilizedMaxExtent(controller);
    final viewport = controller.position.viewportDimension;
    if (viewport <= 0) throw StateError('分享渲染失败：视口高度异常');
    _checkHeight((maxExtent + viewport) * scale);

    // 逐屏截图；懒加载途中 extent 再增长则整轮重试（有界，防死循环）。
    for (var attempt = 0; ; attempt++) {
      try {
        return await _captureAndStitch(
          ro, controller, maxExtent, viewport, scale, logicalWidth, designWidth,
        );
      } on _ExtentGrewException catch (e) {
        maxExtent = e.newMaxExtent;
        _checkHeight((maxExtent + viewport) * scale);
        if (attempt >= 2) {
          // 三轮后 extent 仍不稳：按当前值收口，避免永远截不完。
          return await _captureAndStitch(
            ro, controller, maxExtent, viewport, scale, logicalWidth, designWidth,
            force: true,
          );
        }
      }
    }
  }

  static void _checkHeight(double heightAtDesign) {
    if (heightAtDesign > kMaxRenderHeight) throw const TooTallException();
  }

  /// 跳到底部等排版落定，直到 maxScrollExtent 连续两轮一致。
  static Future<double> _stabilizedMaxExtent(ScrollController controller) async {
    var prev = -1.0;
    while (true) {
      controller.jumpTo(controller.position.maxScrollExtent);
      await _settle();
      final now = controller.position.maxScrollExtent;
      if ((now - prev).abs() <= _extentEps) return now;
      prev = now;
    }
  }

  static Future<void> _settle() async {
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  static Future<String> _captureAndStitch(
    RenderRepaintBoundary ro,
    ScrollController controller,
    double maxExtent,
    double viewport,
    double scale,
    double logicalWidth,
    double designWidth, {
    bool force = false,
  }) async {
    // 采集段：[o, o+viewport)，最后补一段贴底保证覆盖到总高。
    final offsets = <double>[];
    for (double o = 0.0; o < maxExtent; o += viewport) {
      offsets.add(o);
    }
    if (offsets.isEmpty || offsets.last < maxExtent) offsets.add(maxExtent);

    final images = <ui.Image>[];
    try {
      var coveredUntil = 0.0;
      for (final o in offsets) {
        controller.jumpTo(o);
        await _settle();
        // 懒加载使 extent 增长：本轮作废重探（force 收口时不再重试）。
        if (!force && controller.position.maxScrollExtent > maxExtent + _extentEps) {
          throw _ExtentGrewException(controller.position.maxScrollExtent);
        }
        images.add(await ro.toImage(pixelRatio: scale));
        coveredUntil = o + viewport;
      }

      // 纵向拼接：各段只画未覆盖部分（贴底段裁掉与上一段的重叠）。
      final outWidth = (logicalWidth * scale).round();
      final outHeight = (coveredUntil * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      coveredUntil = 0.0;
      var index = 0;
      for (final o in offsets) {
        final img = images[index++];
        final top = coveredUntil.clamp(o, o + viewport);
        final bottom = (o + viewport).clamp(0.0, maxExtent + viewport);
        if (bottom > top) {
          final pxRatio = img.width / logicalWidth;
          final segTopPx = (top - o) * pxRatio;
          final segHeightPx = (bottom - top) * pxRatio;
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, segTopPx, img.width.toDouble(), segHeightPx),
            Rect.fromLTWH(0, top * scale, outWidth.toDouble(), (bottom - top) * scale),
            Paint(),
          );
        }
        coveredUntil = o + viewport;
      }
      final composed = await recorder.endRecording().toImage(outWidth, outHeight);
      final bytes = await composed.toByteData(format: ui.ImageByteFormat.png);
      composed.dispose();
      if (bytes == null) throw StateError('分享渲染失败：PNG 编码为空');
      final dir = await Directory.systemTemp.createTemp('goodshare_share');
      final file = File(
        '${dir.path}/shibei_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes.buffer.asUint8List());
      return file.path;
    } finally {
      for (final img in images) {
        img.dispose();
      }
    }
  }
}

/// 逐屏截图途中懒加载令总高增长：整轮重探。
class _ExtentGrewException implements Exception {
  _ExtentGrewException(this.newMaxExtent);
  final double newMaxExtent;
}

/// 内容超长：调用方应降级走 PDF 分享。
class TooTallException implements Exception {
  const TooTallException();

  @override
  String toString() => '内容过长，不适合生成图片';
}
