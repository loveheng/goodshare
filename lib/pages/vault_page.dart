import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../ui/content_card.dart';
import '../ui/drawer_menu_button.dart';
import '../ui/repo_auto_reload.dart';
import 'item_detail_page.dart';

/// 保险箱页：is_vault=1 列表，动作走 vaultContext=true（可移出）。
/// 生物识别门随 V3 加密一并上线（D1 决策）；当前内容仅存在于本机。
///
/// 安全窗（FLAG_SECURE）不再由此页生命周期驱动——主页用 IndexedStack 常驻挂载，
/// initState 在启动即触发会导致全局「银行级」不可截图。由 HomeShell 按当前 tab
/// 索引统一开关（见 [SecureWindow.setVaultTabVisible]）。
class VaultPage extends StatefulWidget {
  const VaultPage({
    super.key,
    required this.repo,
    required this.handler,
    required this.caps,
    this.onOpenDrawer,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final AiCapabilities caps; // 详情页翻译预检用
  final VoidCallback? onOpenDrawer;

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> with RepoAutoReload {
  List<InboxItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  Repository get repo => widget.repo;

  @override
  void reload() => _reload();

  Future<void> _reload() async {
    final items = await widget.repo.list(vault: true, limit: 500);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuLeading(widget.onOpenDrawer),
        title: const Text('保险箱'),
        actions: [
          IconButton(
            tooltip: '生物识别门（V3）',
            icon: const Icon(Icons.fingerprint),
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('生物识别门随 V3 加密上线')),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline,
                          size: 48, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 12),
                      const Text('保险箱是空的'),
                      const SizedBox(height: 4),
                      Text('在条目详情点「移入保险箱」，内容即对 MCP 物理不可见',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      return ContentCard(
                        item: it,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => ItemDetailPage(
                              repo: widget.repo,
                              handler: widget.handler,
                              item: it,
                              caps: widget.caps,
                              vaultContext: true,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
