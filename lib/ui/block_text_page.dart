import 'package:flutter/material.dart';

import '../ai/capability.dart';
import 'toast.dart';
import 'tokens.dart';

/// 文本块三级处理页（detail-two-zone.md §5.1 拍板：长按 → 能力菜单 →
/// 全屏文本页）。媒体块能力卡同构的文本处理面——细分能力（翻译/摘要/
/// 未来朗读润色等）全部进本页承载，长按菜单永不膨胀。
///
/// 形态先例：block_editor_dialog（fullscreen dialog，编辑回存）。
/// 返回值：保存的文本（null = 取消）；能力按钮走既有命令层（由调用方
/// 经 [onCapability] 组装入队，本页只负责唤出与回传）。
Future<String?> showBlockTextPage(
  BuildContext context, {
  required String initialText,
  String title = '文本处理',
  String? anchorLabel,
  Future<void> Function(ContentCapability capability, String text)?
      onCapability,
}) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => _BlockTextPage(
        initialText: initialText,
        title: title,
        anchorLabel: anchorLabel,
        onCapability: onCapability,
      ),
    ),
  );
}

class _BlockTextPage extends StatefulWidget {
  const _BlockTextPage({
    required this.initialText,
    required this.title,
    this.anchorLabel,
    this.onCapability,
  });

  final String initialText;
  final String title;
  final String? anchorLabel;
  final Future<void> Function(ContentCapability, String)? onCapability;

  @override
  State<_BlockTextPage> createState() => _BlockTextPageState();
}

class _BlockTextPageState extends State<_BlockTextPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run(ContentCapability cap) async {
    await widget.onCapability?.call(cap, _ctrl.text);
    if (!mounted) return;
    ToastManager.show('已开始${cap.label}');
  }

  void _save() => Navigator.of(context).pop(_ctrl.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caps = capabilitiesFor(BlockKind.text);
    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.anchorLabel != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.sm,
                  Insets.lg,
                  0,
                ),
                child: Text(
                  widget.anchorLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            // 能力行：文本块适用能力（菜单不膨胀的承载面，扩展有空间）
            if (caps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
                child: Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    for (final c in caps)
                      ActionChip(
                        avatar: const Icon(Icons.auto_awesome, size: 16),
                        label: Text(c.label),
                        onPressed: () => _run(c),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Insets.lg),
                child: TextField(
                  controller: _ctrl,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '编辑文本…',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
