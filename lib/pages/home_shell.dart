import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../share/text_collector.dart';
import '../service/mcp_controller.dart';
import 'ai_tags_page.dart';
import 'inbox_page.dart';
import 'quick_note_sheet.dart';
import 'settings_page.dart';
import 'timeline_page.dart';
import 'vault_page.dart';

/// 主壳：底部 5 tab（时光机/全部/AI 分类/保险箱/设置）+ 中央 FAB「速记」
/// （设计 §3 导航架构；不做其它顶层入口，除非回写需求）。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.repo,
    required this.handler,
    required this.collector,
    required this.mcp,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final McpController mcp;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final List<Widget> _pages = [
    TimelinePage(repo: widget.repo, handler: widget.handler),
    InboxPage(repo: widget.repo, handler: widget.handler),
    const AiTagsPage(),
    VaultPage(repo: widget.repo, handler: widget.handler),
    SettingsPage(
      repo: widget.repo,
      collector: widget.collector,
      mcp: widget.mcp,
      onCollectorChanged: () => setState(() {}),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showQuickNote,
        icon: const Icon(Icons.add),
        label: const Text('速记'),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timeline_outlined), label: '时光机'),
          NavigationDestination(icon: Icon(Icons.inbox_outlined), label: '全部'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_motion_outlined), label: 'AI 分类'),
          NavigationDestination(icon: Icon(Icons.lock_outline), label: '保险箱'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }

  Future<void> _showQuickNote() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => QuickNoteSheet(repo: widget.repo, collector: widget.collector),
    );
  }
}
