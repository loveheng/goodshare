import 'package:flutter/material.dart';

import '../ui/drawer_menu_button.dart';

/// 工作区（2026-09-30 新增 tab，当前为**空态占位**）。
///
/// 设计见 ui-spec §4.11：条目集合容器、多对多（`workspaces` + `workspace_items`
/// 两表）；手动聚合 + AI 聚合（V2）。按 Human-AI 对称性铁律，UI 能建则 AI 必能建，
/// 须配套 `WorkspaceCommand` 与 MCP 工具——**这些均未实现**，故这里不给假入口。
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key, this.onOpenDrawer});

  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuLeading(onOpenDrawer),
        title: const Text('工作区'),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.workspaces_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            const Text('还没有工作区'),
            const SizedBox(height: 4),
            Text(
              '把多个条目聚在一起（手动或让 AI 聚合），随后续版本开放',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
