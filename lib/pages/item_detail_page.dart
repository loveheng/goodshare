import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../ai/translation.dart';
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
/// 该任务是否「跑完了但什么都没产出」——转写/OCR 看正文，翻译看译文。
bool aiTaskEmptyOutput(String action, InboxItem item) =>
    Repository.isTranslateAction(action) ? !item.hasTranslation : item.bodyText.trim().isEmpty;

/// 反馈文案（纯函数，便于单测）：空串表示「无需提示」。
///
/// **管线给的原因优先**：`note` 是管线写下的真实原因（如「模型未下载」「语言与模型不匹配」），
/// 比按状态猜的兜底文案准确得多——错误描述必须具体到可行动，而不是「失败了」。
String aiTaskStatusText(String status, String action, bool empty, {String? note}) {
  if (status == 'pending' || status == 'processing') {
    return '处理中… 完成后结果会自动出现在这里';
  }
  final reason = note?.trim() ?? '';
  if (reason.isNotEmpty) {
    return status == 'failed' ? '$reason（可在「AI 任务队列」重启该任务）' : reason;
  }
  if (status == 'failed') return '处理失败，可在「AI 任务队列」重启该任务';
  if (status == 'paused') return '任务已暂停，可在「AI 任务队列」继续';
  if (status == 'cancelled') return '任务已取消，可重新触发';
  if (!empty) return ''; // 已产出：不再提示
  return switch (action) {
    // 中文模型跑英文音频是最常见的「静默无产出」，必须给出换档指引
    Repository.taskTranscribeAudio =>
      '转写已结束，但没有识别出任何文本。常见原因：音频不是中文（请在「设置 → 语音转写模型」'
          '换到「全能 · 多语种」或「全球 · Whisper」）、模型未下载、音频无语音',
    Repository.taskOcrAndExtract => '识别已结束，但没有识别出文字：图片可能不含文字或过于模糊',
    _ => '处理已结束但未产出内容，可在「AI 任务队列」查看',
  };
}

/// AI 任务反馈条（2026-09-28）：转写 / OCR / 翻译都是**异步队列任务**，
/// 「已入队」之后页面不会有任何变化，用户无从判断是在跑、失败了、还是跑完没产出。
///
/// 尤其要处理「**完成但产出为空**」这一档——例如用中文模型转写英文音频：
/// Sherpa 返回空文本，管线按「占位不卡死」记为 `is_processed=1`（成功），
/// 详情页一片空白，看起来和失败一模一样。这里按任务动作给出**可执行的下一步**
/// （换多语种模型 / 图片太糊 / 引擎未就绪），把静默降级变成明示。
///
/// 有产出或没有相关任务时整行不占位（避免噪音）。
class _AiTaskStatusLine extends StatelessWidget {
  const _AiTaskStatusLine({required this.repo, required this.item});

