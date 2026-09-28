import 'dart:async';

import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../service/secure_window.dart';
import '../ui/content_card.dart';
import '../ui/drawer_menu_button.dart';
import '../ui/repo_auto_reload.dart';
import 'item_detail_page.dart';

/// 保险箱页：is_vault=1 列表，动作走 vaultContext=true（可移出）。
/// 生物识别门随 V3 加密一并上线（D1 决策）；当前内容仅存在于本机。
class VaultPage extends StatefulWidget {
  const VaultPage({super.key, required this.repo, required this.handler, this.onOpenDrawer});

  final Repository repo;
  final ItemActionHandler handler;
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
    // 进入保险箱即开启 FLAG_SECURE，防止敏感内容被截屏 / 多任务卡片偷窥
    unawaited(SecureWindow.setSecure(true));
    _reload();
  }

  @override
  void dispose() {
    // 离开保险箱清除 FLAG_SECURE，恢复普通页面可截图分享
    unawaited(SecureWindow.setSecure(false));
    super.dispose();
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
