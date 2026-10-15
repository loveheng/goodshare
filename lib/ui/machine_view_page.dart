import 'package:flutter/material.dart';

import '../models/item.dart';
import 'tokens.dart';

/// 机器态查看页（P1-5 降级拍板，detail-page-visual-audit.md §6 盲点 B）：
/// 机器态是开发者/极客调试专用的极低频特性，不再作为读态正文的整页替换态
/// （原 `ItemViewTemplate.machineMode` 正文流内对切已撤）——降级为独立二级
/// 全屏页，读态容器保持纯粹，入口仍走详情页 `⋯` 面板（受设置「机器码」
/// 开关门控，默认关闭）。
class MachineViewPage extends StatelessWidget {
  const MachineViewPage({super.key, required this.item});

  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // JSON 美化收口模型层（machineJsonPretty，R2-ui-json-codec：UI 禁内联编解码）
    final pretty = item.machineJsonPretty;
    final body = pretty == null
        ? Text(
            '暂无机器态（基础模式）\n\n机器态由 AI 管线 / 桌面端经 MCP 写入'
            '（强类型 JSON，供大模型消费）。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        : Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: SelectableText(
              pretty,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          );
    return Scaffold(
      appBar: AppBar(title: const Text('机器态')),
      body: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: body,
      ),
    );
  }
}
