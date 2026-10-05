import 'dart:io';

import 'package:flutter/material.dart';

import 'goodshare_image.dart';

/// 全屏图片查看（2026-10-03 拍板「图片区域点击之后图片全屏查看」）：黑底
/// + InteractiveViewer 双指缩放/拖移（maxScale 5），点按任意处关闭。
/// 调用方预判文件存在性（丢失卡不进查看）；解码宽度按屏宽（统一封装
/// cacheWidth 口径，防全分辨率解码内存翻倍）。本地文件与网络图双出口
/// （详情页/行内块/能力页预览共用，禁两套实现）。
Future<void> showImageFullScreen(
  BuildContext context, {
  File? file,
  String? networkUrl,
}) {
  assert((file == null) != (networkUrl == null), 'file 与 networkUrl 二选一');
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullScreenImagePage(file: file, networkUrl: networkUrl),
    ),
  );
}

class _FullScreenImagePage extends StatelessWidget {
  const _FullScreenImagePage({this.file, this.networkUrl});

  final File? file;
  final String? networkUrl;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final screenW = MediaQuery.sizeOf(context).width;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // 点按任意处关闭（全屏 dialog 无返回箭头，必须有可见关闭方式——
        // 手势即出口，符合既有全屏浮层口径）
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(
          maxScale: 5,
          // SizedBox.expand 而非 Center：Center 松开约束后 Image 按解码原始
          // 逻辑尺寸（cacheWidth≈屏宽×DPR）摆放——屏幕只装得下中间一块，
          // 用户被迫上下左右拖动看图（2026-10-04 真机反馈「图片太大」）。
          // 紧约束 + fit contain = 开屏整图入画，双指放大后仍可拖移细看。
          child: SizedBox.expand(
            child: file != null
                ? GoodshareImage(
                    file: file!,
                    fit: BoxFit.contain,
                    cacheWidth: (dpr * screenW).round(),
                    errorBuilder: (_, _, _) => const Center(
                      child: Text(
                        '图片无法读取',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : GoodshareImage.network(
                    url: networkUrl!,
                    fit: BoxFit.contain,
                    cacheWidth: (dpr * screenW).round(),
                    errorBuilder: (_, _, _) => const Center(
                      child: Text(
                        '图片无法读取',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
