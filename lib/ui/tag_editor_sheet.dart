import 'package:flutter/material.dart';

import '../models/draft_store.dart';
import 'tokens.dart';

/// 全局唯一一份标签草稿的存储键（「只有一份草稿」）。
/// 输入框里还没回车/`+` 成 chip 的半截文字，按此键落盘，下次打开预填。
const String _kTagDraftId = 'tag_editor';

/// 统一标签编辑 Sheet（动词→容器词汇表：「编辑一组小项」唯一容器）。
///
/// InputChip 删 + 回车/`+` 即加（去重去空）；「保存」回传最终 chip 清单，取消回 null
/// 不动数据。原详情页 `_TagEditorSheet`（detail-two-zone.md §3 拍板 2026-10-01）抽为
/// 共享组件，便签作曲器同一动作共用同一形态。
///
/// 草稿语义（用户拍板 2026-10-05）：输入框里未提交的半截文字**不当作已存标签**，
/// 但也不丢——作为一份持久化草稿留着，下次打开预填；只有显式回车/`+` 成 chip 再保存
/// 才落库。避免「打字后直接点保存就被当成标签误存」或「直接点保存就丢字」。
Future<List<String>?> showTagEditor(
  BuildContext context, {
  required List<String> initial,
  DraftPersistencer? persistencer,
}) async {
  final store = persistencer ?? DraftStore();
  final draft = await store.load(_kTagDraftId) ?? '';
  if (!context.mounted) return null; // 跨异步间隙后守卫 context
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TagEditorSheet(
      initial: initial,
      draft: draft,
      persistencer: store,
    ),
  );
}

class TagEditorSheet extends StatefulWidget {
  const TagEditorSheet({
    super.key,
    required this.initial,
    required this.draft,
    required this.persistencer,
  });

  final List<String> initial;
  final String draft;
  final DraftPersistencer persistencer;

  @override
  State<TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<TagEditorSheet> {
  late final List<String> _tags = [...widget.initial];
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.draft.isNotEmpty) _ctrl.text = widget.draft;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 把输入框里未提交的半截文字留作草稿（持久化），下次打开仍在。
  /// [explicit] 用于 chip 已提交后清掉草稿的场景。
  Future<void> _persistDraft([String? explicit]) async {
    final text = (explicit ?? _ctrl.text).trim();
    await widget.persistencer.save(_kTagDraftId, '', text);
  }

  void _add() {
    final t = _ctrl.text.trim();
    if (t.isEmpty || _tags.contains(t)) {
      _ctrl.clear();
      _persistDraft(''); // 清空也回写，避免残留旧草稿
      return;
    }
    setState(() {
      _tags.add(t);
      _ctrl.clear();
    });
    _persistDraft(''); // 已变成正式 chip，草稿清空
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: Insets.lg,
        right: Insets.lg,
        top: Insets.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + Insets.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('编辑标签', style: theme.textTheme.titleMedium),
          const SizedBox(height: Insets.md),
          if (_tags.isNotEmpty)
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final t in _tags)
                  InputChip(
                    label: Text(t),
                    onDeleted: () => setState(() => _tags.remove(t)),
                  ),
              ],
            )
          else
            Text(
              '暂无标签，输入添加',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          const SizedBox(height: Insets.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '输入标签，回车变为标签；不回车则留作草稿',
                    filled: true,
                    fillColor: scheme.surfaceContainerLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: Insets.sm),
              IconButton(
                onPressed: _add,
                tooltip: '加入标签',
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  // 取消也保留草稿，不丢字。
                  _persistDraft();
                  Navigator.pop(context);
                },
                child: const Text('取消'),
              ),
              const SizedBox(width: Insets.sm),
              FilledButton(
                onPressed: () {
                  // 仅提交已显式成 chip 的标签；半截输入留作草稿，不误存。
                  _persistDraft();
                  Navigator.pop(context, _tags);
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
