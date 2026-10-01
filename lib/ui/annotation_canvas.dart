import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/annotation.dart';
import '../models/annotation_geometry.dart';
import '../render/annotation_painter.dart';
import 'annotation_loupe.dart';
import 'tokens.dart' show Radii;

/// 标注画布（image-markup.md §4/§5.1，第 1 批：箭头/矩形/序号 pin）。
///
/// 职能边界（goodshare-arch「UI 只持交互态」）：
/// - 本组件**只持交互态**（选中对象 / 选中锚点 / 生成中工具），几何判定走
///   `annotation_geometry.dart` 纯函数、渲染走 `annotation_painter.dart`
///   纯函数（三消费方共用），持久化由调用方经 [onChanged]/[onAdded] 落
///   `AnnotationStore`——本组件不做任何文件 IO / json。
///
/// 手势排他锁（§5.1 落地第一优先级，不处理此竞争整套 UI 不可用）：
/// - 命中优先级：锚点热区 > 对象本体 > 画布；
/// - **选中对象后画布平移锁定**（[InteractiveViewer.panEnabled] 随选中态翻转），
///   单指拖拽仅作用于标注；点空白取消选中后解锁；
/// - 8dp 逃生口：选中判定只发生在 tap（位移 <8dp 的 down-up）——「按在对象上
///   但想平移」时未选中态下画布平移仍然可用，无需压点即选；
/// - 层级回退单向：锚点级 → 对象级 → 无，唯一出口是点空白/点对象本体。
class AnnotationCanvas extends StatefulWidget {
  const AnnotationCanvas({
    super.key,
    required this.annotations,
    required this.onChanged,
    required this.onAdded,
    this.createType,
    this.createFilled = false,
    this.onCreateSettled,
    this.selectedId,
    this.onSelectedChanged,
    this.background,
  });

  final List<Annotation> annotations;

  /// 拖拽（整体移动 / 锚点调整）结束后的整表回写（调用方持久化）。
  final ValueChanged<List<Annotation>> onChanged;

  /// 新标注生成（拖拽绘制完成）——自动入列由调用方负责。
  final ValueChanged<Annotation> onAdded;

  /// 非 null = 生成模式：画布上一次拖拽生成该类型标注（工具栏发起，§6）。
  final AnnotationType? createType;

  /// 生成态是否实心（§3 隐私遮挡=圆角矩形实心态，随 rect 生成）。
  final bool createFilled;

  /// 生成模式结束（无论成功取消）——工具栏复位用。
  final VoidCallback? onCreateSettled;

  /// 受控选中态（列表 ↔ 画布双向联动，§6）。null = 无选中。
  final String? selectedId;

  final ValueChanged<String?>? onSelectedChanged;

  /// 原图背景（loupe 镜中复渲染用；null = loupe 只镜标注层）。
  final Widget? background;

  @override
  State<AnnotationCanvas> createState() => _AnnotationCanvasState();
}

enum _GestureMode { idle, panCandidate, objectDrag, anchorDrag, creating }

class _AnnotationCanvasState extends State<AnnotationCanvas> {
  // ── 交互态（仅此三样，无业务数据） ──
  String? _selectedId;
  int? _anchorIndex; // 非 null = 锚点级选中

  _GestureMode _mode = _GestureMode.idle;
  NormPoint _lastNorm = const NormPoint(0, 0);
  NormPoint _downNorm = const NormPoint(0, 0);
  Annotation? _creating;

  /// 拖动中的吸附线显示态（§5 松手即隐）与上一帧触觉档（边沿触发去重）。
  List<SnapLine> _snapLines = const [];
  SnapHaptic? _lastHaptic;

  /// 手指画布坐标（loupe 跟随用），仅锚点级拖动期间有效。
  Offset? _fingerLocal;

  void _fireHaptic(SnapHaptic h) {
    switch (h) {
      case SnapHaptic.orthogonal:
        HapticFeedback.selectionClick();
      case SnapHaptic.align:
        HapticFeedback.lightImpact();
    }
  }

  static const _tapSlop = 8.0; // 逻辑像素（§5.1 拖拽阈值判定）

  String? get _effectiveSelected => widget.selectedId ?? _selectedId;

  void _setSelected(String? id, {int? anchor}) {
    setState(() {
      _selectedId = id;
      _anchorIndex = id == null ? null : anchor;
    });
    widget.onSelectedChanged?.call(id);
  }

