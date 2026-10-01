import 'package:flutter/material.dart';

/// 三环绳结插画（用户供图，2026-10-01 拍板：**序号已按用户要求剔除，
/// 方向箭头保留**——「把散落的条目打成结」的工作区隐喻，挂工作区创建页）。
///
/// 与鹦鹉螺同一处理管线（源图浅色背景边界连通泛洪抠除 + 亮度反转映射进
/// 主题暖灰阶：绳体→surfaceContainerLow 档、线稿/箭头→onSurface 暖白），
/// 序号经连通域分析剔除（55×55 环形块特征），资产 `assets/glyphs/knot_diagram.png`，
/// 源图彩色不落一色进代码。定位是**插画**非品牌 glyph（品牌符号=鹦鹉螺兼
/// app 图标，ui-spec §2.4）。
class KnotIllustration extends StatelessWidget {
  const KnotIllustration({super.key, this.height = 96});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/glyphs/knot_diagram.png',
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}
