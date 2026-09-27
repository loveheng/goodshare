import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../ui/content_card.dart';
import '../ui/item_view_template.dart';

/// 详情页：ItemViewTemplate 双态外壳 + 动作区。
/// 全部写操作经 ItemActionHandler（与 MCP 同一实现）；vaultContext=true 表示
/// 从保险箱页进入（可移出等 MCP 不可用的动作）。
class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({
    super.key,
    required this.repo,
    required this.handler,
    required this.item,
    this.vaultContext = false,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final InboxItem item;
  final bool vaultContext;

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late InboxItem _item = widget.item;

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_reload);
  }

  @override
  void dispose() {
    widget.repo.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final fresh = await widget.repo.byId(_item.id!, includeDeleted: true);
    if (fresh == null) return;
    if (!mounted) return;
    setState(() => _item = fresh);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      _snack(done);
      await _reload();
    } on ActionException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条收集？'),
        content: const Text('删除后 30 天内可在「设置 → 最近删除」恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await _run(
        () => widget.handler.delete(_item.id!, vaultContext: widget.vaultContext),
        '已删除（30 天内可恢复）',
      );
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _edit() async {
    final titleCtrl = TextEditingController(text: _item.humanTitle ?? '');
    final tldrCtrl = TextEditingController(text: _item.humanTldr ?? '');
    final bodyCtrl = TextEditingController(text: _item.humanMd ?? _item.rawContent ?? '');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tldrCtrl,
              decoration: const InputDecoration(labelText: 'TL;DR'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bodyCtrl,
              maxLines: 6,
              decoration: const InputDecoration(labelText: '内容（Markdown）'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    await _run(
      () => widget.handler.edit(
        _item.id!,
        title: titleCtrl.text.trim(),
        tldr: tldrCtrl.text.trim(),
        humanMd: bodyCtrl.text,
        vaultContext: widget.vaultContext,
      ),
      '已保存',
    );
  }

  Future<void> _reclassify() async {
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(12), child: Text('重分类为（AI 未处理时的手动纠正）')),
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('聊天记录'),
              onTap: () => Navigator.pop(ctx, InboxItem.typeChatlog),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('文档 / 发票'),
              onTap: () => Navigator.pop(ctx, InboxItem.typeDocument),
            ),
          ],
        ),
      ),
    );
    if (target == null) return;
    await _run(
      () => widget.handler.reclassify(_item.id!, target, vaultContext: widget.vaultContext),
      '已重分类',
    );
  }

  @override
  Widget build(BuildContext context) {
    final vault = _item.isVault;
    return Scaffold(
      appBar: AppBar(title: Text('${ContentCard.labelOf(_item.itemType)}详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          ItemViewTemplate(item: _item),
          const Divider(height: 32),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _edit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('编辑'),
              ),
              if (_item.editLocked)
                FilledButton.tonalIcon(
                  onPressed: () => _run(
                    () => widget.handler.unlockEdit(_item.id!, vaultContext: widget.vaultContext),
                    '已解除编辑锁定',
                  ),
                  icon: const Icon(Icons.lock_open),
                  label: const Text('解除编辑'),
                ),
              if (_item.sourceType == InboxItem.typeImage && _item.itemType == InboxItem.typeImage)
                OutlinedButton.icon(
                  onPressed: _reclassify,
                  icon: const Icon(Icons.category_outlined),
                  label: const Text('重分类'),
                ),
              OutlinedButton.icon(
                onPressed: () => _run(
                  () => widget.handler.reprocess(_item.id!, vaultContext: widget.vaultContext),
                  '已重新处理',
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('重新处理'),
              ),
              if (!vault)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.setVault(_item.id!, true),
                    '已移入保险箱',
                  ),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('移入保险箱'),
                )
              else if (widget.vaultContext)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.setVault(_item.id!, false, vaultContext: true),
                    '已移出保险箱',
                  ),
                  icon: const Icon(Icons.lock_open_outlined),
                  label: const Text('移出保险箱'),
                ),
              FilledButton.tonalIcon(
                onPressed: _confirmDelete,
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