  void _syncExternalSelection() {
    if (_selectedId != null &&
        widget.selectedId != null &&
        _selectedId != widget.selectedId) {
      _selectedId = widget.selectedId; // 列表点行 → 画布同步（§6）
      _anchorIndex = null;
    }
  }

  NormPoint _norm(Offset local, Size size) => NormPoint(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  void _onPointerDown(PointerDownEvent e, Size size) {
    _lastNorm = _downNorm = _norm(e.localPosition, size);
    final creating = widget.createType;
    if (creating != null) {
      // 生成模式：down 定第一锚点，拖拽定第二（§6 在画布拖拽生成）
      _creating = Annotation(
        type: creating,
        points: [_downNorm, _downNorm],
        filled: widget.createFilled,
      );
      _mode = _GestureMode.creating;
      return;
    }
    final sel = _effectiveSelected;
    if (sel != null) {
      // 命中优先级 1：锚点热区（就近吸附容错，§4）
      final hit = hitAnchor(widget.annotations, _downNorm);
      if (hit != null && hit.annId == sel) {
        _mode = _GestureMode.anchorDrag;
        setState(() => _anchorIndex = hit.anchorIndex);
        return;
      }
      // 优先级 2：对象本体（含选中对象本体→对象级回退；其他对象→切换选中）
      final obj = hitObject(widget.annotations, _downNorm);
      if (obj != null) {
        _mode = _GestureMode.objectDrag;
        if (obj != sel) _setSelected(obj);
        // 同一对象本体：锚点级 → 对象级（层级回退单向）
        if (obj == sel) setState(() => _anchorIndex = null);
        return;
      }
    } else {
      final obj = hitObject(widget.annotations, _downNorm);
      if (obj != null) {
        // 未选中态下按在对象上：不立即选中也不锁画布——拖动=平移（8dp 逃生口），
        // tap（<8dp up）才选中。
        _mode = _GestureMode.panCandidate;
        return;
      }
    }
    _mode = _GestureMode.panCandidate; // 空白：tap 取消选中，拖动=画布平移
  }

  void _onPointerMove(PointerMoveEvent e, Size size) {
    final now = _norm(e.localPosition, size);
    final dx = now.x - _lastNorm.x;
    final dy = now.y - _lastNorm.y;
    _lastNorm = now;
    _fingerLocal = e.localPosition;
    switch (_mode) {
      case _GestureMode.creating:
        setState(() {
          final c = _creating!;
          if (c.type == AnnotationType.free) {
            // 笔迹（§3 候选工具）：矢量一笔采点——轨迹追加，非两点替换；
            // 与上一采样点重合（<0.002 归一化）不重复采。
            final last = c.points.last;
            if ((now.x - last.x).abs() > 0.002 ||
                (now.y - last.y).abs() > 0.002) {
              _creating = c.copyWith(points: [...c.points, now]);
            }
          } else {
            _creating = withAnchor(c, 1, now);
          }
        });
      case _GestureMode.anchorDrag:
        final sel = _effectiveSelected;
        if (sel == null || _anchorIndex == null) return;
        final idx = widget.annotations.indexWhere((a) => a.id == sel);
        if (idx < 0) return;
        // 精度栈（§5）：对齐吸附（边缘/中心/其他标注锚点）+ 正交角度吸附。
        // 参照系排除被拖标注自身（自己的锚点不与自己吸附）。
        final others = [
          for (final a in widget.annotations)
            if (a.id != sel) a,
        ];
        final snapped = snapAnchorPoint(now, others);
        final orthogonal = snapOrthogonal(_downNorm, now);
        final target = orthogonal?.point ?? snapped.point;
        // 触觉两档（§5）：正交=selectionClick，对齐线=lightImpact；
        // 仅在「状态翻转为命中」的边沿触发，不随帧连发。
        final haptic = orthogonal != null
            ? SnapHaptic.orthogonal
            : (snapped.lines.isNotEmpty ? SnapHaptic.align : null);
        if (haptic != null && haptic != _lastHaptic) {
          _fireHaptic(haptic);
        }
        _lastHaptic = haptic;
        setState(() {
          _snapLines = snapped.lines;
          widget.annotations[idx] = withAnchor(
            widget.annotations[idx],
            _anchorIndex!,
            target,
          );
        });
      case _GestureMode.objectDrag:
        final sel = _effectiveSelected;
        if (sel == null) return;
        final idx = widget.annotations.indexWhere((a) => a.id == sel);
        if (idx < 0) return;
        setState(() {
          widget.annotations[idx] = translated(widget.annotations[idx], dx, dy);
        });
      case _GestureMode.panCandidate || _GestureMode.idle:
        break; // 交给 InteractiveViewer
    }
  }

  void _onPointerUp(PointerUpEvent e, Size size) {
    final upNorm = _norm(e.localPosition, size);
    final moved =
        (upNorm.x - _downNorm.x).abs() * size.width > _tapSlop ||
        (upNorm.y - _downNorm.y).abs() * size.height > _tapSlop;
    switch (_mode) {
      case _GestureMode.creating:
        final created = _creating;
        _creating = null;
        _mode = _GestureMode.idle;
        if (created != null &&
            (moved ||
                created.type == AnnotationType.number ||
                created.type == AnnotationType.text)) {
          // 两点重合的误触不产出；序号 pin / 文字为单点放置（tap 即生成，§3/§7）
          widget.onAdded(created);
          _setSelected(created.id);
        }
        widget.onCreateSettled?.call();
      case _GestureMode.anchorDrag || _GestureMode.objectDrag:
        widget.onChanged(widget.annotations);
        _mode = _GestureMode.idle;
        setState(() {
          _snapLines = const []; // §5 松手即隐
          _lastHaptic = null;
          _fingerLocal = null; // loupe 随拖动结束消失
        });
      case _GestureMode.panCandidate:
        _mode = _GestureMode.idle;
        if (!moved) {
          // tap：命中优先级兜底——对象→选中/切换，锚点已选中态处理，空白→取消
          final hit = hitAnchor(widget.annotations, upNorm);
          final sel = _effectiveSelected;
          if (hit != null && hit.annId == sel) {
            setState(() => _anchorIndex = hit.anchorIndex); // 对象级→锚点级
          } else {
            final obj = hitObject(widget.annotations, upNorm);
            _setSelected(obj); // null = 点空白取消（层级唯一出口）
          }
        }
      case _GestureMode.idle:
        break;
    }
  }

  void _onPointerCancel() {
    if (_mode == _GestureMode.creating) {
      _creating = null;
      widget.onCreateSettled?.call();
    }
    _mode = _GestureMode.idle;
    _snapLines = const [];
    _lastHaptic = null;
  }

  @override
  Widget build(BuildContext context) {
    _syncExternalSelection();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // 手势返回兜底（ui-spec §3）：生成/拖拽中不退页——笔画起于屏幕边缘
        // 手势带时被系统掐断（ACTION_CANCEL→_onPointerCancel），随后的返回
        // 事件在此被解释为「取消生成模式」而非退出标注；拖拽中则静默吞掉。
        return PopScope(
          canPop:
              _mode == _GestureMode.idle || _mode == _GestureMode.panCandidate,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_mode == _GestureMode.creating) {
              setState(() {
                _creating = null;
                _mode = _GestureMode.idle;
              });
              widget.onCreateSettled?.call();
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: InteractiveViewer(
              // 排他锁：选中/生成中锁平移，双指缩放恒可用（§5.1）
              panEnabled:
                  _effectiveSelected == null &&
                  widget.createType == null &&
                  _mode != _GestureMode.creating,
              scaleEnabled: true,
              maxScale: 4,
              child: SizedBox.expand(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) => _onPointerDown(e, size),
                      onPointerMove: (e) => _onPointerMove(e, size),
                      onPointerUp: (e) => _onPointerUp(e, size),
                      onPointerCancel: (_) => _onPointerCancel(),
                      child: CustomPaint(
                        painter: _AnnotationOverlay(
                          annotations: widget.annotations,
                          selectedId: _effectiveSelected,
                          anchorIndex: _anchorIndex,
                          creating: _creating,
                          snapLines: _snapLines,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // loupe（§5）：挂在**锚点级选中**拖动上（对象级不浮现）。
                    // 复渲染法镜中只画原图 + 当前操作标注本体线（§5.1）。
                    if (_mode == _GestureMode.anchorDrag &&
                        _fingerLocal != null &&
                        _effectiveSelected != null)
                      AnnotationLoupe(
                        annotations: widget.annotations,
                        focusIds: {_effectiveSelected!},
                        background:
                            widget.background ?? const SizedBox.shrink(),
                        fingerLocal: _fingerLocal!,
                        canvasSize: size,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 叠加层 painter：薄封装 [paintAnnotations] 纯函数（画布消费方）。
class _AnnotationOverlay extends CustomPainter {
  _AnnotationOverlay({
    required this.annotations,
    this.selectedId,
    this.anchorIndex,
    this.creating,
    this.snapLines = const [],
  });

  final List<Annotation> annotations;
  final String? selectedId;
  final int? anchorIndex;
  final Annotation? creating;
  final List<SnapLine> snapLines;

  @override
  void paint(Canvas canvas, Size size) {
    // 吸附参考线（§5）：细线先画（垫底），命中即显示、松手即隐。
    for (final l in snapLines) {
      final paint = Paint()
        ..color = const Color(0x66FFFFFF)
        ..strokeWidth = 1;
      if (l.isVertical) {
        canvas.drawLine(
          Offset(l.x * size.width, 0),
          Offset(l.x * size.width, size.height),
          paint,
        );
      } else {
        canvas.drawLine(
          Offset(0, l.y * size.height),
          Offset(size.width, l.y * size.height),
          paint,
        );
      }
    }
    paintAnnotations(
      canvas,
      size,
      [...annotations, ?creating],
      selectedId: selectedId,
      anchorIndex: anchorIndex,
    );
  }

  @override
  bool shouldRepaint(_AnnotationOverlay old) =>
      old.annotations != annotations ||
      old.selectedId != selectedId ||
      old.anchorIndex != anchorIndex ||
      old.creating != creating ||
      old.snapLines != snapLines;
}

/// 画布边缘轻量工具栏（§6）：发起生成（箭头/矩形/序号 pin）——
/// 「新建在画布，管理在列表」；遵守 §2 瞬隐纪律由调用方控制显隐。
class AnnotationToolbar extends StatelessWidget {
  const AnnotationToolbar({
    super.key,
    required this.onCreate,
    this.activeType,
    this.onCancelCreate,
    this.onToggleFill,
    this.fillAvailable = false,
    this.currentFilled = false,
  });

  /// 点工具 = 进入生成模式（下一次画布拖拽生成该类型）。
  final ValueChanged<AnnotationType> onCreate;
  final AnnotationType? activeType;
  final VoidCallback? onCancelCreate;

  /// 选中 rect 时的「空心线框 / 实心遮挡」Toggle（§3 隐私遮挡不新增工具，
  /// 是 rect 的实心填充态）。null/不可用时不展示。
  final VoidCallback? onToggleFill;
  final bool fillAvailable;
  final bool currentFilled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      // 全系统去胶囊（2026-10-01）：24 于 ~40dp 高即胶囊，改 lg16 矩形
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tool(context, Icons.arrow_outward, '箭头', AnnotationType.arrow),
            _tool(context, Icons.crop_square, '矩形', AnnotationType.rect),
            _tool(
              context,
              Icons.looks_one_outlined,
              '序号',
              AnnotationType.number,
            ),
            _tool(context, Icons.gesture, '笔迹', AnnotationType.free),
            _tool(context, Icons.text_fields, '文字', AnnotationType.text),
            // 遮挡 = rect 实心态快捷入口（§3：一键变纯色色块盖头像/名字/金额）
            IconButton(
              onPressed: () => onCreate(AnnotationType.rect),
              icon: const Icon(Icons.square_rounded),
              tooltip: '遮挡（实心矩形）',
              isSelected: activeType == AnnotationType.rect && currentFilled,
            ),
            if (fillAvailable && onToggleFill != null)
              IconButton(
                onPressed: onToggleFill,
                icon: Icon(
                  currentFilled ? Icons.format_color_fill : Icons.format_shapes,
                ),
                tooltip: currentFilled ? '切换为空心线框' : '切换为实心遮挡',
              ),
          ],
        ),
      ),
    );
  }

  Widget _tool(
    BuildContext context,
    IconData icon,
    String tip,
    AnnotationType t,
  ) {
    final active = activeType == t && !currentFilled;
    return IconButton(
      onPressed: active ? onCancelCreate : () => onCreate(t),
      icon: Icon(icon),
      tooltip: active ? '点击取消$tip' : tip,
      isSelected: active,
    );
  }
}
