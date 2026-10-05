import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 可旋转圆盘（中心名称 + 外环档位/数值）——与 [FormatDial]（径向菜单）
/// 同一口径的零业务语义通用组件：值语义归宿主回调，配置经
/// [RotaryDialSpec] 注入（缺省回落默认值）。
///
/// 双模式：
/// - **有级**（[RotaryMode.stepped]）：外环均分为 [RotaryMenu.items] 档，
///   拖动旋转实时换档（触觉 tick），松手指示点吸附段中心
///  （feel.snapOnRelease）；
/// - **无级**（[RotaryMode.continuous]）：弧内角度线性映射
///  `[min, max]` 连续值回调，可配刻度线（menu.tickCount）。
///
/// 几何：默认 270° 弧、缺口朝正下（startAngle=135°，y-down atan2 系，
/// 顺时针推进）；角度→进度映射为纯函数 [rotaryProgressFromAngle]，缺口
/// 区回就近端，独立可单测。

// ---------- 几何默认值（RotaryGeometry 未指定项回落） ----------

/// 外半径（圆盘整体半径）。
const double kRotaryRadius = 96;

/// 环带厚度（弧线 stroke 宽度）。
const double kRotaryRingWidth = 26;

/// 中心圆半径（名称/当前值盘面）。
const double kRotaryHubRadius = 58;

/// 总弧角（默认 270°，缺口 90°）。
const double kRotarySweepAngle = 3 * math.pi / 2;

/// 起始角（y-down atan2 系；135° = 左下，缺口居中朝正下）。
const double kRotaryStartAngle = 3 * math.pi / 4;

/// 环带外命中余量（触控.land 区）。
const double kRotaryHitSlop = 12;

/// 有级段间分隔角（度）。
const double kRotarySegGapDeg = 1.5;

/// 松手吸附动画时长。
const Duration kRotarySnapDuration = Duration(milliseconds: 180);

/// 旋转模式：有级（档位吸附）/ 无级（连续值）。
enum RotaryMode { stepped, continuous }

/// 有级档位项：环上标签 + 自定义色（null 用主题）。
class RotaryItem {
  const RotaryItem(this.label, {this.color});

  final String label;
  final Color? color;
}

/// 环尺寸/弧角配置（未指定项用构造默认值回落）。
class RotaryGeometry {
  const RotaryGeometry({
    this.radius = kRotaryRadius,
    this.ringWidth = kRotaryRingWidth,
    this.hubRadius = kRotaryHubRadius,
    this.sweepAngle = kRotarySweepAngle,
    this.startAngle = kRotaryStartAngle,
    this.hitSlop = kRotaryHitSlop,
  }) : assert(
          radius > 0 && ringWidth > 0 && hubRadius > 0,
          'radius/ringWidth/hubRadius 必须为正',
        ),
        assert(
          hubRadius < radius - ringWidth,
          'hubRadius 必须小于 radius - ringWidth（环带内缘）',
        ),
        assert(sweepAngle > 0 && sweepAngle <= 2 * math.pi, '弧角 ∈ (0, 2π]');

  /// 外半径。
  final double radius;

  /// 环带厚度。
  final double ringWidth;

  /// 中心圆半径。
  final double hubRadius;

  /// 总弧角（弧度；<2π 时缺口区拖动回就近端）。
  final double sweepAngle;

  /// 起始角（弧度，y-down 系，顺时针向 endAngle 推进）。
  final double startAngle;

  /// 环带外命中余量。
  final double hitSlop;
}

/// 环内容配置：有级档位项 / 无级刻度线 / 中心值显示。
class RotaryMenu {
  const RotaryMenu({
    this.items = const [],
    this.tickCount = 0,
    this.showCenterValue = true,
    this.formatValue,
  });

  /// 有级档位项（continuous 模式忽略）。
  final List<RotaryItem> items;

  /// 无级模式刻度线数（含两端；0=不画，stepped 模式忽略）。
  final int tickCount;

  /// 中心名称下方是否显示当前值/档位标签。
  final bool showCenterValue;

  /// 无级值格式化（null = toStringAsFixed(2)）；stepped 显示档位标签。
  final String Function(double value)? formatValue;
}

/// 手感配置：触觉、松手吸附。
class RotaryFeel {
  const RotaryFeel({
    this.haptics = true,
    this.snapOnRelease = true,
    this.snapDuration = kRotarySnapDuration,
    this.snapCurve = Curves.easeOutCubic,
  });

