import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 鹦鹉螺品牌 glyph（2026-10-01 拍板「Geometric Nautilus」，用户供 SVG 源）。
/// 「贝」押「拾贝」题眼，螺旋分室暗合「散落碎片长出秩序」。
///
/// 颜色纪律：源 SVG 的青蓝粉彩色板已在资产层重映射进主题灰阶、白底已删
/// （assets/glyphs/nautilus.svg 仅剩 #e8e4dc 线稿 / #242833、#1c1f27 两档
/// 切面，对应 onSurface 与 surfaceContainer 两槽位值）——源图彩色不落一色
/// 进代码；装饰 glyph 不走橘红（橘红仅动作与选中）。
class NautilusGlyph extends StatelessWidget {
  const NautilusGlyph({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/glyphs/nautilus.svg',
      width: size,
      height: size,
    );
  }
}
