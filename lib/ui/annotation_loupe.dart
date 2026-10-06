import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../render/annotation_painter.dart';

/// 放大镜（image-markup.md §5 / §5.1）：锚点级拖动时就近浮现被对准区域的
/// 放大视图（含十字准星）——「放大镜中世界，画布纹丝不动」。
///
/// 技术纪律（§5.1）：**复渲染而非截屏**——镜内再渲染一遍图层（实时截屏法
/// 60fps 拖拽掉帧，弃用）；镜中**只渲染原图 + 当前操作标注的本体线**（不做
/// 选中态/其他标注/吸附线——200% 视野里多余图层全是噪音），经 [focusIds] 过滤。
///
/// 取景模型（2026-10-06 修指向偏差）：整张画布（原图+当前标注，同一归一化
/// 参照系）1:1 复刻后经 [loupeTransform] 平移+放大——**笔点恒钉在镜心**，
/// 十字准星所指就是手指下方的真实画布点。旧实现 FittedBox cover 居中裁切 +
/// Transform.scale 以画布中心为锚，镜中内容与笔点无关（「镜中指 A 实际点 B」
/// 即此）；标注层当年按整框归一化重画，恰好与放大的背景错位叠加。
///
/// 边缘翻转（§5.1）：默认在手指斜上方，靠近顶/左边缘自动翻转到下方/右侧。
///
/// 图上叠加色声明（勿主题化）：镜框白边 `0xCCFFFFFF` / 投影黑 `0x66000000` /
/// 准星白与 annotation_painter 同一对比度系统——底是任意用户图片而非
/// App 表面，白+黑投影对任意底图成立；主题暖白/灰为暗室底设计，放到
/// 白底截图会隐身。口径 SSOT 见 render/annotation_painter.dart 顶部声明。
class AnnotationLoupe extends StatelessWidget {
  const AnnotationLoupe({
    super.key,
    required this.annotations,
    required this.focusIds,
    required this.background,
    required this.fingerLocal,
    required this.canvasSize,
    this.magnification = 2.0,
    this.radius = 56,
  });

  /// 仅渲染被拖动标注（loupe 口径的「只画当前操作标注」）。
  final List<Annotation> annotations;
  final Set<String> focusIds;

  /// 镜中底层——原图（复渲染法的「再渲染一遍」对象）。
  final Widget background;

  /// 手指在画布坐标系的当前位置（loupe 浮点跟随）。
  final Offset fingerLocal;
  final Size canvasSize;
  final double magnification;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final diameter = radius * 2;
    final margin = 12.0;

    // 边缘翻转：默认手指斜上方；贴顶翻下方、贴左翻右侧（§5.1 悬浮层边界）。
    final above = fingerLocal.dy > diameter + margin;
    final right = fingerLocal.dx > diameter + margin;
    final dx = right ? -diameter * 0.7 : diameter * 0.7;
    final dy = above ? -diameter * 0.7 : diameter * 0.7;
    final center = fingerLocal + Offset(dx, dy);

    return Positioned(
      left: (center.dx - radius).clamp(0.0, canvasSize.width - diameter),
      top: (center.dy - radius).clamp(0.0, canvasSize.height - diameter),
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xCCFFFFFF), width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 8),
          ],
        ),
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 取景层（2026-10-06 修指向偏差）：整画布（原图+当前标注，同一
              // 归一化参照系）1:1 复刻后经 [loupeTransform] 平移+放大——笔点
              // 恒钉镜心，十字准星所指=手指下方的真实画布点；标注层与原图走
              // 同一矩阵，永不错位。OverflowBox 给画布尺寸约束（Stack 单元是
              // 直径紧约束，直接放会被压扁），超界内容由 ClipOval 裁掉。
              ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxWidth: canvasSize.width,
                  maxHeight: canvasSize.height,
                  child: Transform(
                    transform:
                        loupeTransform(fingerLocal, radius, magnification),
                    child: SizedBox(
                      width: canvasSize.width,
                      height: canvasSize.height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          background,
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _LoupeOverlay(
                                annotations: annotations,
                                focusIds: focusIds,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 十字准星
              const IgnorePointer(
                child: Center(
                  child: _Crosshair(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 放大镜取景矩阵（纯函数，单测锁定）：画布点 p → 镜内坐标 = 镜心 + m·(p − 笔点)。
/// 笔点恒映到镜心 `(radius, radius)`——十字准星所指即手指下方的真实画布点；
/// 放大锚点=笔点，拖动时镜中内容随手指平滑跟随。
Matrix4 loupeTransform(Offset finger, double radius, double magnification) =>
    Matrix4.translationValues(
          radius - magnification * finger.dx,
          radius - magnification * finger.dy,
          0,
        ) *
        Matrix4.diagonal3Values(magnification, magnification, 1);

class _LoupeOverlay extends CustomPainter {
  _LoupeOverlay({required this.annotations, required this.focusIds});

  final List<Annotation> annotations;
  final Set<String> focusIds;

  @override
  void paint(Canvas canvas, Size size) {
    // 标注层在 [loupeTransform] 内与原图同一矩阵（画布尺寸复刻，归一化坐标
    // 画满整框即与画布对位）；无选中态、无其他标注、无吸附线。
    paintAnnotations(canvas, size, annotations, onlyIds: focusIds);
  }

  @override
  bool shouldRepaint(_LoupeOverlay old) =>
      old.annotations != annotations || old.focusIds != focusIds;
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: CustomPaint(painter: _CrosshairPainter()),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 1;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(c - const Offset(10, 0), c - const Offset(3, 0), paint);
    canvas.drawLine(c + const Offset(3, 0), c + const Offset(10, 0), paint);
    canvas.drawLine(c - const Offset(0, 10), c - const Offset(0, 3), paint);
    canvas.drawLine(c + const Offset(0, 3), c + const Offset(0, 10), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
