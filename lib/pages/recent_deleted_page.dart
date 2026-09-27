import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../models/item.dart';

/// 最近删除：保留期内可恢复或手动彻底删除；30 天后启动时自动物理清理。
class RecentDeletedPage extends StatefulWidget {
  const RecentDeletedPage({super.key, required this.repo});

  final Repository repo;

  @override
  State<RecentDeletedPage> createState() => _RecentDeletedPageState();
}

class _RecentDeletedPageState extends State<RecentDeletedPage> {
  List<InboxItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await widget.repo.listDeleted();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _confirmClearAll() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空最近删除？'),
        content: Text('将立即彻底删除全部 ${_items.length} 条，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      await widget.repo.purgeAllDeleted();
      await _reload();
    }
  }

  Future<void> _confirmDeleteForever(InboxItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除这条？'),
        content: const Text('立即物理删除（含附件），不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await widget.repo.deleteForever(it.id!);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('最近删除'),
        actions: [
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.clear_all),
            onPressed: _confirmClearAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text('没有可恢复的条目', style: Theme.of(context).textTheme.bodySmall))
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final it = _items[i];
                    final deletedAt = it.deletedAt == null
                        ? null
                        : DateTime.fromMillisecondsSinceEpoch(it.deletedAt!);
                    return ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: Text(
                        it.preview.isEmpty ? '（无文本内容）' : it.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(deletedAt == null
                          ? '已删除'
                          : '删除于 ${deletedAt.month}-${deletedAt.day.toString().padLeft(2, '0')} '
                              '${deletedAt.hour}:${deletedAt.minute.toString().padLeft(2, '0')}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () async {
                              await widget.repo.restore(it.id!);
                              await _reload();
                            },
                            child: const Text('恢复'),
                          ),
                          IconButton(
                            tooltip: '彻底删除',
                            icon: const Icon(Icons.delete_forever_outlined),
                            onPressed: () => _confirmDeleteForever(it),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
