/// 标注渲染纯函数（image-markup.md §5.1 三消费方复用纪律）。
///
/// **同一个纯函数**服务三个消费方，保证所见即所得：
/// 1. 画布叠加层（编辑态 CustomPainter）
/// 2. loupe 镜中复渲染（放大镜内只画原图 + 当前操作标注本体线，见 §5.1）
/// 3. 导出合成（PictureRecorder 离屏 Canvas → PNG，§7 文字瞬时合成）
///
/// 入参只有 canvas + 标注列表 + 画布尺寸（归一化坐标 → 像素的唯一换算口），
/// 不持状态、不触 IO。对比度纪律（§5.1）：线要素垫极淡黑投影；文字自带
/// 半透明底框。序号由 [assignPinNumbers]（annotation_geometry.dart）动态计算。
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart' as pt;

import '../models/annotation.dart';
import '../models/annotation_geometry.dart';

/// 把全部标注画上 [canvas]（像素坐标 = 归一化 × size）。
///
/// [onlyIds]：非空时只画这些 ID（loupe 镜中「只渲染当前操作标注」用）；
/// [selectedId]：画选中框 + 锚点小圆点（导出合成时不传——导出无选中态）；
/// [anchorIndex]：锚点级选中时放大高亮该锚点、其余变暗（§4 视觉区分）。
void paintAnnotations(
  ui.Canvas canvas,
  ui.Size size,
  List<Annotation> annotations, {
  Set<String>? onlyIds,
  String? selectedId,
  int? anchorIndex,
  Map<String, int>? pinNumbers,
}) {
  final numbers = pinNumbers ?? assignPinNumbers(annotations);
  for (final a in annotations) {
    if (onlyIds != null && !onlyIds.contains(a.id)) continue;
    final selected = a.id == selectedId;
    _paintOne(canvas, size, a,
        selected: selected, anchorIndex: selected ? anchorIndex : null);
    if (a.type == AnnotationType.number) {
      _paintPinBadge(canvas, size, a, numbers[a.id] ?? 0, selected: selected);
    }
  }
  if (selectedId != null) {
    final sel = annotations.where((a) => a.id == selectedId).firstOrNull;
    if (sel != null) _paintSelectionOverlay(canvas, size, sel, anchorIndex);
  }
}

void _paintOne(
  ui.Canvas canvas,
  ui.Size size,
  Annotation a, {
  required bool selected,
  int? anchorIndex,
}) {
  final paint = ui.Paint()
    ..color = _colorOf(a.color)
    ..style = (a.filled && a.type == AnnotationType.rect)
        ? ui.PaintingStyle.fill
        : ui.PaintingStyle.stroke
    ..strokeWidth = (a.strokeW * size.shortestSide).clamp(2.0, 12.0)
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    // 对比度增强（§5.1）：线要素垫极淡黑投影，防固定色板融进底图
    ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.solid, 1.5);

  switch (a.type) {
    case AnnotationType.arrow:
      if (a.points.length < 2) return;
      final head = _px(a.points[0], size);
      final tail = _px(a.points[1], size);
      canvas.drawLine(tail, head, paint);
      _drawArrowHead(canvas, paint, head, tail, paint.strokeWidth * 3);
    case AnnotationType.rect:
      if (a.points.length < 2) return;
      final rect = ui.Rect.fromPoints(_px(a.points[0], size), _px(a.points[1], size));
      canvas.drawRRect(
          ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(8)), paint);
    case AnnotationType.free:
      if (a.points.length < 2) return;
      final path = ui.Path()
        ..moveTo(_px(a.points[0], size).dx, _px(a.points[0], size).dy);
      for (var i = 1; i < a.points.length; i++) {
        final pt = _px(a.points[i], size);
        path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(path, paint);
    case AnnotationType.number:
      break; // 序号角标走 _paintPinBadge
    case AnnotationType.text:
      _paintText(canvas, size, a);
  }
}

