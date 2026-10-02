import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../doc/attach.dart';
import '../models/item.dart';
import '../service/attach_migration_service.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/tokens.dart';

/// 附件迁移清单页（content-pipeline §7 引用模式兜底）：
/// 列出所有 attach_state=ref 的条目，一键迁移为本地持有（owned）。
///
/// 三态分组：可迁移（原件可达）/ 失效（原件已不可访问，复制无从谈起）/
/// 已迁移成功（本次会话内即时反馈）。单条失败不中断批量，逐条上报结果。
class AttachMigrationPage extends StatefulWidget {
  const AttachMigrationPage({
    super.key,
    required this.handler,
    required this.repo,
  });

  final ItemActionHandler handler;
  final Repository repo;

  @override
  State<AttachMigrationPage> createState() => _AttachMigrationPageState();
}

class _AttachMigrationPageState extends State<AttachMigrationPage>
    with RepoAutoReload {
  late final AttachMigrationService _service =
      AttachMigrationService(widget.handler);
  List<InboxItem> _refs = [];
  bool _loading = true;
  bool _migrating = false;
  int _done = 0;
  int _total = 0;
  final Set<String> _migrated = <String>{};
  final Map<String, String> _failed = <String, String>{}; // id → 原因

  @override
  Repository get repo => widget.repo;

  @override
  void reload() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final refs = await widget.repo.listRefs();
    if (!mounted) return;
    setState(() {
      _refs = refs;
      _loading = false;
    });
  }

  Future<void> _migrateAll() async {
    if (_migrating || _refs.isEmpty) return;
    setState(() {
      _migrating = true;
      _done = 0;
      _total = _refs.length;
      _migrated.clear();
      _failed.clear();
    });
    final items = List.of(_refs);
    await _service.migrateAll(
      items,
      onProgress: (done, total, title, ok) {
        if (!mounted) return;
        setState(() => _done = done);
      },
    );
    // 逐条结果从执行侧回填：migrateOne 单条结果在 migrateAll 内消化，
    // 此处统一重查 + 逐条探测可达性归类（避免两份状态源）
    await _load();
    if (!mounted) return;
    setState(() => _migrating = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('迁移完成：$_done 条已处理')),
    );
  }

  Future<void> _migrateOne(InboxItem item) async {
    if (_migrating) return;
    setState(() => _migrating = true);
    final r = await _service.migrateOne(item);
    if (!mounted) return;
    setState(() {
      _migrating = false;
      if (r.ok) {
        _migrated.add(item.id!);
        _failed.remove(item.id);
      } else {
        _failed[item.id!] = r.message;
      }
    });
    if (r.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('附件迁移')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _refs.isEmpty
              ? _empty(scheme)
              : _list(scheme),
    );
  }

  Widget _empty(ColorScheme scheme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt_outlined, size: 48, color: scheme.primary),
            const SizedBox(height: Insets.md),
            const Text('没有需要迁移的引用附件'),
            const SizedBox(height: Insets.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              child: Text(
                '分享收集的附件已全部本地持有，或均已完成迁移。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );

  Widget _list(ColorScheme scheme) {
    final pending = <InboxItem>[];
    final lost = <InboxItem>[];
    for (final it in _refs) {
      if (_migrated.contains(it.id)) continue;
      (it.isRef && _failed.containsKey(it.id) ? lost : pending).add(it);
    }
    return ListView(
      padding: const EdgeInsets.all(Insets.md),
      children: [
        if (!_migrating && pending.isNotEmpty)
          FilledButton.icon(
            onPressed: _migrateAll,
            icon: const Icon(Icons.download_done_outlined),
            label: Text('一键迁移全部（${pending.length}）'),
          ),
        if (_migrating)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.md),
            child: Column(
              children: [
                LinearProgressIndicator(value: _total > 0 ? _done / _total : 0),
                const SizedBox(height: Insets.sm),
                Text('迁移中 $_done/$_total…',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        _group('可迁移（原件当前可达）', pending, scheme),
        _group('失效（原件已不可访问）', lost, scheme),
        if (_migrated.isNotEmpty) _doneGroup(scheme),
      ],
    );
  }

  Widget _group(String title, List<InboxItem> items, ColorScheme scheme) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.sm),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final it in items)
          Card(
            margin: const EdgeInsets.only(bottom: Insets.sm),
            child: ListTile(
              title: Text(
                it.humanTitle ?? it.rawFilePath?.split('/').last ?? it.id ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: _failed.containsKey(it.id)
                  ? Text(
                      _failed[it.id]!,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    )
                  : Text(
                      Attach.statusText(it.attachState) ?? '',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
              trailing: _migrating
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.copy_all_outlined),
                      tooltip: '迁移为本地持有',
                      onPressed: () => _migrateOne(it),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _doneGroup(ColorScheme scheme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.sm),
            child: Text('本次已迁移（${_migrated.length}）',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Card(
            margin: const EdgeInsets.only(bottom: Insets.sm),
            child: ListTile(
              leading: Icon(Icons.check_circle_outline, color: scheme.primary),
              title: Text('已迁移为本地持有', style: Theme.of(context).textTheme.bodyMedium),
            ),
          ),
        ],
      );
}
