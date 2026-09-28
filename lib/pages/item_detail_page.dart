import 'dart:async';

import 'package:flutter/material.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../app/lifecycle_manager.dart';
import '../data/repository.dart';
import '../models/draft_store.dart';
import '../models/item.dart';
import '../service/secure_window.dart';
import '../ui/content_card.dart';
import '../ui/draft_controller.dart';
import '../ui/item_view_template.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/tokens.dart';

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

class _ItemDetailPageState extends State<ItemDetailPage> with RepoAutoReload {
  late InboxItem _item = widget.item;
  EditDraft? _editDraft;
  StreamSubscription<AppLifecycleState>? _lifecycleSub;

  @override
  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    // 退后台时强制落盘正在编辑的草稿
    _lifecycleSub = AppLifecycleManager.instance.onBackgrounded.listen((_) => _editDraft?.flushAll());
    // Vault 敏感内容：开启 FLAG_SECURE 防截屏（离开时清除）
    if (widget.vaultContext) unawaited(SecureWindow.setSecure(true));
  }

  @override
  void dispose() {
    _lifecycleSub?.cancel();
    if (widget.vaultContext) unawaited(SecureWindow.setSecure(false));
    super.dispose();
  }

  @override
  void reload() => _reload();

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

  Future<void> _run(Future<Object?> Function() action, String done) async {
    try {
      final res = await action();
      // 命令层可能回更具体的提示（如「已放入任务列表，前面还有 N 条」），优先展示
      _snack(res is CommandResult ? (res.note ?? done) : done);
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
        () => widget.handler.execute(
          DeleteItemCommand(_item.id!),
          vaultContext: widget.vaultContext,
        ),
        '已删除（30 天内可恢复）',
      );
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _edit() async {
    if (_editDraft != null) return; // 防重入
    final store = DraftStore();
    final id = _item.id!;
    final baseId = 'edit:$id';
    final title = DraftController(draftId: '$baseId:title', targetId: id, store: store, initialContent: _item.humanTitle ?? '');
    final tldr = DraftController(draftId: '$baseId:tldr', targetId: id, store: store, initialContent: _item.humanTldr ?? '');
    final body = DraftController(draftId: '$baseId:body', targetId: id, store: store, initialContent: _item.humanMd ?? _item.rawContent ?? '');
    _editDraft = EditDraft(baseId: baseId, targetId: id, store: store, title: title, tldr: tldr, body: body);
    await _editDraft!.loadAll(); // 优先恢复已落盘草稿
    if (!mounted) {
      _editDraft!.dispose();
      _editDraft = null;
      return;
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _editDraft!.title.text,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: Insets.sm),
            TextField(
              controller: _editDraft!.tldr.text,
              decoration: const InputDecoration(labelText: 'TL;DR'),
            ),
            const SizedBox(height: Insets.sm),
            TextField(
              controller: _editDraft!.body.text,
              maxLines: 6,
              decoration: const InputDecoration(labelText: '内容（Markdown）'),
            ),
            const SizedBox(height: Insets.md),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) {
      _editDraft!.dispose();
      _editDraft = null;
      return;
    }
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(
          id: _item.id!,
          title: title.text.text.trim(),
          tldr: tldr.text.text.trim(),
          humanMd: body.text.text,
        ),
        vaultContext: widget.vaultContext,
      ),
      '已保存',
    );
    await _editDraft!.clearAll();
    _editDraft!.dispose();
    _editDraft = null;
  }

  Future<void> _reclassify() async {
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(Insets.md), child: Text('重分类为（AI 未处理时的手动纠正）')),
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
      () => widget.handler.execute(
        ReclassifyCommand(_item.id!, target),
        vaultContext: widget.vaultContext,
      ),
      '已重分类',
    );
  }

  @override
  Widget build(BuildContext context) {
    final vault = _item.isVault;
    return Scaffold(
      appBar: AppBar(title: Text('${ContentCard.labelOf(_item.itemType)}详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.md, Insets.xl, Insets.xxl),
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
                    () => widget.handler.execute(
                      UnlockEditCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
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
              // 转写**只手动触发**（音频不做实时 / 摄入即转写，只存文件）：
              // 仅音频 / 视频条目显示，点击才入队 transcribe_audio 跑 Sherpa。
              if (_item.itemType == InboxItem.typeAudio || _item.itemType == InboxItem.typeVideo)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.execute(
                      TranscribeCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
                    '已入队转写',
                  ),
                  icon: const Icon(Icons.subtitles_outlined),
                  label: const Text('转写'),
                ),
              // 图片 OCR 同样**只手动触发**（与音频转写对称）：仅图片条目显示。
              if (_item.itemType == InboxItem.typeImage)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.execute(
                      OcrCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
                    '已入队 OCR',
                  ),
                  icon: const Icon(Icons.document_scanner_outlined),
                  label: const Text('识别文字'),
                ),
              if (!vault)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.execute(SetVaultCommand(_item.id!, true)),
                    '已移入保险箱',
                  ),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('移入保险箱'),
                )
              else if (widget.vaultContext)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.execute(
                      SetVaultCommand(_item.id!, false),
                      vaultContext: true,
                    ),
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
