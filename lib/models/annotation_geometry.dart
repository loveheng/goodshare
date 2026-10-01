/// 标注对象化几何与序号纯函数（image-markup.md §3/§4，2026-10-01 拍板落地）。
///
/// 全部纯函数、坐标归一化（[0,1] 相对原图），与屏幕尺寸/画布变换解耦——
/// 画布组件（UI 层）与渲染层共用本模块，禁止在 UI State 里内联这些判定。
///
/// 序号与身份解耦（防雪崩纪律）：schema 只存对象 ID，序号是**渲染时按列表
/// 顺序动态计算的视图属性**——删除中间 pin 后后续自动回补重排，图文永不错位。
library;

import 'dart:math' as math;

import 'annotation.dart';

/// 序号视图属性：按列表顺序给 number（pin）标注分配 1,2,3…（与 ID 解耦）。
/// 入参顺序即列表顺序（z 序 / 添加序，调用方决定）；非 pin 类型不参与编号。
Map<String, int> assignPinNumbers(List<Annotation> annotations) {
  final out = <String, int>{};
  var n = 0;
  for (final a in annotations) {
    if (a.type == AnnotationType.number) out[a.id] = ++n;
  }
  return out;
}

/// 锚点最小集（image-markup.md §3）：返回该标注的可拖锚点（归一化坐标）。
/// - 箭头：[头点, 尾点]（两点定线，朝向/长度全由两点导出）
/// - 圆角矩形：[对角点A, 对角点B]（拖一角=对角锁定）
/// - 序号 pin / 文字：[定位锚]（单点）
/// - 笔迹 free：全部轨迹点（候选工具，第 1 批不可拖）
List<NormPoint> anchorsOf(Annotation a) {
  switch (a.type) {
    case AnnotationType.arrow:
    case AnnotationType.rect:
      return a.points.length >= 2 ? a.points.sublist(0, 2) : a.points;
    case AnnotationType.number:
    case AnnotationType.text:
      return a.points.isNotEmpty ? [a.points.first] : const [];
    case AnnotationType.free:
      return a.points;
  }
}

/// 就近吸附容错（§4）：命中半径内（归一化距离，相对原图对角线）返回最近锚点，
/// 超阈值返回 null。返回 (标注ID, 锚点索引)。
({String annId, int anchorIndex})? hitAnchor(
  List<Annotation> annotations,
  NormPoint at, {
  double tolerance = 0.03,
}) {
  String? bestId;
  var bestIdx = -1;
  var bestDist = tolerance;
  // 倒序遍历 = Z 轴最上层优先（§5.1 多对象重叠命中）
  for (final a in annotations.reversed) {
    final anchors = anchorsOf(a);
    for (var i = 0; i < anchors.length; i++) {
      final d = _dist(anchors[i], at);
      if (d <= bestDist) {
        bestDist = d;
        bestId = a.id;
        bestIdx = i;
      }
    }
  }
  return bestId == null ? null : (annId: bestId, anchorIndex: bestIdx);
}

/// 对象本体命中（§4 对象级选中）：点在对象几何范围内（含线宽容错）返回
/// 最上层命中的标注 ID，否则 null。矩形/文字用包围盒（含容错），箭头用
/// 线段距离，pin 用锚点半径，笔迹逐段线距离。
String? hitObject(
  List<Annotation> annotations,
  NormPoint at, {
  double tolerance = 0.02,
}) {
  for (final a in annotations.reversed) {
    if (_hitsBody(a, at, tolerance)) return a.id;
  }
  return null;
}

bool _hitsBody(Annotation a, NormPoint at, double tol) {
  switch (a.type) {
    case AnnotationType.rect:
    case AnnotationType.text:
      if (a.points.length < 2) return false;
      final l = _minX(a), r = _maxX(a), t = _minY(a), b = _maxY(a);
      return at.x >= l - tol && at.x <= r + tol && at.y >= t - tol && at.y <= b + tol;
    case AnnotationType.arrow:
      return a.points.length >= 2 &&
          _segDist(a.points[0], a.points[1], at) <= tol;
    case AnnotationType.number:
      return a.points.isNotEmpty && _dist(a.points.first, at) <= tol * 2;
    case AnnotationType.free:
      for (var i = 0; i + 1 < a.points.length; i++) {
        if (_segDist(a.points[i], a.points[i + 1], at) <= tol) return true;
      }
      return false;
  }
}

/// 拖动锚点后重算几何（§4 锚点级拖动）：返回更新 points 后的副本。
/// 箭头/矩形两点模型直接替换锚点位；pin/文字替换单锚点。
Annotation withAnchor(Annotation a, int anchorIndex, NormPoint newPos) {
  final pts = [...a.points];
  if (anchorIndex < 0 || anchorIndex >= pts.length) return a;
  pts[anchorIndex] = newPos;
  return a.copyWith(points: pts);
}

/// 整体移动（§4 对象级拖本体）：全部点平移 [dx,dy]（归一化增量）。
Annotation translated(Annotation a, double dx, double dy) =>
    a.copyWith(points: [for (final pt in a.points) NormPoint(pt.x + dx, pt.y + dy)]);

double _dist(NormPoint a, NormPoint b) {
  final dx = a.x - b.x, dy = a.y - b.y;
  // 归一化坐标按各自维度缩放差异大（竖图 x 跨度小），用各维平方和直接比——
  // 容差阈值同口径即可，无需严格欧氏（调用方阈值随真机调整）。
  return dx * dx + dy * dy <= 0 ? 0 : _sqrt(dx * dx + dy * dy);
}

