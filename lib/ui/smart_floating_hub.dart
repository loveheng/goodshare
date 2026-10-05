import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

/// 通用磁吸悬浮球（SmartFloatingHub）——与业务完全解耦的可复用组件。
///
/// 只负责三件事：**边界内跟手拖拽 + 松手磁吸最近缘 + tap/drag 手势分流**。
/// 不携带任何业务语义（图标/角标由外部经 [child] 组合）；点按以
/// [SmartFloatingHub.onTap] 抛出（父组件据此展开转盘/菜单），位置以
/// [positionNotifier] 注入——外部持有即天然跨页记忆/持久化（SSOT 在宿主）。
///
/// 分工契约（V11 架构拍板）：
/// - 球（本组件）：拖拽、吸附、手势分流、RepaintBoundary 性能隔离；
/// - 菜单/转盘（环）：接收点按事件展开 L2/L3，命中与业务归宿主。
class SmartFloatingHub extends StatefulWidget {
  const SmartFloatingHub({
    super.key,
    required this.child,
    required this.onTap,
    required this.positionNotifier,
    required this.bounds,
    this.size = const Size(48, 48),
    this.enableSnapToEdge = true,
    this.snapDuration = const Duration(milliseconds: 160),
    this.enabled = true,
    this.onDragEnd,
  });

  /// 球面视觉（图标/文字/角标 Stack 均可，业务自组合）。
  final Widget child;

  /// 点按（位移未超 touch slop）回调——外部据此展开菜单/转盘。
  final VoidCallback onTap;

  /// 球左上角位置（相对 [bounds] 顶左；宿主持有：跨页记忆/持久化）。
  /// 组件只在拖拽/吸附时写入，不主动归一——越界值由宿主钳制。
  final ValueNotifier<Offset> positionNotifier;

  /// 拖拽边界（本地坐标；组件按 [size] 自动钳制右/下缘）。
  final Rect bounds;

  /// 球尺寸（默认 48×48 达 MD 最小触控）。
  final Size size;

  /// 松手磁吸最近缘（四缘吸附：左/右/上/下取球心距最近一边）。
  final bool enableSnapToEdge;

  /// 拖拽松手（吸附位置已写入 [positionNotifier]）回调——宿主据此持久化
  /// 停靠位（点按不触发）。
  final VoidCallback? onDragEnd;

  /// 吸附补间时长（拖动中零时长跟手，松手吸附走补间）。
  final Duration snapDuration;

  /// false 时禁用手势（纯展示态，位置仍由 notifier 驱动）。
  final bool enabled;

  @override
  State<SmartFloatingHub> createState() => _SmartFloatingHubState();
}

class _SmartFloatingHubState extends State<SmartFloatingHub> {
  /// 拖拽中实时位置（null=未拖拽，显示 notifier 位置）。
  Offset? _dragPos;

  /// 本次按压是否超 touch slop（分流：未超的松手 = tap）。
  bool _moved = false;

  /// 拖拽起点（计算 delta 用）。
  Offset _start = Offset.zero;

  void _onPanStart(DragStartDetails details) {
    _moved = false;
    _start = details.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    // 超 slop 才算拖拽：轻点微抖不误判（与 GestureDetector tap 语义对齐）
    if (!_moved &&
        (details.localPosition - _start).distance < kTouchSlop) {
      return;
    }
    _moved = true;
    final b = widget.bounds;
    final maxX = (b.width - widget.size.width).clamp(0.0, double.infinity);
    final maxY = (b.height - widget.size.height).clamp(0.0, double.infinity);
    final base = _dragPos ?? widget.positionNotifier.value;
    _dragPos = Offset(
      (base.dx + details.delta.dx).clamp(0.0, maxX),
      (base.dy + details.delta.dy).clamp(0.0, maxY),
    );
    widget.positionNotifier.value = _dragPos!; // 宿主实时可读（持久化/联动）
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_moved) return; // 未超 slop：GestureDetector onTap 已处理点按
    final pos = _dragPos;
    _dragPos = null;
    if (pos == null) return;
    if (widget.enableSnapToEdge) {
      // 四缘吸附（2026-10-04 拍板：全域拖动 AssistiveTouch 模式）：球心
      // 距四边最近者吸附该轴，另一轴保持松手位（钳制界内）——「缘上停留
      // 不遮内容流」底线保留，自由度给满
      final b = widget.bounds;
      final maxX = (b.width - widget.size.width).clamp(0.0, double.infinity);
      final maxY = (b.height - widget.size.height).clamp(0.0, double.infinity);
      final cx = pos.dx + widget.size.width / 2;
      final cy = pos.dy + widget.size.height / 2;
      final dLeft = cx, dRight = b.width - cx;
      final dTop = cy, dBottom = b.height - cy;
      final nearestH = math.min(dLeft, dRight);
      final nearestV = math.min(dTop, dBottom);
      var x = pos.dx.clamp(0.0, maxX);
      var y = pos.dy.clamp(0.0, maxY);
      if (nearestH <= nearestV) {
        x = dLeft <= dRight ? 0.0 : maxX;
      } else {
        y = dTop <= dBottom ? 0.0 : maxY;
      }
      widget.positionNotifier.value = Offset(x, y);
    } else {
      widget.positionNotifier.value = pos;
    }
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Offset>(
      valueListenable: widget.positionNotifier,
      builder: (context, pos, _) {
        final p = _dragPos ?? pos;
        return AnimatedPositioned(
          // 拖拽中零时长跟手；松手吸附走 160ms 补间
          duration: _dragPos == null ? widget.snapDuration : Duration.zero,
          curve: Curves.easeOutCubic,
          left: p.dx,
          top: p.dy,
          child: GestureDetector(
            onTap: widget.enabled ? widget.onTap : null,
            onPanStart: widget.enabled ? _onPanStart : null,
            onPanUpdate: widget.enabled ? _onPanUpdate : null,
            onPanEnd: widget.enabled ? _onPanEnd : null,
            child: RepaintBoundary(
              // 拖拽重绘限制在球体边界内，外层编辑器无感（性能隔离）
              child: SizedBox(
                width: widget.size.width,
                height: widget.size.height,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
