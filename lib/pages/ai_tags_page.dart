import 'package:flutter/material.dart';

import '../ui/drawer_menu_button.dart';

/// AI 分类（多视角聚类，设计 §4.10）：MVP 无 facets 时为空态占位。
/// 视角/聚类标签由 AI 打标（V2 §3.8 ReconstructResult.facets）动态生成。
class AiTagsPage extends StatelessWidget {
  const AiTagsPage({super.key, this.onOpenDrawer});

  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: drawerMenuLeading(onOpenDrawer), title: const Text('AI 分类')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_motion_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('暂无分类'),
            const SizedBox(height: 4),
            Text('离线 AI 打标（V2）生效后，这里出现主题 / 事件 / 项目等视角',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