  final Repository repo;
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final id = item.id;
    if (id == null) return const SizedBox.shrink();
    return FutureBuilder<List<Map<String, Object?>>>(
      future: repo.listTasks(), // 已按最新在前排好序
      builder: (context, snap) {
        final mine = (snap.data ?? const []).where((t) => t['item_id'] == id).toList();
        if (mine.isEmpty) return const SizedBox.shrink();
        final status = mine.first['status'] as String? ?? '';
        final action = mine.first['task_action'] as String? ?? '';
        final note = mine.first['last_note'] as String?;
        final text = aiTaskStatusText(status, action, aiTaskEmptyOutput(action, item), note: note);
        if (text.isEmpty) return const SizedBox.shrink();
        final running = status == 'pending' || status == 'processing';
        final failed = status == 'failed';
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(top: Insets.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                running ? Icons.hourglass_top : (failed ? Icons.error_outline : Icons.info_outline),
                size: 16,
                color: failed ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: failed ? scheme.error : scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({
    super.key,
    required this.repo,
    required this.handler,
    required this.item,
    required this.caps,
    this.vaultContext = false,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final InboxItem item;

  /// 翻译设置与引擎可用性（点「翻译」前的预检来源：不可用就明确告知，
  /// 不让用户对着一个必然无结果的任务干等）。
  final AiCapabilities caps;
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

  /// 翻译入口：**入队前先预检**——翻译是异步队列任务，若开关关闭或语言包未就绪
  /// 仍照常入队，用户只会看到「点了一下、什么都没发生」。这种情况直接告知原因
  /// 与去处（设置 → 翻译），不让用户干等一个必然无译文的任务。
  Future<void> _translate() async {
    final caps = widget.caps;
    if (!caps.translationEnabled) {
      _snack('翻译已关闭：设置 → 翻译 可开启');
      return;
    }
    caps.router?.reset(); // 语言包可能刚下载完，缓存结果作废后重判
    if (!await caps.checkTranslationAvailable()) {
      final reason = await caps.translationUnavailableReason();
      _snack('无法翻译：${reason ?? '无可用翻译引擎'}（设置 → 翻译 可下载语言包）');
      return;
    }
    await _run(
      () => widget.handler.execute(
        TranslateCommand(_item.id!),
        vaultContext: widget.vaultContext,
      ),
      '已入队翻译',
    );
  }

  /// 译文卡片：标注目标语言 + 一键复制。译文缺失时不占位（避免空卡片）。
  /// 端侧 LLM 摘要卡片（与译文卡片同构：独立产物，不覆盖原文，可一键复制）。
  Widget _summaryCard() {
    final scheme = Theme.of(context).colorScheme;
    final text = _item.summaryMd!.trim();
    return Card(
      margin: const EdgeInsets.only(top: Insets.md),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.summarize, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '摘要 · 端侧大模型',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: scheme.primary),
                  ),
                ),
                IconButton(
                  tooltip: '复制摘要',
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('摘要已复制')));
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(text, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _translationCard() {
    final scheme = Theme.of(context).colorScheme;
    final text = _item.translatedMd!.trim();
    return Card(
      margin: const EdgeInsets.only(top: Insets.md),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.translate, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '译文 · ${languageLabel(_item.translateLang ?? '')}',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: scheme.primary),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  tooltip: '复制译文',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    _snack('译文已复制');
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.share_outlined, size: 18),
                  tooltip: '导出译文文件',
                  onPressed: () async {
                    final lang = _item.translateLang ?? 'translation';
                    final path = await TranslationStore.save(_item.id!, lang, text);
                    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
                  },
                ),
              ],
            ),
            const SizedBox(height: Insets.sm),
            SelectableText(text),
          ],
        ),
      ),
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
          // 端侧 LLM 摘要与正文并列展示（不覆盖原文，翻译层同口径）
          if (_item.summaryMd != null && _item.summaryMd!.trim().isNotEmpty) _summaryCard(),
          // 译文与正文并列展示：译文是独立产物，不覆盖原文（翻译层硬口径）
          if (_item.hasTranslation) _translationCard(),
          _AiTaskStatusLine(repo: widget.repo, item: _item),
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
              // 翻译：正文非空才可翻译（图片 / 音视频需先 OCR / 转写出文本）。
              // 与 OCR / 转写同构——端侧动作一律手动 / 显式触发，摄入不自动跑。
              if (_item.bodyText.trim().isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _translate,
                  icon: const Icon(Icons.translate_outlined),
                  label: Text(_item.hasTranslation ? '重新翻译' : '翻译'),
                ),
              // 端侧 LLM 摘要 / 关键词（2026-09-28）：正文非空才可用，
              // 与翻译同构——显式手动触发，产物并列不覆盖原文。
              if (_item.bodyText.trim().isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.execute(
                      SummarizeCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
                    '已开始生成摘要',
                  ),
                  icon: const Icon(Icons.summarize_outlined),
                  label: Text((_item.summaryMd ?? '').trim().isNotEmpty ? '重新摘要' : '摘要'),
                ),
              if (_item.bodyText.trim().isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _run(
                    () => widget.handler.execute(
                      ExtractTagsCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
                    '已开始提取关键词',
                  ),
                  icon: const Icon(Icons.sell_outlined),
                  label: const Text('提取关键词'),
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
