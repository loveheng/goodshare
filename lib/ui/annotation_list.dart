import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../models/annotation_geometry.dart';

/// 标注列表（image-markup.md §6 主入口）：承载「找与管」，画布只承担「调」。
///
/// 防膨胀纪律：五件事——**选中 / 删除 / 改色 / 进入调整 / 显隐**——不做搜索/
/// 折叠/分组/重排（不长成图层面板）；显隐是唯一的**视图态豁免**（不落盘、
/// 隐藏=不绘制不命中、选中自动复显、导出所见即所得）。
/// 对象数预期个位数。
///
/// 双向联动（§6）：点行 → 画布选中同步高亮（受控 [selectedId]，由宿主透传
/// 画布）；图上选中 → 宿主让本列表对应行高亮滚动到位（本组件内 scrollIntoView）。
/// 序号 = 列表顺序动态计算（[assignPinNumbers]），pin 行首显示序号角标；
/// 显隐不参与重排（序号是列表顺序的数据属性）。
class AnnotationList extends StatefulWidget {
  const AnnotationList({
    super.key,
    required this.annotations,
    required this.selectedId,
    required this.onSelected,
    required this.onDelete,
    required this.onCycleColor,
    this.onEnterAdjust,
    this.hiddenIds = const {},
    this.onToggleHidden,
    this.palette = const [
      '#FF3B30',
      '#34C759',
      '#007AFF',
      '#FFCC00',
      '#000000',
    ],
  });

  final List<Annotation> annotations;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final ValueChanged<String> onDelete;

  /// 改色 = 固定色板循环（§3 颜色固定色板，无取色器）。
  final ValueChanged<String> onCycleColor;

  /// 「调整」→ 锚点级编辑（画布拖锚点，§5 反馈栈兜底）。
  /// 传 anchorIndex = 0 让画布直接落锚点级；null = 不展示调整入口。
  final ValueChanged<String>? onEnterAdjust;

  /// 视图态隐藏集（宿主持有，不落盘）；行内 eye 键切换。
  final Set<String> hiddenIds;
  final ValueChanged<String>? onToggleHidden;

  final List<String> palette;

  @override
  State<AnnotationList> createState() => _AnnotationListState();
}

class _AnnotationListState extends State<AnnotationList> {
  final _scrollCtl = ScrollController();
  final _rowKeys = <String, GlobalKey>{};

  @override
  void dispose() {
    _scrollCtl.dispose();
    super.dispose();
  }

  GlobalKey _keyOf(String id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  /// 图上点中对象 → 对应行高亮滚动到位（§6 双向联动的列表侧）。
  void _ensureVisible(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keyOf(id).currentContext;
      if (ctx != null && mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
        );
      }
    });
  }

  String _typeLabel(Annotation a) => switch (a.type) {
    AnnotationType.arrow => '箭头',
    AnnotationType.rect => a.filled ? '遮挡' : '矩形',
    AnnotationType.free => '笔迹',
    AnnotationType.text => '文字',
    AnnotationType.number => '序号',
  };

  @override
  Widget build(BuildContext context) {
    // 外部选中变化 → 滚动到位（图上点选联动）
    if (widget.selectedId != null) {
      _ensureVisible(widget.selectedId!);
    }
    final numbers = assignPinNumbers(widget.annotations);
    final scheme = Theme.of(context).colorScheme;

    if (widget.annotations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '还没有标注——用「标注工具」在图上添加',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtl,
      shrinkWrap: true,
      itemCount: widget.annotations.length,
      itemBuilder: (context, i) {
        final a = widget.annotations[i];
        final selected = a.id == widget.selectedId;
        final pinNo = numbers[a.id];
        final hidden = widget.hiddenIds.contains(a.id);
        // 隐藏行整行降透明（视图态的视觉表达），数据不动
        return Opacity(
          opacity: hidden ? 0.45 : 1.0,
          child: ListTile(
            key: _keyOf(a.id),
            selected: selected,
            selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
            dense: true,
            visualDensity: VisualDensity.compact,
            // 选中隐藏行 = 自动复显（宿主侧实现）——防「藏了找不回」死锁
            onTap: () => widget.onSelected(selected ? null : a.id),
            leading: pinNo != null
                ? CircleAvatar(
                    radius: 11,
                    backgroundColor: _colorOf(a.color),
                    child: Text(
                      '$pinNo',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: Colors.white),
                    ),
                  )
                : Icon(
                    switch (a.type) {
                      AnnotationType.arrow => Icons.arrow_outward,
                      AnnotationType.rect =>
                        a.filled ? Icons.square_rounded : Icons.crop_square,
                      AnnotationType.free => Icons.gesture,
                      AnnotationType.text => Icons.text_fields,
                      AnnotationType.number => Icons.looks_one_outlined,
                    },
                    size: 18,
                    color: _colorOf(a.color),
                  ),
            title: Text(
              _typeLabel(a),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            subtitle: a.text != null && a.text!.isNotEmpty
                ? Text(
                    a.text!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 显隐（视图态豁免，§6）：只改渲染不改数据
                if (widget.onToggleHidden != null)
                  IconButton(
                    onPressed: () => widget.onToggleHidden!(a.id),
                    icon: Icon(
                      hidden
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                    ),
                    tooltip: hidden ? '在图上显示' : '在图上隐藏',
                    visualDensity: VisualDensity.compact,
                  ),
                // 改色：固定色板循环（§3）
                IconButton(
                  onPressed: () => widget.onCycleColor(a.id),
                  icon: Icon(Icons.palette_outlined, size: 18),
                  tooltip: '换色',
                  visualDensity: VisualDensity.compact,
                ),
                // 进入调整：锚点级编辑入口（列表是绕开画布歧义的确定性通道）
                if (widget.onEnterAdjust != null)
                  IconButton(
                    onPressed: () => widget.onEnterAdjust!(a.id),
                    icon: const Icon(Icons.open_with, size: 18),
                    tooltip: '调整位置',
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  onPressed: () => widget.onDelete(a.id),
                  icon: Icon(Icons.close, size: 18),
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _colorOf(String hex) {
    final v = hex.replaceFirst('#', '');
    return Color(int.parse(v.length == 6 ? 'FF$v' : v, radix: 16));
  }
}
