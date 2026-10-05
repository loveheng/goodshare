// DEPRECATED（2026-10-03 编辑器统一）：详情页编辑态格式入口已切换为统一作曲
// 编辑器内的可拖动格式转盘（lib/ui/format_dial.dart），本线性格式条不再被 UI 消费。
// 清偿待办见 context/todos.md。
import 'dart:async';

import 'package:flutter/material.dart';

import '../doc/rich_text.dart' show InlineMark;
import 'tokens.dart';

/// 键盘上方格式工具条（block-format-input.md §2 拍板形态）：
/// 文本块聚焦时出现在键盘上沿；只放一个「格式」按钮（预留扩展位），按钮
/// **显示当前激活档**（正文/一级标题/二级标题）；点它上方浮出一排预设格式
/// 按钮，选完立即收起，未选 ~4s 超时自动收起（拍板交互）。
///
/// 行内三钮（加粗/斜体/下划线）接通样式化编辑层（slice-3）：先选后打——
/// 激活的 mark 作用于之后输入的文字（再点一次关闭）。块级三钮经
/// [onPickLevel] 走 SetHeadingOp 事务。
class FormatToolbar extends StatefulWidget {
  const FormatToolbar({
    super.key,
    required this.currentLevel,
    required this.onPickLevel,
    this.activeMarks = const {},
    this.onToggleMark,
  });

  /// 聚焦块的当前档：0 正文 / 1 一级 / 2 二级。
  final int currentLevel;
  final void Function(int level) onPickLevel;

  /// 行内格式激活集（先选后打）；null 回调时三钮回落置灰（无聚焦块）。
  final Set<InlineMark> activeMarks;
  final void Function(InlineMark mark)? onToggleMark;

  @override
  State<FormatToolbar> createState() => _FormatToolbarState();
}

class _FormatToolbarState extends State<FormatToolbar> {
  bool _expanded = false;
  Timer? _collapseTimer;

  static const _levels = [
    (1, '一级标题'),
    (2, '二级标题'),
    (0, '正文'),
  ];

  /// 行内三钮（加粗/斜体/下划线）。
  static const _marks = [
    (InlineMark.bold, '加粗'),
    (InlineMark.italic, '斜体'),
    (InlineMark.underline, '下划线'),
  ];

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    if (_expanded) _armCollapse(); // 未选超时自动收起（拍板 ~4s）
  }

  void _pick(int level) {
    _collapseTimer?.cancel();
    setState(() => _expanded = false);
    widget.onPickLevel(level);
  }

  /// 行内格式为**开关型**（可连续启停多种）：切换后格式排保持展开并重置
  /// 超时，与档位型「选完即收」区分。
  void _toggleMark(InlineMark mark) {
    _collapseTimer?.cancel();
    setState(_armCollapse);
    widget.onToggleMark?.call(mark);
  }

  void _armCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _expanded = false);
    });
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  String get _currentLabel => switch (widget.currentLevel) {
        1 => '一级标题',
        2 => '二级标题',
        _ => '正文',
      };

  String get _marksLabel {
    const names = {
      InlineMark.bold: '加粗',
      InlineMark.italic: '斜体',
      InlineMark.underline: '下划线',
    };
    final on = [
      for (final (m, _) in _marks)
        if (widget.activeMarks.contains(m)) names[m]!,
    ];
    return on.isEmpty ? '' : ' · ${on.join('/')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: Insets.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 预设格式排：在「格式」按钮上方浮现（拍板交互）
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (level, label) in _levels)
                          Padding(
                            padding: const EdgeInsets.only(right: Insets.sm),
                            child: _chip(
                              context,
                              label,
                              highlighted: widget.currentLevel == level,
                              onTap: () => _pick(level),
                            ),
                          ),
                        for (final (mark, label) in _marks)
                          Padding(
                            padding: const EdgeInsets.only(right: Insets.sm),
                            child: _chip(
                              context,
                              label,
                              enabled: widget.onToggleMark != null,
                              highlighted: widget.activeMarks.contains(mark),
                              onTap: () => _toggleMark(mark),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // 主按钮：显示当前激活档（拍板：激活态可见）
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: _toggleExpanded,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: ShapeDecoration(
                      color: widget.currentLevel > 0
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.lg),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.text_fields,
                            size: 18,
                            color: widget.currentLevel > 0
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(
                          widget.currentLevel > 0 || widget.activeMarks.isNotEmpty
                              ? '格式 · $_currentLabel${_marksLabel == '' ? '' : _marksLabel}'
                              : '格式',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: widget.currentLevel > 0
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String label, {
    bool enabled = true,
    bool highlighted = false,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = !enabled
        ? scheme.outline
        : highlighted
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: ShapeDecoration(
          color: highlighted ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        child: Text(label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
      ),
    );
  }
}
