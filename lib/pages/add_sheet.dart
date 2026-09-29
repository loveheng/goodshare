import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../models/item.dart';
import '../share/text_collector.dart';
import '../ui/content_card.dart';
import 'quick_note_sheet.dart';

/// 通用「添加」面板（2026-09-27 改版：悬浮球由「速记」升级为全类型添加入口）。
/// 首屏展示 7 种类型的选择网格；点击任一项后切换到该类型的专用添加 UI
/// （复用 QuickNoteSheet 的各类型分支），左上角可返回类型选择。
class AddSheet extends StatefulWidget {
  const AddSheet({
    super.key,
    required this.handler,
    required this.collector,
    this.initialType,
  });

  final ItemActionHandler handler;
  final TextCollector collector;

  /// 预选类型：非空则跳过类型网格直接进该类型的录入 UI
  /// （2026-09-30：顶部 `＋` 菜单的「拍照」等单项入口需要一步直达）。
  final String? initialType;

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialType;
  }

  @override
  Widget build(BuildContext context) {
    // 键盘避让：输入法弹起时用 viewInsets 把内容顶起，避免遮挡文本框
    // （isScrollControlled / useSafeArea 已在 home_shell 的 showModalBottomSheet 设置）。
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              if (_selected != null)
                IconButton(
                  tooltip: '返回类型选择',
                  icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  onPressed: () => setState(() => _selected = null),
                ),
              const Spacer(),
              Text(
                _selected == null ? '添加' : '添加${ContentCard.labelOf(_selected!)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
        if (_selected == null)
          _TypeGrid(
            onSelected: (t) {
              // 选类型后收起键盘、重置输入态（新 QuickNoteSheet 实例）
              FocusScope.of(context).unfocus();
              setState(() => _selected = t);
            },
          )
        else
          QuickNoteSheet(
            handler: widget.handler,
            collector: widget.collector,
            initialType: _selected,
          ),
      ],
      ),
    );
  }
}

/// 类型选择网格：图标 + 文案，2 列布局。
class _TypeGrid extends StatelessWidget {
  const _TypeGrid({required this.onSelected});

  final void Function(String type) onSelected;

  static const _items = [
    (InboxItem.typeNote, '便签'),
    (InboxItem.typeUrl, '链接'),
    (InboxItem.typeImage, '图片'),
    (InboxItem.typeChatlog, '聊天'),
    (InboxItem.typeAudio, '录音/音频'),
    (InboxItem.typeVideo, '视频'),
    (InboxItem.typeDocument, '文档'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 3.2,
        ),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final (type, label) = _items[i];
          return Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => onSelected(type),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(
                      ContentCard.iconOf(type),
                      size: 22,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
