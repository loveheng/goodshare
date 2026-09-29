import 'dart:async';

import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../ai/ai_queue_service.dart';
import '../ai/capabilities.dart';
import '../ai/llm_model_manager.dart';
import '../ai/model_manager.dart';
import '../data/repository.dart';
import '../service/mcp_controller.dart';
import '../service/secure_window.dart';
import '../share/text_collector.dart';
import '../sync/backup_service.dart';
import '../ui/quick_note_bar.dart';
import 'inbox_page.dart';
import 'recent_deleted_page.dart';
import 'settings_page.dart';
import 'task_queue_page.dart';
import 'workspace_page.dart';

/// 主壳（2026-09-30 改版）：底部 3 tab（全部 / 工作区 / 设置）+ 底部常驻速记条
/// + 侧边栏（低频 / 隐私入口）。
///
/// 收敛说明（ui-spec §3）：时光机降为主列表排序维度、AI 分类降为标签筛选维度、
/// 保险箱移入侧边栏（安全域，视图仍由「全部」页承载），悬浮球已删除。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.repo,
    required this.handler,
    required this.collector,
    required this.mcp,
    required this.caps,
    required this.models,
    required this.llmModels,
    required this.aiQueue,
    required this.backup,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final McpController mcp;
  final AiCapabilities caps;
  final ModelManager models;
  final LlmModelManager llmModels;
  final AiQueueService aiQueue;
  final BackupService backup;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  int _index = 0; // 首页落点：全部

  /// 保险箱视图（安全域）：由侧边栏入口或主列表「保险箱」chip 切换。
  bool _vaultOnly = false;

  @override
  void initState() {
    super.initState();
    // 启动时处于普通视图：确保 FLAG_SECURE 关闭，普通页面可截图分享。
    unawaited(SecureWindow.setVaultTabVisible(false));
  }

  /// 保险箱视图切换 → 同步防截图（FLAG_SECURE）。
  ///
  /// 原实现绑定 tab 索引（`_vaultIndex`），保险箱不再占 tab 后改为按「当前是否
  /// 处于保险箱视图」判定——这是本次改版的连带改动。
  void _setVaultOnly(bool v) {
    setState(() => _vaultOnly = v);
    unawaited(SecureWindow.setVaultTabVisible(v));
  }

  void _openVault() {
    Navigator.of(context).pop(); // 关抽屉
    setState(() => _index = 0);
    _setVaultOnly(true);
  }

  late final List<Widget> _pages = [
    InboxPage(
      key: ValueKey<bool>(_vaultOnly),
      repo: widget.repo,
      handler: widget.handler,
      collector: widget.collector,
      caps: widget.caps,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
      vaultOnly: _vaultOnly,
      onVaultOnlyChanged: _setVaultOnly,
    ),
    WorkspacePage(
      repo: widget.repo,
      handler: widget.handler,
      caps: widget.caps,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    ),
    SettingsPage(
      handler: widget.handler,
      repo: widget.repo,
      caps: widget.caps,
      collector: widget.collector,
      mcp: widget.mcp,
      models: widget.models,
      llmModels: widget.llmModels,
      aiQueue: widget.aiQueue,
      backup: widget.backup,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          IndexedStack(index: _index, children: _pages),
          // 速记条：仅内容页显示（设置页不显示），详情页是 push 出去的新页面
          // 故天然不显示，不会与详情底部操作条并存。
          if (_index != 2)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: QuickNoteBar(collector: widget.collector),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inbox_outlined), label: '全部'),
          NavigationDestination(
              icon: Icon(Icons.workspaces_outlined), label: '工作区'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }

  /// 侧边栏：低频 / 隐私入口（不再承担分类导航，分类已并入主列表筛选 chips）。
  Drawer _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('拾贝 goodshare',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('低频与隐私入口',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          // 安全域：带锁图标，与普通入口视觉区分
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('保险箱'),
            subtitle: const Text('不进备份、MCP 不可见'),
            onTap: _openVault,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('最近删除'),
            subtitle: const Text('30 天内可恢复 / 彻底删除'),
            onTap: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute<void>(
                builder: (_) => RecentDeletedPage(
                  handler: widget.handler,
                  repo: widget.repo,
                ),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.list_alt_outlined),
            title: const Text('AI 任务队列'),
            subtitle: const Text('查看 OCR / 转写任务状态'),
            onTap: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute<void>(
                builder: (_) => TaskQueuePage(repo: widget.repo),
              ));
            },
          ),
          // 占位入口保留：AI 分类已降为标签维度，暂由主列表 chips 承载，
          // 此处不再重复给入口（ui-spec §4.7）。
        ],
      ),
    );
  }
}
