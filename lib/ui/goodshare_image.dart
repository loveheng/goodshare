import 'dart:io';

import 'package:flutter/material.dart';

/// 统一图片渲染封装（规则二 cacheWidth 陷阱）。
///
/// Flutter 的 imageCache 以「源 + 解码参数」为键：同一张图在列表用 cacheWidth=96、
/// 详情页用原图会被当成两个缓存对象，导致重复解码、内存翻倍。集中在此封装后，
/// 调用方显式声明 cacheWidth/cacheHeight，全 App 的缩略图/大图配置口径一致可控。
/// 文件图与网络图双出口，行内媒体块与顶级媒体区共用（禁两套实现）。
class GoodshareImage extends StatelessWidget {
  const GoodshareImage({
    super.key,
    required this.file,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.cacheHeight,
    this.errorBuilder,
    this.loadingBuilder,
    this.placeholderColor,
  }) : networkUrl = null;

  const GoodshareImage.network({
    super.key,
    required String url,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.errorBuilder,
    this.loadingBuilder,
    this.placeholderColor,
  })  : file = null,
        networkUrl = url,
        cacheHeight = null;

  final File? file;
  final String? networkUrl;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;

  /// 加载完成前的占位底色（V3 主色调，rich-text-component.md §6.1）：
  /// 传入摄入探测的图片主色，消灭白闪；需外层给定界约束（如 AspectRatio）。
  final Color? placeholderColor;

  @override
  Widget build(BuildContext context) {
    // 首帧解码完成前用主色占位（配合外层 AspectRatio 即整块色底）
    final frameBuilder = placeholderColor == null
        ? null
        : (BuildContext context, Widget child, int? frame,
                bool wasSynchronouslyLoaded) =>
            frame == null ? Container(color: placeholderColor) : child;
    final fallback = errorBuilder ??
        (_, _, _) => const Icon(Icons.broken_image_outlined);

    if (file != null) {
      return Image.file(
        file!,
        fit: fit,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        gaplessPlayback: true,
        frameBuilder: frameBuilder,
        errorBuilder: fallback,
      );
    }
    return Image.network(
      networkUrl!,
      fit: fit,
      cacheWidth: cacheWidth,
      frameBuilder: frameBuilder,
      loadingBuilder: loadingBuilder,
      errorBuilder: fallback,
    );
  }
}
