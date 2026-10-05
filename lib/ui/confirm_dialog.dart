import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 统一确认弹窗（ui-spec §6「裸 AlertDialog 只做快速确认」的单一实现）。
///
/// 全 App 的删除/清空/放弃改动/重置类二次确认都走这里，不再手写
/// `AlertDialog`：按钮档位、取消/确认语义、危险态红字一处收口。
/// 返回 true = 用户确认。
///
/// [danger] 为 true 时确认钮用 error 色（删除类）；false 用主题默认
/// （FilledButton，非危险确认如「解除编辑锁定」「从 S3 恢复」）。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? content,
  String confirmText = '确认',
  String cancelText = '取消',
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: content == null ? null : Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelText),
        ),
        danger
            ? FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(confirmText),
              )
            : FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(confirmText),
              ),
      ],
    ),
  );
  if (ok == true && danger) HapticFeedback.heavyImpact();
  return ok == true;
}
