import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../app/lifecycle_manager.dart';
import '../data/repository.dart';
import '../doc/attach.dart';
import '../models/draft_store.dart';
import '../models/item.dart';
import '../service/secure_window.dart';
import '../ui/content_card.dart';
import '../ui/clip_editor_sheet.dart';
import '../ui/draft_controller.dart';
import '../ui/item_view_template.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/rich_text_view.dart';
import '../ui/tokens.dart';
import '../ui/slogans.dart';

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
    Repository.taskClassifyImage =>
      '分类已结束，但没有识别出已知标签：图片可能过于抽象、非实体内容，或类别不在常用映射表内',
    Repository.taskScanBarcode =>
      '扫描已结束，但没有识别到条码 / 二维码：图片可能不含条码，或条码过于模糊、超出取景框',
    Repository.taskAnalyzeText =>
      '分析已结束，但没有提取到内容：笔记可能过短，或不含可识别的语言 / 实体',
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

  /// 机器态开关：由 AppBar `⋯` 菜单控制（双态入口保留但降权，不在正文流里常驻）。
  bool _machineMode = false;

  @override
  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    // 退后台时强制落盘正在编辑的草稿
    _lifecycleSub = AppLifecycleManager.instance.onBackgrounded.listen((_) => _editDraft?.flushAll());
    // Vault 敏感内容：开启 FLAG_SECURE 防截屏（离开时清除）。用 detail 维度计数，
    // 与保险箱 tab 维度互不干扰——叠在保险箱 tab 上也不会被本页 dispose 提前解除。
    if (widget.vaultContext) unawaited(SecureWindow.enterVaultDetail());
  }

  @override
  void dispose() {
    _lifecycleSub?.cancel();
    if (widget.vaultContext) unawaited(SecureWindow.exitVaultDetail());
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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${ContentCard.labelOf(_item.itemType)}详情'),
        // 低频 / 危险操作收进 `⋯` 菜单（ui-spec §4.3：不做按钮矩阵）
        actions: [_overflowMenu()],
      ),
      // Phase 1：主体改 CustomScrollView，正文 block 经 ItemViewTemplate.bodySlivers
      // 以 SliverList 虚拟化，数万字长文只构建可视区 widget。
      body: CustomScrollView(
        slivers: [
          const SliverPadding(
              padding: EdgeInsets.fromLTRB(Insets.xl, Insets.md, Insets.xl, 0)),
          ...ItemViewTemplate(item: _item, machineMode: _machineMode)
              .bodySlivers(context),
          // 类型专属处理动作：正文末尾一行 chips，不占正文主线
          SliverToBoxAdapter(child: _typeActions()),
          SliverToBoxAdapter(child: _attachStatusLine()),
          // 派生内容为正文末尾「附录章节」（小标题 + 内容），不叠卡片边框
          if (_item.summaryMd != null && _item.summaryMd!.trim().isNotEmpty)
            SliverToBoxAdapter(child: _appendix('摘要', _item.summaryMd!)),
          if (_item.hasTranslation)
            SliverToBoxAdapter(child: _appendix('译文', _item.translatedMd!)),
          SliverToBoxAdapter(
              child: _AiTaskStatusLine(repo: widget.repo, item: _item)),
          SliverToBoxAdapter(child: _sourceLine()),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          SliverToBoxAdapter(
            child: PoeticText(sloganFor(SloganKeys.detailFooter),
                large: false, align: TextAlign.center),
          ),
        ],
      ),
      // 基本操作条（5 项，全类型固定）：摘要 / 标签 / 工作区 / 分享 / 删除
      bottomNavigationBar: _actionBar(),
    );
  }

  /// 基本操作条：全类型固定的 5 项（ui-spec §4.3）。
  ///
  /// 摘要与标签是重操作，须带任务状态反馈（见 `_AiTaskStatusLine`），
  /// 且仅在有正文时可用——无正文跑模型必然空产出。
  Widget _actionBar() {
    final canProcess = _item.bodyText.trim().isNotEmpty;
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _barAction(
            icon: Icons.summarize_outlined,
            label: '摘要',
            enabled: canProcess,
            onPressed: () => _run(
              () => widget.handler.execute(
                SummarizeCommand(_item.id!),
                vaultContext: widget.vaultContext,
              ),
              '已开始生成摘要',
            ),
          ),
          _barAction(
            icon: Icons.sell_outlined,
            label: '标签',
            enabled: canProcess,
            onPressed: () => _run(
              () => widget.handler.execute(
                ExtractTagsCommand(_item.id!),
                vaultContext: widget.vaultContext,
              ),
              '已开始提取标签',
            ),
          ),
          _barAction(
            icon: Icons.workspaces_outlined,
            label: '工作区',
            onPressed: _workspaceHint,
          ),
          _barAction(
            icon: Icons.share_outlined,
            label: '分享',
            onPressed: _share,
          ),
          _barAction(
            icon: Icons.delete_outline,
            label: '删除',
            danger: true,
            onPressed: _confirmDelete,
          ),
        ],
      ),
    );
  }

  Widget _barAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool enabled = true,
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.onSurfaceVariant;
    final effective = enabled ? color : scheme.outline;
    return InkWell(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: effective),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: effective),
            ),
          ],
        ),
      ),
    );
  }

  /// `⋯` 菜单：低频 / 危险操作（编辑、机器态、重分类、保险箱、重新处理）。
  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      onSelected: _onMenu,
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: 'machine',
          checked: _machineMode,
          child: const Text('机器态'),
        ),
        const PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
        if (_item.editLocked)
          const PopupMenuItem<String>(value: 'unlock', child: Text('解除编辑')),
        if (_item.sourceType == InboxItem.typeImage &&
            _item.itemType == InboxItem.typeImage)
          const PopupMenuItem<String>(
              value: 'reclassify', child: Text('重分类')),
        const PopupMenuItem<String>(
            value: 'reprocess', child: Text('重新处理')),
        if (!_item.isVault)
          const PopupMenuItem<String>(
              value: 'vault_in', child: Text('移入保险箱'))
        else if (widget.vaultContext)
          const PopupMenuItem<String>(
              value: 'vault_out', child: Text('移出保险箱')),
      ],
    );
  }

  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'machine':
        setState(() => _machineMode = !_machineMode);
      case 'edit':
        await _edit();
      case 'unlock':
        await _run(
          () => widget.handler.execute(
            UnlockEditCommand(_item.id!),
            vaultContext: widget.vaultContext,
          ),
          '已解除编辑锁定',
        );
      case 'reclassify':
        await _reclassify();
      case 'reprocess':
        await _run(
          () => widget.handler.execute(
            ReprocessCommand(_item.id!),
            vaultContext: widget.vaultContext,
          ),
          '已入队重新处理',
        );
      case 'vault_in':
        await _run(
          () => widget.handler.execute(SetVaultCommand(_item.id!, true)),
          '已移入保险箱',
        );
      case 'vault_out':
        await _run(
          () => widget.handler.execute(
            SetVaultCommand(_item.id!, false),
            vaultContext: true,
          ),
          '已移出保险箱',
        );
    }
  }

  /// 类型专属处理动作：正文末尾一行 chips。
  ///
  /// 端侧 AI 动作一律**手动触发**（摄入不自动跑模型）；重资源动作不进基本操作条，
  /// 避免诱导误触。提取音轨 / 字幕导出在类型区内（与播放器一起），不在此重复。
  Widget _typeActions() {
    final chips = <Widget>[];
    void add(IconData icon, String label, VoidCallback onPressed) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: Insets.sm),
        child: ActionChip(
          avatar: Icon(icon, size: 16),
          label: Text(label),
          onPressed: onPressed,
        ),
      ));
    }

    final isMedia = _item.itemType == InboxItem.typeAudio ||
        _item.itemType == InboxItem.typeVideo;
    if (isMedia) {
      add(Icons.subtitles_outlined, '转写', () => _run(
            () => widget.handler.execute(
              TranscribeCommand(_item.id!),
              vaultContext: widget.vaultContext,
            ),
            '已入队转写',
          ));
    }
    if (_item.itemType == InboxItem.typeVideo) {
      add(Icons.content_cut, '切片', () => showClipEditorSheet(
            context,
            handler: widget.handler,
            item: _item,
            vaultContext: widget.vaultContext,
          ));
      add(
        _item.videoWholeMarked ? Icons.bookmark : Icons.bookmark_border,
        '整片',
        () => _run(
          () => widget.handler.execute(
            MarkWholeVideoCommand(_item.id!, marked: !_item.videoWholeMarked),
            vaultContext: widget.vaultContext,
          ),
          _item.videoWholeMarked
              ? '已取消整片标记'
              : '已标记整片：下次备份将携带此视频',
        ),
      );
    }
    if (_item.itemType == InboxItem.typeImage) {
      add(Icons.document_scanner_outlined, '识别文字', () => _run(
            () => widget.handler.execute(
              OcrCommand(_item.id!),
              vaultContext: widget.vaultContext,
            ),
            '已入队 OCR',
          ));
      add(Icons.auto_awesome_motion_outlined, '识别分类', () => _run(
            () => widget.handler.execute(
              ClassifyCommand(_item.id!),
              vaultContext: widget.vaultContext,
            ),
            '已入队分类',
          ));
      add(Icons.qr_code_scanner_outlined, '识别条码', () => _run(
            () => widget.handler.execute(
              ScanBarcodeCommand(_item.id!),
              vaultContext: widget.vaultContext,
            ),
            '已入队条码扫描',
          ));
    }
    if (_item.itemType == InboxItem.typeNote) {
      add(Icons.text_snippet_outlined, '分析文本', () => _run(
            () => widget.handler.execute(
              AnalyzeTextCommand(_item.id!),
              vaultContext: widget.vaultContext,
            ),
            '已开始分析文本',
          ));
    }
    if (_item.bodyText.trim().isNotEmpty) {
      add(
        Icons.translate_outlined,
        _item.hasTranslation ? '重新翻译' : '翻译',
        _translate,
      );
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: Wrap(children: chips),
    );
  }

  /// 附件引用状态（content-pipeline §7）：引用中 / 失效都**明示**，
  /// 不能只给一个破图图标了事（R1：降级与失效必须被用户感知）。
  ///
  /// 可达性是文件 stat IO，走异步且不进列表滚动路径（只在详情页查一次）。
  Widget _attachStatusLine() {
    if (!_item.hasAttachment) return const SizedBox.shrink();
    return FutureBuilder<bool>(
      future: Attach.reachable(_item),
      builder: (context, snap) {
        final reachable = snap.data ?? true;
        final state = Attach.resolveState(_item.attachState, reachable);
        final text = Attach.statusText(state);
        if (text == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(top: Insets.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                state == InboxItem.attachLost
                    ? Icons.broken_image_outlined
                    : Icons.link_off,
                size: 18,
                color: scheme.error,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 附录章节（派生内容）：小标题 + 内容，**不叠卡片边框**。
  Widget _appendix(String title, String body) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: Insets.xs),
          RichTextView(markdown: body, shrinkWrap: true),
        ],
      ),
    );
  }

  /// 末尾来源小字（把「从哪来、什么时候」说清楚）。
  Widget _sourceLine() {
    final parts = <String>[
      if (_item.sourceApp?.isNotEmpty ?? false) _item.sourceApp!,
      _fmtDate(_item.createdAt),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Text(
        parts.join(' · '),
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Future<void> _share() async {
    final text = _item.bodyText.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可分享的文本')),
      );
      return;
    }
    await SharePlus.instance.share(ShareParams(text: text));
  }

  Future<void> _workspaceHint() async {
    // 加入工作区：列出用户工作区 → 选一个 → AddToWorkspaceCommand。
    // Vault 条目由动作层在 add_to_workspace 时拒绝（同 list 口径），UI 不必预过滤。
    final ws = await widget.repo.listWorkspaces();
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('加入工作区'),
        children: [
          if (ws.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('还没有工作区，去「工作区」tab 新建一个'),
            ),
          for (final w in ws)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, w.id),
              child: Text(w.name),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await _run(
      () => widget.handler.execute(
        AddToWorkspaceCommand(chosen, _item.id!),
        vaultContext: widget.vaultContext,
      ),
      '已加入工作区',
    );
  }
}
