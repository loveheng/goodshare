import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../share/text_collector.dart';
import '../service/mcp_controller.dart';
import 'mcp_page.dart';
import 'recent_deleted_page.dart';
import 'update_page.dart';

/// 设置页（设计 §5 设置树）：MCP 网关 / AI 模式(V2 灰显) / 隐私与保险箱(V2 灰显) /
/// 数据（文本收集模式 + 最近删除）/ 关于（更新页）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.repo,
    required this.collector,
    required this.mcp,
    required this.onCollectorChanged,
  });

  final Repository repo;
  final TextCollector collector;
  final McpController mcp;
  final VoidCallback onCollectorChanged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('MCP 网关'),
          ListTile(
            leading: Icon(
              Icons.cloud_sync_outlined,
              color: mcp.running ? Theme.of(context).colorScheme.primary : null,
            ),
            title: const Text('服务与连接'),
            subtitle: Text(mcp.running ? '运行中 · 端口 ${mcp.port}' : '未运行'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => McpPage(controller: mcp)),
            ),
          ),
          const _SectionHeader('AI 模式'),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('离线 AI（自动 / 强制 V1 / 尝试 V2）'),
            subtitle: const Text('V2 生效，当前为基础模式'),
            trailing: const Text('V2', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const _SectionHeader('隐私与保险箱'),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.fingerprint),
            title: const Text('FaceID 锁定保险箱'),
            subtitle: const Text('V3 生效（加密 + 生物识别门）'),
            trailing: const Text('V3', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.credit_card),
            title: const Text('身份证 / 银行卡默认打码'),
            subtitle: const Text('V2 生效（AI 管线产出时打码）'),
            trailing: const Text('V2', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.merge_type_outlined),
            title: const Text('文本收集模式'),
            subtitle: Text(collector.mode == 'merge' ? '合并（同源 5 分钟内追加为一条）' : '分散（默认，每次一条）'),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'scatter', label: Text('分散')),
                ButtonSegment(value: 'merge', label: Text('合并')),
              ],
              selected: {collector.mode},
              onSelectionChanged: (selection) {
                collector.setMode(selection.first);
                onCollectorChanged();
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('最近删除'),
            subtitle: const Text('已删条目保留 30 天，可恢复'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => RecentDeletedPage(repo: repo)),
            ),
          ),
          const _SectionHeader('关于'),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查更新'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const UpdatePage()),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}
