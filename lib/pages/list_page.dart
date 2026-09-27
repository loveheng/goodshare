import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/repository.dart';
import '../models/item.dart';
import '../service/mcp_controller.dart';
import 'mcp_page.dart';

/// 收集列表主页：搜索 + 列表 + 详情。
class ListPage extends StatefulWidget {
  const ListPage({super.key, required this.repo, required this.mcp});

  final Repository repo;
  final McpController mcp;

  @override
  State<ListPage> createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<CollectItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.repo.removeListener(_reload);
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(query: _searchCtrl.text, limit: 200);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _reload);
  }

  void _openDetail(CollectItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _DetailSheet(repo: widget.repo, item: item, onChanged: _reload),
    );
  }

  IconData _typeIcon(String type) => switch (type) {
        CollectItem.typeLink => Icons.link,
        CollectItem.typeImage => Icons.image_outlined,
        CollectItem.typeVideo => Icons.movie_outlined,
        CollectItem.typeAudio => Icons.audiotrack,
        CollectItem.typeFile => Icons.insert_drive_file_outlined,
        _ => Icons.notes,
      };

  String _timeLabel(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('拾贝'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'MCP 服务',
            icon: Icon(
              Icons.cloud_sync_outlined,
              color: widget.mcp.running ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => McpPage(controller: widget.mcp)),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索标题 / 正文 / 标签',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 48, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 12),
                      const Text('还没有收集'),
                      const SizedBox(height: 4),
                      Text('在任意 app 点「分享」→「拾贝」即可收集好东西',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      return ListTile(
                        leading: Icon(_typeIcon(it.type)),
                        title: Text(
                          it.preview.isEmpty ? '（无文本内容）' : it.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (it.sourceApp?.isNotEmpty ?? false) it.sourceApp!,
                            _timeLabel(it.createdAt),
                            if (it.tags.isNotEmpty) '#${it.tags.join(' #')}',
                            if (it.hasAttachment) '📎${it.files.length}',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _openDetail(it),
                      );
                    },
                  ),
                ),
    );
  }
}

class _DetailSheet extends StatelessWidget {
  const _DetailSheet({required this.repo, required this.item, required this.onChanged});

  final Repository repo;
  final CollectItem item;
  final Future<void> Function() onChanged;

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条收集？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await repo.delete(item.id!);
      if (context.mounted) Navigator.pop(context);
      await onChanged();
    }
  }

  Future<void> _reshare(BuildContext context) async {
    await SharePlus.instance.share(
      ShareParams(
        text: item.text,
        title: item.title,
        files: [for (final f in item.files) XFile(f)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (item.sourceApp?.isNotEmpty ?? false) '来源：${item.sourceApp}',
      if (item.sourcePackage?.isNotEmpty ?? false) item.sourcePackage!,
      if (item.mime?.isNotEmpty ?? false) item.mime!,
      if (item.tags.isNotEmpty) '标签：${item.tags.join('、')}',
    ].join(' · ');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          if (item.title?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(item.title!, style: Theme.of(context).textTheme.titleLarge),
            ),
          if (meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(meta, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (item.text?.isNotEmpty ?? false)
            SelectableText(item.text!, style: const TextStyle(height: 1.5)),
          for (final f in item.files)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: item.isImage
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(File(f), fit: BoxFit.contain),
                    )
                  : ListTile(
                      leading: const Icon(Icons.attach_file),
                      title: Text(f.split('/').last),
                    ),
            ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: item.text ?? item.title ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制'),
              ),
              OutlinedButton.icon(
                onPressed: () => _reshare(context),
                icon: const Icon(Icons.share_outlined),
                label: const Text('再分享'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _delete(context),
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
