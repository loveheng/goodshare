import 'package:flutter/material.dart';

/// 速记悬浮球：可拖拽、松手自动贴左右边（设计 §4.6 悬浮球形态）。
/// 仅在 app 内悬浮；跨 app 系统级悬浮窗需 overlay 插件 + 悬浮权限，为后续项。
class FloatingBall extends StatefulWidget {
  const FloatingBall({super.key, required this.onTap, this.size = 52});

  final VoidCallback onTap;
  final double size;

  @override
  State<FloatingBall> createState() => _FloatingBallState();
}

class _FloatingBallState extends State<FloatingBall> {
  double? _x; // 球左缘的屏幕坐标
  double? _y;
  bool _dragging = false;

  void _ensurePosition(Size screen) {
    if (_x != null && _y != null) return;
    _x = screen.width - widget.size - 12; // 默认贴右缘
    _y = screen.height * 0.35;
  }

  void _clamp(Size screen) {
    _x = _x!.clamp(0.0, screen.width - widget.size);
    _y = _y!.clamp(MediaQuery.paddingOf(context).top + 8, screen.height - widget.size - 96);
  }

  void _snapToEdge(Size screen) {
    final centerX = _x! + widget.size / 2;
    final target = centerX < screen.width / 2 ? 8.0 : screen.width - widget.size - 8;
    setState(() => _x = target);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    _ensurePosition(screen);
    _clamp(screen);
    return AnimatedPositioned(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      left: _x,
      top: _y,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanStart: (_) => setState(() => _dragging = true),
        onPanUpdate: (d) => setState(() {
          _x = _x! + d.delta.dx;
          _y = _y! + d.delta.dy;
          _clamp(screen);
        }),
        onPanEnd: (_) {
          _snapToEdge(screen);
          setState(() => _dragging = false);
        },
        child: Opacity(
          opacity: _dragging ? 1 : 0.85,
          child: Material(
            elevation: 4,
            shape: const CircleBorder(),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: Icon(
                Icons.edit_note_rounded,
                size: widget.size * 0.55,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
