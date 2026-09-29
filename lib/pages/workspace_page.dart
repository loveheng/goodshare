import 'package:flutter/material.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../models/workspace.dart';
import '../ui/content_card.dart';
import '../ui/tokens.dart';
import 'item_detail_page.dart';

/// 工作区（ui-spec §4.11）：条目集合容器，多对多。
///
/// 两层：①工作区列表（新建 / 进入）②某工作区内的条目列表（复用 `ContentCard`）。
/// 与「AI 分类标签」区分：工作区是用户可创建/命名的容器，标签是 AI 产出的属性。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.repo,
    required this.handler,
    required this.caps,
    this.onOpenDrawer,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final AiCapabilities caps;
  final VoidCallback? onOpenDrawer;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  late Future<List<Workspace>> _workspaces;
  Workspace? _selected;
  late Future<List<InboxItem>> _items;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _workspaces = widget.repo.listWorkspaces();
    });
  }

  void _open(Workspace ws) {
    setState(() {
      _selected = ws;
      // 与 list() 同口径：排除 Vault 与已删，工作区不得成为隐私隔离后门
      _items = widget.repo.listWorkspaceItems(ws.id);
    });
  }

  Future<void> _create() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建工作区'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(hintText: '工作区名称'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.handler.execute(CreateWorkspaceCommand(name));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: _selected == null
            ? IconButton(
                icon: const Icon(Icons.menu),
                onPressed: widget.onOpenDrawer,
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selected = null),
              ),
        title: Text(_selected?.name ?? '工作区'),
        actions: [
          if (_selected == null)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: _create,
              tooltip: '新建工作区',
            ),
        ],
      ),
      body: _selected == null
          ? _buildList(theme)
          : _buildItems(),
    );
  }

  Widget _buildList(ThemeData theme) => FutureBuilder<List<Workspace>>(
        future: _workspaces,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final ws = snap.data!;
          if (ws.isEmpty) {
            return Center(
              child: Text(
                '还没有工作区\n点右上角 + 新建',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(Insets.md),
            itemCount: ws.length,
            itemBuilder: (_, i) => Card(
              child: ListTile(
                leading: const Icon(Icons.workspaces_outlined),
                title: Text(ws[i].name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(ws[i]),
              ),
            ),
          );
        },
      );

  Widget _buildItems() => FutureBuilder<List<InboxItem>>(
        future: _items,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Text(
                '这个工作区还没有条目',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(Insets.md),
            itemCount: items.length,
            itemBuilder: (_, i) => ContentCard(
              item: items[i],
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ItemDetailPage(
                    repo: widget.repo,
                    handler: widget.handler,
                    caps: widget.caps,
                    item: items[i],
                    vaultContext: false,
                  ),
                ),
              ),
            ),
          );
        },
      );
}
