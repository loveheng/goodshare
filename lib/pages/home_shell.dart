
import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../ai/ai_queue_service.dart';
import '../ai/capabilities.dart';
import '../ai/llm_model_manager.dart';
import '../ai/model_manager.dart';
import '../data/repository.dart';
import '../service/mcp_controller.dart';
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

  /// 主列表批量选择模式激活中（card-batch-selection §2.1）：底部导航与
  /// 速记条让位——操作栏由 InboxPage 自己的 Scaffold bottomNavigationBar 承载。
  bool _selectionMode = false;

  @override
  void initState() {
    super.initState();
  }

  /// 保险箱视图切换：仅切换列表过滤状态（显示保险箱条目）。
  ///
  /// 保险箱子页面不再屏蔽截图，安全等级与普通页面一致（2026-10-02 拍板）。
  void _setVaultOnly(bool v) {
    setState(() => _vaultOnly = v);
  }

  /// 切 tab 即放弃选择（瞬态任务语义，拍板）；同时离开保险箱子态——
  /// 保险箱仅存在于「全部」tab，从工作区/设置切回「全部」应回普通列表而非滞留。
  void _selectTab(int i) {
    setState(() {
      _index = i;
      if (i != 0) _selectionMode = false;
      _vaultOnly = false;
    });
  }

  void _openVault() {
    Navigator.of(context).pop(); // 关抽屉
    setState(() => _index = 0);
    _setVaultOnly(true);
  }

  // 必须是 getter（非 late final）：_vaultOnly 在运行期翻转，InboxPage 需随每次
  // build 拿到最新 vaultOnly；否则首帧固化的 false 会让保险箱视图永远不出现。
  List<Widget> get _pages => [
        InboxPage(
          key: ValueKey<bool>(_vaultOnly),
      repo: widget.repo,
      handler: widget.handler,
      collector: widget.collector,
      caps: widget.caps,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
      vaultOnly: _vaultOnly,
      onVaultOnlyChanged: _setVaultOnly,
      onSelectionModeChanged: (v) => setState(() => _selectionMode = v),
    ),
    WorkspacePage(
      repo: widget.repo,
      handler: widget.handler,
      caps: widget.caps,
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
          // 速记条：仅首页（「全部」tab）显示（2026-09-30 用户拍板：工作区不显示），
          // 保险箱视图不显示（安全域为内容让路，采集动作与私密上下文冲突），
          // 详情页是 push 出去的新页面故天然不显示，不会与详情底部操作条并存。
          // 选择模式中让位（card-batch-selection §2.1 让位矩阵）。
          if (_index == 0 && !_selectionMode && !_vaultOnly)
            Positioned(
              // 四边拉满：Stack 只在上下边同时给出时才收紧高度——此前仅 bottom
              // 锚点时高度无界，展开态 Column+Expanded 触发 unbounded flex
              // 异常，整棵便利贴子树渲染失败（真机=点一下整个功能消失）。
              // 键盘让位仍由 Scaffold resize 承担，此处不做任何高度手算。
              left: 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: QuickNoteBar(
                collector: widget.collector,
                handler: widget.handler,
              ),
            ),
        ],
      ),
      // 保险箱视图藏底栏（安全域沉浸，2026-10-05 拍板）：底栏是「全部」页的
      // 导航 chrome，在保险箱里点工作区/设置还会打断隐私上下文；选择模式让位
      // 逻辑不变（操作栏由 InboxPage 自己的 Scaffold 承载）。
      bottomNavigationBar: (_selectionMode || _vaultOnly)
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _selectTab,
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
