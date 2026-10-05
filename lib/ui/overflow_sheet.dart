import 'package:flutter/material.dart';

import 'tokens.dart';

/// `⋯` 功能面板的单列条目描述。
class OverflowItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool checked;

  /// 并入连接按钮组（与同组其它项连成一个整体胶囊）。
  final bool grouped;

  const OverflowItem(
    this.icon,
    this.label,
    this.onTap, {
    this.danger = false,
    this.checked = false,
    this.grouped = false,
  });
}

/// mymind 风格功能面板（动词→容器词汇表：「低频/危险集合」唯一容器）：
/// 从底部升起，圆角 + 柔阴影；条目错峰淡入 / 上移 / 微缩放。
///
/// 原详情页 `_OverflowSheet` 抽为共享组件——页面级 AppBar 次要动作
/// （刷新/清空等低频项）不再散落 IconButton，统一收进此面板。
Future<void> showOverflowSheet(
  BuildContext context, {
  required List<OverflowItem> items,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => OverflowSheet(items: items),
  );
}

class OverflowSheet extends StatefulWidget {
  const OverflowSheet({super.key, required this.items});

  final List<OverflowItem> items;

  @override
  State<OverflowSheet> createState() => _OverflowSheetState();
}

class _OverflowSheetState extends State<OverflowSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _tile(int index, OverflowItem item, {bool connected = false}) {
    final start = (index * 0.08).clamp(0.0, 0.6);
    final end = (start + 0.5).clamp(0.0, 1.0);
    final curve = Interval(start, end, curve: Curves.easeOutCubic);
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: curve));
    final fade = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _ctrl, curve: curve));
    final scale = Tween<double>(
      begin: 0.92,
      end: 1,
    ).animate(CurvedAnimation(parent: _ctrl, curve: curve));
    final scheme = Theme.of(context).colorScheme;
    final iconColor = item.danger ? scheme.error : scheme.onSurfaceVariant;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(item.icon, size: 26, color: iconColor),
        const SizedBox(height: 8),
        Text(
          item.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: item.danger ? scheme.error : scheme.onSurface,
          ),
        ),
        if (item.checked)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(Icons.check, size: 14, color: scheme.primary),
          ),
      ],
    );
    final inner = connected
        ? content
        : Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            decoration: ShapeDecoration(
              color: scheme.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.lg),
              ),
            ),
            child: content,
          );
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: slide,
        child: ScaleTransition(
          scale: scale,
          child: InkWell(
            onTap: () {
              Navigator.pop(context);
              item.onTap();
            },
            borderRadius:
                BorderRadius.circular(connected ? Radii.sm : Radii.lg),
            child: Padding(
              padding: connected
                  ? const EdgeInsets.symmetric(vertical: 16)
                  : EdgeInsets.zero,
              child: inner,
            ),
          ),
        ),
      ),
    );
  }

  /// 连接按钮组：同类开关连成同一个胶囊，项间以细分隔线区隔。
  Widget _connectedGroup(List<OverflowItem> items, int startIndex) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              VerticalDivider(
                width: 1,
                thickness: 1,
                indent: 10,
                endIndent: 10,
                color: scheme.outlineVariant,
              ),
            Expanded(
              child: _tile(startIndex + i, items[i], connected: true),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final grouped = widget.items.where((i) => i.grouped).toList();
    final standalone = widget.items.where((i) => !i.grouped).toList();
    var idx = 0;
    final body = <Widget>[];
    if (grouped.isNotEmpty) {
      body.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: _connectedGroup(grouped, idx),
      ));
      idx += grouped.length;
    }
    if (grouped.isNotEmpty && standalone.isNotEmpty) {
      body.add(const SizedBox(height: 12));
    }
    if (standalone.isNotEmpty) {
      body.add(Row(
        children: [
          for (final s in standalone)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _tile(idx++, s),
              ),
            ),
        ],
      ));
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.md),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.md,
            Insets.md,
            Insets.lg,
          ),
          decoration: ShapeDecoration(
            color: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: Insets.md),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ...body,
            ],
          ),
        ),
      ),
    );
  }
}
