import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// AI 历史面板（ai-writeback-revert §7 / §9 拍板 1 的 MVP 极简口径）。
///
/// 只展示**刚被接管覆盖的那 1 条** AI 文本（`ai_revisions` 最新条），带
/// 「复制 / 插入」。完整历史列表属 Roadmap——MVP 不做版本浏览器，避免范围
/// 蔓延：`ai_revisions` 后端照常全量写，前端只在接管 Toast 里给这一个入口。
///
/// [onInsert] 为空（读态）时只给复制；编辑态才额外给「插入」。
Future<void> showAiRevisionSheet(
  BuildContext context, {
  required String text,
  VoidCallback? onInsert,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.lg,
                  Insets.lg,
                  Insets.sm,
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.primary),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        '上次 AI 版本',
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                child: Text(
                  '这是你接管前 AI 给出的版本，可复制或插入正文。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: Insets.md),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Insets.lg),
                  child: SelectableText(
                    text.isEmpty ? '（空）' : text,
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.sm,
                  Insets.lg,
                  Insets.lg,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            const SnackBar(content: Text('AI 版本已复制')),
                          );
                        },
                        icon: const Icon(Icons.copy_all_outlined),
                        label: const Text('复制'),
                      ),
                    ),
                    if (onInsert != null) ...[
                      const SizedBox(width: Insets.md),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            onInsert();
                          },
                          icon: const Icon(Icons.add_comment_outlined),
                          label: const Text('插入正文'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