  /// 换档触觉 tick（仅 stepped；划入新档 selectionClick）。
  final bool haptics;

  /// 松手吸附段中心（仅 stepped；false = 指示点停在松手处）。
  final bool snapOnRelease;
  final Duration snapDuration;
  final Curve snapCurve;
}

/// 转盘配置聚合（三节；全部有默认值，按需覆盖）。
class RotaryDialSpec {
  const RotaryDialSpec({
    this.geometry = const RotaryGeometry(),
    this.menu = const RotaryMenu(),
    this.feel = const RotaryFeel(),
  });

  final RotaryGeometry geometry;
  final RotaryMenu menu;
  final RotaryFeel feel;
}

// ---------- 几何映射（纯函数） ----------

/// 角度 → 归一化进度（0..1）：弧内线性；缺口区回就近端（end 侧半缺口=1，
/// start 侧半缺口=0）。[angle]/[startAngle]/[sweepAngle] 均为弧度。
double rotaryProgressFromAngle(
  double angle, {
  required double startAngle,
  required double sweepAngle,
}) {
  assert(sweepAngle > 0);
  const twoPi = 2 * math.pi;
  var d = (angle - startAngle) % twoPi;
  if (d < 0) d += twoPi; // 顺时针距 start 的角距 ∈ [0, 2π)
  if (d <= sweepAngle) return (d / sweepAngle).clamp(0.0, 1.0);
  final gap = twoPi - sweepAngle;
  final overshoot = d - sweepAngle; // 深入缺口的角距
  return overshoot < gap / 2 ? 1.0 : 0.0;
}

// ---------- 组件 ----------

/// 可旋转圆盘。有级：拖动换档 + 松手吸附；无级：连续值。中心显示名称
///（[title]）与当前值（menu.showCenterValue）。
class RotaryDial extends StatefulWidget {
  const RotaryDial({
    super.key,
    required this.title,
    this.mode = RotaryMode.stepped,
    this.items = const [],
    this.index = 0,
    this.value = 0.0,
    this.min = 0.0,
    this.max = 1.0,
    this.onIndexChanged,
    this.onValueChanged,
    this.spec = const RotaryDialSpec(),
  });

  /// 中心名称（hub 盘面主文字）。
  final String title;

  /// 旋转模式（默认有级）。
  final RotaryMode mode;

  /// 有级档位项（continuous 忽略）。
  final List<RotaryItem> items;

  /// 初始档位 index（stepped；外部变更在非拖动期回写）。
  final int index;

  /// 初始值（continuous，取值 [min, max]；外部变更在非拖动期回写）。
  final double value;

  /// 无级值域下/上界。
  final double min;
  final double max;

  /// 有级换档回调（拖动期实时触发）。
  final void Function(int index)? onIndexChanged;

  /// 无级值回调（拖动期实时触发，值域 [min, max]）。
  final void Function(double value)? onValueChanged;

  /// 配置（geometry/menu/feel 三节；缺省 = 270° 盘 + 默认手感）。
  final RotaryDialSpec spec;

  @override
  State<RotaryDial> createState() => _RotaryDialState();
}

