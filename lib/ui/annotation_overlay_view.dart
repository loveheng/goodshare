import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../render/annotation_painter.dart';

/// 标注常态显示层（2026-10-06 拍板：标注不再「点进编辑页才可见」）：
/// 只读叠加组件——加载 [AnnotationStore] 标注列表并按归一化坐标画在
/// 与底图同尺寸的区域内。编辑画布/导出合成共用同一 paintAnnotations
/// 纯函数（image-markup.md §5.1 三消费方复用纪律），所见即所得。
///
/// 无标注（文件不存在）时零渲染（SizedBox.shrink），列表滚动零开销。
/// 异步加载失败兜底空列表（与 AnnotationStore.load 同口径，非阻断）。
class AnnotationOverlayView extends StatelessWidget {
  const AnnotationOverlayView({super.key, required this.itemId, this.blockKey});

  final String itemId;

  /// 行内块 key（null = 顶级 'item'，AnnotationStore 同口径）。
  final String? blockKey;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Annotation>>(
      future: AnnotationStore.load(itemId, blockKey ?? AnnotationStore.topLevelKey),
      builder: (context, snap) {
        final list = snap.data;
        if (list == null || list.isEmpty) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) => CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _ReadonlyAnnotationPainter(list),
          ),
        );
      },
    );
  }
}

/// 只读 painter：直接复用 paintAnnotations（无选中/锚点 chrome）。
class _ReadonlyAnnotationPainter extends CustomPainter {
  _ReadonlyAnnotationPainter(this.annotations);

  final List<Annotation> annotations;

  @override
  void paint(Canvas canvas, Size size) =>
      paintAnnotations(canvas, size, annotations);

  @override
  bool shouldRepaint(_ReadonlyAnnotationPainter old) =>
      old.annotations != annotations;
}
