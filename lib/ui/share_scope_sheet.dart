import 'package:flutter/material.dart';

import 'tokens.dart';

/// 分享产物内容勾选项（detail-two-zone.md §6 预警补丁）。
class ShareScope {
  const ShareScope({
    this.includeBody = true,
    this.includeSummary = true,
    this.includeInspiration = false,
    this.includeBlockAppendix = false,
  });

  /// 正文（恒可用，默认开）。
  final bool includeBody;

  /// AI 摘要。
  final bool includeSummary;

  /// 灵感区（用户私密碎片，**默认关**——不得无提示进分享产物）。
  final bool includeInspiration;

  /// 块级附录（OCR/转写文本，默认关）。
  final bool includeBlockAppendix;

  bool get includeAnything =>
      includeBody || includeSummary || includeInspiration || includeBlockAppendix;
}

/// 分享预览 Sheet（渲染前拉起）：轻量勾选产物内容，返回 [ShareScope]；
/// 取消返回 null。
///
/// 灵感区默认关是隐私红线：私密碎片不得无提示进分享长图/PDF。
Future<ShareScope?> showShareScopeSheet(BuildContext context) {
  var scope = const ShareScope();
  return showModalBottomSheet<ShareScope>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        void toggle(void Function() fn) {
          setSheet(() => fn());
        }

        Widget tile(String label, String? subtitle, bool value,
            ValueChanged<bool> onChanged) {
          return CheckboxListTile(
            value: value,
            onChanged: (v) => toggle(() => onChanged(v ?? false)),
            title: Text(label),
            subtitle: subtitle == null
                ? null
                : Text(
                    subtitle,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                  ),
            dense: true,
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.sm,
              Insets.lg,
              Insets.xl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '分享内容',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: Insets.xs),
                tile('正文', null, scope.includeBody,
                    (v) => scope = _copy(scope, includeBody: v)),
                tile('AI 摘要', null, scope.includeSummary,
                    (v) => scope = _copy(scope, includeSummary: v)),
                tile(
                  '灵感区',
                  '你的私密想法，默认不包含',
                  scope.includeInspiration,
                  (v) => scope = _copy(scope, includeInspiration: v),
                ),
                tile(
                  '识别与转写文本',
                  '图片文字识别 / 音视频转写产出',
                  scope.includeBlockAppendix,
                  (v) => scope = _copy(scope, includeBlockAppendix: v),
                ),
                const SizedBox(height: Insets.sm),
                FilledButton(
                  onPressed: scope.includeAnything
                      ? () => Navigator.pop(ctx, scope)
                      : null,
                  child: const Text('继续分享'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

ShareScope _copy(
  ShareScope s, {
  bool? includeBody,
  bool? includeSummary,
  bool? includeInspiration,
  bool? includeBlockAppendix,
}) {
  return ShareScope(
    includeBody: includeBody ?? s.includeBody,
    includeSummary: includeSummary ?? s.includeSummary,
    includeInspiration: includeInspiration ?? s.includeInspiration,
    includeBlockAppendix: includeBlockAppendix ?? s.includeBlockAppendix,
  );
}
