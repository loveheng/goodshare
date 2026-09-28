import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../ai/ai_queue_service.dart';
import '../ai/capabilities.dart';
import '../ai/model_manager.dart';
import '../data/repository.dart';
import '../share/text_collector.dart';
import '../service/mcp_controller.dart';
import '../ui/floating_ball.dart';
import 'add_sheet.dart';
import 'ai_tags_page.dart';
import 'inbox_page.dart';
import 'recent_deleted_page.dart';
import 'settings_page.dart';
import 'timeline_page.dart';
import 'vault_page.dart';

/// 主壳：底部 5 tab（全部/时光机/AI 分类/保险箱/设置）+ 悬浮球「添加」
/// （2026-09-27 改版：「全部」与「时光机」交换、首页落点为全部；悬浮球由
/// 速记升级为全类型通用添加入口；设计 §3 导航架构同步回写 ui-spec）。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.repo,
    required this.handler,
    required this.collector,
    required this.mcp,
    required this.caps,
    required this.models,
    required this.aiQueue,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final McpController mcp;
  final AiCapabilities caps;
  final ModelManager models;
  final AiQueueService aiQueue;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = 0; // 首页落点：全部
  late final List<Widget> _pages = [
    InboxPage(
      repo: widget.repo,
      handler: widget.handler,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    ),
    TimelinePage(
      repo: widget.repo,
      handler: widget.handler,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    ),
    AiTagsPage(onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer()),
    VaultPage(
      repo: widget.repo,
      handler: widget.handler,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    ),
    SettingsPage(
      handler: widget.handler,
      repo: widget.repo,
      caps: widget.caps,
      collector: widget.collector,
      mcp: widget.mcp,
      models: widget.models,
      aiQueue: widget.aiQueue,
      onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(),
      // 悬浮球贴边（速记入口，可拖拽吸附左右边），取代原中央 FAB
      body: Stack(
        children: [
          IndexedStack(index: _index, children: _pages),
          FloatingBall(onTap: _showAdd),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inbox_outlined), label: '全部'),
          NavigationDestination(icon: Icon(Icons.timeline_outlined), label: '时光机'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_motion_outlined), label: 'AI 分类'),
          NavigationDestination(icon: Icon(Icons.lock_outline), label: '保险箱'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }

  Future<void> _showAdd() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.5,
        maxChildSize: 1.0,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child:           AddSheet(
            handler: widget.handler,
            collector: widget.collector,
          ),
        ),
      ),
    );
  }

  /// 侧边抽屉：已开发功能的简易聚合入口（不内嵌任何业务逻辑，仅导航）。
  Drawer _buildDrawer() {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: scheme.primaryContainer),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('拾贝 goodshare',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('已开发功能入口',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('最近删除'),
            subtitle: const Text('30 天内可恢复 / 彻底删除'),
            onTap: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute<void>(
                builder: (_) => RecentDeletedPage(handler: widget.handler, repo: widget.repo),
              ));
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.auto_awesome_motion_outlined),
            title: const Text('AI 分类'),
            onTap: () {
              Navigator.of(context).pop();
              setState(() => _index = 2);
            },
          ),
          ListTile(
            leading: const Icon(Icons.brush_outlined),
            title: const Text('图片标注'),
            subtitle: const Text('在图片详情页点「标注图片」'),
            onTap: () {
              Navigator.of(context).pop();
              setState(() => _index = 0);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('OCR 图片转写'),
            subtitle: const Text('设置 → 开关'),
            onTap: () {
              Navigator.of(context).pop();
              setState(() => _index = 4);
            },
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq_outlined),
            title: const Text('录音/音频转写'),
            subtitle: const Text('设置 → 模型下载'),
            onTap: () {
              Navigator.of(context).pop();
              setState(() => _index = 4);
            },
          ),
          ListTile(
            leading: const Icon(Icons.link_outlined),
            title: const Text('链接离线抓取'),
            subtitle: const Text('设置 → 开关'),
            onTap: () {
              Navigator.of(context).pop();
              setState(() => _index = 4);
            },
          ),
        ],
      ),
    );
  }
}