/// 文字标注（§7）：永不合成进像素仅在导出时经本函数瞬时合成；
/// 半透明底框保证斑斓底图上可读（对比度纪律）。
void _paintText(ui.Canvas canvas, ui.Size size, Annotation a) {
  if (a.text == null || a.text!.isEmpty || a.points.isEmpty) return;
  final origin = _px(a.points.first, size);
  final fontSize = (a.fontSize * size.shortestSide).clamp(10.0, 64.0);
  final tp = pt.TextPainter(
    text: pt.TextSpan(
        text: a.text!,
        style: pt.TextStyle(color: _colorOf(a.color), fontSize: fontSize)),
    textDirection: ui.TextDirection.ltr,
  )..layout(maxWidth: size.width * 0.8);
  final rect = ui.Rect.fromLTWH(origin.dx, origin.dy, tp.width + 8, tp.height + 6);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(4)),
    ui.Paint()..color = const ui.Color(0x99000000),
  );
  tp.paint(canvas, ui.Offset(origin.dx + 4, origin.dy + 3));
}

void _paintPinBadge(
  ui.Canvas canvas,
  ui.Size size,
  Annotation a,
  int number, {
  required bool selected,
}) {
  if (a.points.isEmpty) return;
  final center = _px(a.points.first, size);
  final r = (0.03 * size.shortestSide).clamp(12.0, 32.0);
  canvas.drawCircle(center, r, ui.Paint()..color = _colorOf(a.color));
  final tp = pt.TextPainter(
    text: pt.TextSpan(
      text: '$number',
      style: pt.TextStyle(
          color: ui.Color(0xFFFFFFFF),
          fontSize: r * 1.2,
          fontWeight: ui.FontWeight.bold),
    ),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  tp.paint(
      canvas, center - ui.Offset(tp.width / 2, tp.height / 2) + const ui.Offset(0, 1));
}

/// 选中态叠加（§4）：选中框 + 全部锚点小圆点。只画不参与命中——
/// 命中判定在 annotation_geometry.dart（纯函数可测）。
void _paintSelectionOverlay(
    ui.Canvas canvas, ui.Size size, Annotation a, int? anchorIndex) {
  final anchors = anchorsOf(a);
  for (var i = 0; i < anchors.length; i++) {
    final c = _px(anchors[i], size);
    final isHot = anchorIndex == i;
    // 锚点级：单点放大高亮、其余变暗（§4 视觉区分必须明显）
    canvas.drawCircle(
      c,
      isHot ? 10 : 5,
      ui.Paint()
        ..color = isHot
            ? const ui.Color(0xFFFFFFFF)
            : const ui.Color(0xCCFFFFFF)
        ..style = ui.PaintingStyle.fill,
    );
    canvas.drawCircle(
      c,
      isHot ? 10 : 5,
      ui.Paint()
        ..color = const ui.Color(0xFF1C1F27)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }
}

void _drawArrowHead(ui.Canvas canvas, ui.Paint paint, ui.Offset head,
    ui.Offset tail, double len) {
  final dir = (head - tail);
  if (dir.distance == 0) return;
  final unit = dir / dir.distance;
  final perp = ui.Offset(-unit.dy, unit.dx);
  final p1 = head - unit * len + perp * len * 0.5;
  final p2 = head - unit * len - perp * len * 0.5;
  final fill = ui.Paint()
    ..color = paint.color
    ..style = ui.PaintingStyle.fill;
  canvas.drawPath(
      ui.Path()
        ..moveTo(head.dx, head.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..close(),
      fill);
}

ui.Color _colorOf(String hex) {
  final h = hex.replaceFirst('#', '');
  if (h.length != 6 && h.length != 8) return const ui.Color(0xFFFF3B30);
  return ui.Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
}

ui.Offset _px(NormPoint p, ui.Size size) =>
    ui.Offset(p.x * size.width, p.y * size.height);

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
