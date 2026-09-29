import 'package:flutter/material.dart';

import '../share/text_collector.dart';
import 'tokens.dart';

/// 底部常驻速记条（2026-09-29 改版：取代悬浮球）。
///
/// 硬要求：速记路径**不得比原悬浮球更长**——原路径是「点球 → 选便签 → 打字」，
/// 故本条**点即聚焦、打字即存**，不再经过类型选择。
///
/// 导入类动作（拍照 / 扫描文档 / 导入文件）**不在本条上**，归顶部 `＋` 菜单
/// （ui-spec §4.6 的分工：本条只管「写字」，`＋` 只管「把外部资源拿进来」）。
class QuickNoteBar extends StatefulWidget {
  const QuickNoteBar({super.key, required this.collector});

  final TextCollector collector;

  @override
  State<QuickNoteBar> createState() => _QuickNoteBarState();
}

class _QuickNoteBarState extends State<QuickNoteBar> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final item = await widget.collector.collectText(text);
      if (!mounted) return;
      _ctrl.clear();
      messenger.showSnackBar(
        SnackBar(content: Text(item == null ? '未保存（内容为空）' : '已记下')),
      );
    } catch (e) {
      // 失败原因原样告知（R1：错误要被用户感知，不自行编造兜底文案）
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: '记点什么…',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Insets.md,
                      vertical: Insets.sm,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm),
              IconButton.filledTonal(
                onPressed: _sending ? null : _submit,
                icon: const Icon(Icons.arrow_upward),
                tooltip: '记下',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
