import 'package:flutter/material.dart';

import 'slogans.dart';
import 'tokens.dart';

/// 统一加载态（goodshare-ui「异步加载三态」单一实现）：
/// 居中 `CircularProgressIndicator`，替换散落各页的 `Center(child: …)` 手写。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

/// 统一错误降级态（goodshare-ui「加载失败，点击重试」占位的单一实现）：
/// 未捕获异常绝不抛红屏，错误必须可感知、可重试。
class ErrorRetryView extends StatelessWidget {
  const ErrorRetryView({super.key, this.message = '加载失败，点击重试', this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: InkWell(
        onTap: onRetry,
        borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: scheme.onSurfaceVariant),
              const SizedBox(height: Insets.sm),
              Text(message, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一空态（mymind 口号式空态的单一实现）：衬线口号 + 可选动作。
/// 裸 `Center(child: Text('暂无 XX'))` 一律替换至此，空态不再各页各写。
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({super.key, required this.text, this.action});

  /// 空态文案（一句话，非动作教学——ui-spec §2.4 禁手势教学文案）。
  final String text;

  /// 可选动作（如「清除筛选」）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PoeticText(text),
          if (action != null) ...[
            const SizedBox(height: Insets.lg),
            action!,
          ],
        ],
      ),
    );
  }
}