double _sqrt(double v) {
  var x = v;
  var r = v / 2;
  for (var i = 0; i < 24; i++) {
    r = (r + x / r) / 2;
  }
  return r;
}

/// 点到线段最短距离（归一化）。
double _segDist(NormPoint a, NormPoint b, NormPoint p) {
  final abx = b.x - a.x, aby = b.y - a.y;
  final apx = p.x - a.x, apy = p.y - a.y;
  final lenSq = abx * abx + aby * aby;
  final t = lenSq == 0 ? 0.0 : ((apx * abx + apy * aby) / lenSq).clamp(0.0, 1.0);
  final cx = a.x + abx * t, cy = a.y + aby * t;
  return _dist(NormPoint(cx, cy), p);
}

double _minX(Annotation a) =>
    a.points.map((e) => e.x).reduce((x, y) => x < y ? x : y);
double _maxX(Annotation a) =>
    a.points.map((e) => e.x).reduce((x, y) => x > y ? x : y);
double _minY(Annotation a) =>
    a.points.map((e) => e.y).reduce((x, y) => x < y ? x : y);
double _maxY(Annotation a) =>
    a.points.map((e) => e.y).reduce((x, y) => x > y ? x : y);

// ── 吸附线（image-markup.md §5：拖锚点经过图片边缘/中心线/其他标注对齐线） ──

/// 吸附结果的触觉语义两档（§5 触觉 tick：视觉显示对齐、手感确认对齐）。
enum SnapHaptic {
  /// 正交角度（0/45/90°…）——`HapticFeedback.selectionClick()`
  orthogonal,

  /// 对齐边缘/中心线/其他标注——略重 `HapticFeedback.lightImpact()`
  align,
}

/// 一条吸附线：几何（归一化坐标下的竖/横直线位置）+ 触觉语义。
class SnapLine {
  const SnapLine.vertical(this.x, this.y, this.haptic) : isVertical = true;
  const SnapLine.horizontal(this.y, this.x, this.haptic) : isVertical = false;

  final bool isVertical;
  final double x;
  final double y;
  final SnapHaptic haptic;
}

/// 拖动锚点 [dragging]（其余标注 [others] 提供对齐参照）时的吸附解算。
///
/// 返回：吸附修正后的点 + 应显示的吸附线列表（可能 0~2 条，横竖各一）。
/// 无命中时原样返回、线为空。吸附阈值 [snapTolerance] 归一化（相对原图宽/高）。
/// 参照系（x/y 独立解算）：图片 0/0.5/1 三线 + 其他标注锚点的 x/y 坐标。
({NormPoint point, List<SnapLine> lines}) snapAnchorPoint(
  NormPoint dragging,
  List<Annotation> others, {
  double snapTolerance = 0.015,
}) {
  final xs = <(double, SnapHaptic)>[
    (0.0, SnapHaptic.align),
    (0.5, SnapHaptic.align),
    (1.0, SnapHaptic.align),
    for (final a in others)
      for (final pt in anchorsOf(a)) (pt.x, SnapHaptic.align),
  ];
  final ys = <(double, SnapHaptic)>[
    (0.0, SnapHaptic.align),
    (0.5, SnapHaptic.align),
    (1.0, SnapHaptic.align),
    for (final a in others)
      for (final pt in anchorsOf(a)) (pt.y, SnapHaptic.align),
  ];

  var x = dragging.x;
  var y = dragging.y;
  final lines = <SnapLine>[];

  // 正交角度语义：拖动点相对起点呈 0/45/90° 时给 orthogonal 档
  // （此处只解算对齐吸附；正交档由画布层据拖动方向判定，见 snapOrthogonal）。
  (double, SnapHaptic)? best(List<(double, SnapHaptic)> refs, double v) {
    (double, SnapHaptic)? bestRef;
    var bestD = snapTolerance;
    for (final (r, h) in refs) {
      final d = (r - v).abs();
      if (d <= bestD) {
        bestD = d;
        bestRef = (r, h);
      }
    }
    return bestRef;
  }

  final bx = best(xs, dragging.x);
  if (bx != null) {
    x = bx.$1;
    lines.add(SnapLine.vertical(bx.$1, dragging.y, bx.$2));
  }
  final by = best(ys, dragging.y);
  if (by != null) {
    y = by.$1;
    lines.add(SnapLine.horizontal(by.$1, dragging.x, by.$2));
  }
  return (point: NormPoint(x, y), lines: lines);
}

/// 正交角度吸附（§5 触觉 orthogonal 档）：锚点拖动相对 [start] 的方向角
/// 命中 0/45/90/135°（含镜像全圆八向）时，把点修正到该射线上并返回角度；
/// 未命中返回 null。tolerance 为弧度容差。
({NormPoint point, double angleRadians})? snapOrthogonal(
  NormPoint start,
  NormPoint current, {
  double tolerance = 0.12,
}) {
  final dx = current.x - start.x;
  final dy = current.y - start.y;
  if (dx == 0 && dy == 0) return null;
  final angle = math.atan2(dy, dx);
  const step = math.pi / 4; // 45°
  final snapped = (angle / step).roundToDouble() * step;
  if ((angle - snapped).abs() > tolerance) return null;
  final r = math.sqrt(dx * dx + dy * dy);
  return (
    point: NormPoint(
      (start.x + math.cos(snapped) * r).clamp(0.0, 1.0),
      (start.y + math.sin(snapped) * r).clamp(0.0, 1.0),
    ),
    angleRadians: snapped,
  );
}