class _RotaryDialState extends State<RotaryDial>
    with SingleTickerProviderStateMixin {
  double _progress = 0;
  int _index = 0;
  bool _dragging = false;
  late final AnimationController _snap;
  Animation<double>? _snapAnim;

  RotaryGeometry get _geo => widget.spec.geometry;
  RotaryMenu get _menu => widget.spec.menu;
  RotaryFeel get _feel => widget.spec.feel;
  int get _n => widget.items.length;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this, duration: _feel.snapDuration);
    _syncFromWidget();
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  /// 初始值播种（构造参数 → 内部进度/档位）。
  void _syncFromWidget() {
    if (widget.mode == RotaryMode.stepped) {
      final n = _n;
      _index = n > 0 ? widget.index.clamp(0, n - 1) : 0;
      _progress = n > 0 ? (_index + 0.5) / n : 0;
    } else {
      final range = widget.max - widget.min;
      _progress = range > 0
          ? ((widget.value - widget.min) / range).clamp(0.0, 1.0)
          : 0;
    }
  }

  @override
  void didUpdateWidget(covariant RotaryDial old) {
    super.didUpdateWidget(old);
    // 外部回写（非拖动/吸附期才生效，避免与手势打架）
    if (!_dragging && _snapAnim == null) {
      if (widget.mode == RotaryMode.stepped &&
          widget.index != old.index &&
          widget.index != _index) {
        _syncFromWidget();
      } else if (widget.mode == RotaryMode.continuous &&
          widget.value != old.value) {
        _syncFromWidget();
      }
    }
    if (widget.spec.feel.snapDuration != old.spec.feel.snapDuration) {
      _snap.duration = widget.spec.feel.snapDuration;
    }
  }

  /// 进度落地：stepped 换档（触觉 + 实时回调）、continuous 连续回调。
  void _applyProgress(double p, {required bool notify}) {
    setState(() => _progress = p.clamp(0.0, 1.0));
    if (widget.mode == RotaryMode.stepped) {
      final n = _n;
      if (n == 0) return;
      final idx = (_progress * n).floor().clamp(0, n - 1);
      if (notify && idx != _index) {
        _index = idx;
        if (_feel.haptics) HapticFeedback.selectionClick();
        widget.onIndexChanged?.call(idx);
      }
    } else if (notify) {
      final range = widget.max - widget.min;
      widget.onValueChanged?.call(widget.min + _progress * range);
    }
  }

  void _applyFromPointer(Offset localPos) {
    final size = context.size;
    if (size == null) return;
    final center = Offset(size.width / 2, size.height / 2);
    final angle = math.atan2(
      localPos.dy - center.dy,
      localPos.dx - center.dx,
    );
    _applyProgress(
      rotaryProgressFromAngle(
        angle,
        startAngle: _geo.startAngle,
        sweepAngle: _geo.sweepAngle,
      ),
      notify: true,
    );
  }

  void _onDown(PointerDownEvent e) {
    final size = context.size;
    if (size == null) return;
    final center = Offset(size.width / 2, size.height / 2);
    final r = (e.localPosition - center).distance;
    // 命中环带外扩区（hub 内不响应，防中心误触跳值）
    if (r < _geo.hubRadius || r > _geo.radius + _geo.hitSlop) return;
    _snap.stop();
    _snapAnim = null;
    _dragging = true;
    _applyFromPointer(e.localPosition);
  }

  void _onMove(PointerMoveEvent e) {
    if (!_dragging) return;
    _applyFromPointer(e.localPosition);
  }

  void _onUp(PointerUpEvent e) {
    if (!_dragging) return;
    _dragging = false;
    // 有级松手：指示点吸附段中心（无级停在手处）
    if (widget.mode == RotaryMode.stepped &&
        _feel.snapOnRelease &&
        _n > 0) {
      final target = (_index + 0.5) / _n;
      _snap.duration = _feel.snapDuration;
      _snapAnim = Tween<double>(begin: _progress, end: target).animate(
        CurvedAnimation(parent: _snap, curve: _feel.snapCurve),
      );
      _snap
        ..reset()
        ..forward()
        ..addListener(() {
          if (!mounted) return;
          setState(() {
            if (_snapAnim != null) _progress = _snapAnim!.value;
          });
          if (_snap.isCompleted) _snapAnim = null;
        });
    }
  }

  void _onCancel(PointerCancelEvent e) => _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = _geo.radius * 2;
    final stepped = widget.mode == RotaryMode.stepped;
    final n = _n;
    // 中心当前值：stepped 显档位标签；continuous 经 formatValue
    final String? centerValue;
    if (!_menu.showCenterValue) {
      centerValue = null;
    } else if (stepped) {
      centerValue = n > 0 ? widget.items[_index].label : null;
    } else {
      final v = widget.min + _progress * (widget.max - widget.min);
      centerValue = _menu.formatValue?.call(v) ?? v.toStringAsFixed(2);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Listener(
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: Stack(
          children: [
            CustomPaint(
              size: Size.square(size),
              painter: _RotaryPainter(
                progress: _progress,
                geo: _geo,
                stepped: stepped,
                itemCount: n,
                activeIndex: _index,
                itemColors: [for (final item in widget.items) item.color],
                tickCount: stepped ? 0 : _menu.tickCount,
                scheme: scheme,
              ),
            ),
            // 环上档位标签（有级）：段中角、环带中径，真实 Text 可测可读
            if (stepped)
              for (var i = 0; i < n; i++)
                _itemLabel(
                  widget.items[i].label,
                  angle: _geo.startAngle + (i + 0.5) * _geo.sweepAngle / n,
                  radius: _geo.radius - _geo.ringWidth / 2,
                  highlighted: i == _index,
                ),
            // 中心：名称 + 当前值
            Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (centerValue != null)
                      Text(
                        centerValue,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 环上标签定位：给定角、半径，真实 Text。
  Widget _itemLabel(
    String label, {
    required double angle,
    required double radius,
    required bool highlighted,
  }) {
    final size = _geo.radius * 2;
    final pos = Offset(
      size / 2 + math.cos(angle) * radius,
      size / 2 + math.sin(angle) * radius,
    );
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
            color: highlighted
                ? scheme.onSurface
                : scheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

/// 圆盘绘制：轨道弧 + （有级）分段弧/（无级）进度弧 + 刻度线 + 指示点 +
/// 中心圆。角度映射与 [rotaryProgressFromAngle] 同一坐标系。
class _RotaryPainter extends CustomPainter {
  _RotaryPainter({
    required this.progress,
    required this.geo,
    required this.stepped,
    required this.itemCount,
    required this.activeIndex,
    required this.itemColors,
    required this.tickCount,
    required this.scheme,
  });

  final double progress;
  final RotaryGeometry geo;
  final bool stepped;
  final int itemCount;
  final int activeIndex;
  final List<Color?> itemColors;
  final int tickCount;
  final ColorScheme scheme;

  static const _segGap = kRotarySegGapDeg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final bandR = geo.radius - geo.ringWidth / 2;
    final bandRect = Rect.fromCircle(center: center, radius: bandR);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = geo.ringWidth;
    // 轨道弧（有级时被分段覆盖，仅无级画）
    if (!stepped) {
      canvas.drawArc(
        bandRect,
        geo.startAngle,
        geo.sweepAngle,
        false,
        stroke..color = scheme.surfaceContainerHighest,
      );
      // 进度弧：start → 当前角
      if (progress > 0) {
        canvas.drawArc(
          bandRect,
          geo.startAngle,
          geo.sweepAngle * progress,
          false,
          stroke..color = scheme.primary,
        );
      }
    } else if (itemCount > 0) {
      // 分段弧：段间留分隔角，激活段主色
      final segSweep = geo.sweepAngle / itemCount;
      for (var i = 0; i < itemCount; i++) {
        final active = i == activeIndex;
        final color = active
            ? scheme.primary
            : (itemColors[i] ?? scheme.surfaceContainerHighest);
        canvas.drawArc(
          bandRect,
          geo.startAngle + i * segSweep + _segGap / 2,
          math.max(segSweep - _segGap, 0.001),
          false,
          stroke..color = color,
        );
      }
    }
    // 刻度线（无级可选）：环带内侧短径向线
    if (tickCount > 1) {
      final tickPaint = Paint()
        ..color = scheme.outlineVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final inner = geo.radius - geo.ringWidth - 2;
      for (var i = 0; i < tickCount; i++) {
        final angle = geo.startAngle + geo.sweepAngle * i / (tickCount - 1);
        final dir = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(
          center + dir * (inner - 6),
          center + dir * inner,
          tickPaint,
        );
      }
    }
    // 指示点：当前进度角、环带中径（旋转的「把手」）
    final indicatorAngle = geo.startAngle + geo.sweepAngle * progress;
    final indicatorPos =
        center +
        Offset(math.cos(indicatorAngle), math.sin(indicatorAngle)) * bandR;
    canvas.drawCircle(
      indicatorPos,
      geo.ringWidth * 0.28,
      Paint()..color = scheme.onPrimary,
    );
    canvas.drawCircle(
      indicatorPos,
      geo.ringWidth * 0.28,
      Paint()
        ..color = scheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // 中心圆（名称盘面）
    canvas.drawCircle(
      center,
      geo.hubRadius,
      Paint()..color = scheme.surfaceContainerHigh,
    );
    canvas.drawCircle(
      center,
      geo.hubRadius,
      Paint()
        ..color = scheme.outlineVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_RotaryPainter old) =>
      old.progress != progress ||
      old.activeIndex != activeIndex ||
      old.stepped != stepped ||
      old.itemCount != itemCount ||
      old.tickCount != tickCount ||
      old.scheme != scheme ||
      old.geo != geo ||
      old.itemColors != itemColors;
}
