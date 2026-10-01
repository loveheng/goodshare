import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:share_plus/share_plus.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../ai/capability.dart';
import '../app/lifecycle_manager.dart';
import '../data/repository.dart';
import '../doc/attach.dart';
import '../models/draft_store.dart';
import '../models/item.dart';
import '../service/secure_window.dart';
import '../ui/content_card.dart';
import '../ui/annotation_editor_page.dart';
import '../ui/clip_editor_sheet.dart';
import '../ui/audio_playback_service.dart';
import '../ui/body_screenshot.dart';
import '../ui/block_capability_host.dart';
import '../ui/block_editor_dialog.dart';
import '../ui/block_text_page.dart';
import '../ui/draft_controller.dart';
import '../ui/item_view_template.dart';
import '../ui/pdf_export.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/rich_text_view.dart';
import '../ui/share_scope_sheet.dart';
import '../ui/tokens.dart';
import '../ui/slogans.dart';

/// 详情页：ItemViewTemplate 双态外壳 + 动作区。
/// 全部写操作经 ItemActionHandler（与 MCP 同一实现）；vaultContext=true 表示
/// 从保险箱页进入（可移出等 MCP 不可用的动作）。
/// 该任务是否「跑完了但什么都没产出」——转写/OCR 看正文，翻译看译文。
bool aiTaskEmptyOutput(String action, InboxItem item) =>
    Repository.isTranslateAction(action)
    ? !item.hasTranslation
    : item.bodyText.trim().isEmpty;

/// 反馈文案（纯函数，便于单测）：空串表示「无需提示」。
///
/// **管线给的原因优先**：`note` 是管线写下的真实原因（如「模型未下载」「语言与模型不匹配」），
/// 比按状态猜的兜底文案准确得多——错误描述必须具体到可行动，而不是「失败了」。
String aiTaskStatusText(
  String status,
  String action,
  bool empty, {
  String? note,
}) {
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
    Repository.taskScanBarcode => '扫描已结束，但没有识别到条码 / 二维码：图片可能不含条码，或条码过于模糊、超出取景框',
    Repository.taskAnalyzeText => '分析已结束，但没有提取到内容：笔记可能过短，或不含可识别的语言 / 实体',
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
/// 灵感区页签已废弃（detail-two-zone.md §3 拍板 2026-10-01：摘要/标签
/// 平行并置，不再互斥切换）。
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
        final mine = (snap.data ?? const [])
            .where((t) => t['item_id'] == id)
            .toList();
        if (mine.isEmpty) return const SizedBox.shrink();
        final status = mine.first['status'] as String? ?? '';
        final action = mine.first['task_action'] as String? ?? '';
        final note = mine.first['last_note'] as String?;
        final text = aiTaskStatusText(
          status,
          action,
          aiTaskEmptyOutput(action, item),
          note: note,
        );
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
                running
                    ? Icons.hourglass_top
                    : (failed ? Icons.error_outline : Icons.info_outline),
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

  /// 页面级音频播放控制器（rich-text-media.md §3 单实例红线）：唯一
  /// AudioPlayer 实例，行内 AudioBlock 与顶级音频区共用；离开页面即释放。
  final _audioPlayback = AudioPlaybackController();

  /// 机器态开关：由 AppBar `⋯` 菜单控制（双态入口保留但降权，不在正文流里常驻）。
  bool _machineMode = false;

  /// 灵感区 AI 产出区已改平行并置（见 _aiOutputSection），无页签状态。

  /// 灵感区文本编辑控制器（用户私密碎片，失焦即存——速记条同款语义）。
  final _inspirationCtrl = TextEditingController();

  /// 分享截图渲染边界（detail-two-zone.md §6：复用页面既有 RepaintBoundary）。
  final _bodyBoundaryKey = GlobalKey();

  /// 块锚点注册中心（detail-two-zone.md §5.1 二次改版）：文本块无常驻 ✨，
  /// 划词菜单按选区锚点反查命中块——本表是菜单与块之间唯一的几何桥梁。
  /// 生命周期=页面，宿主滑出视口即自行注销。
  final _blockAnchors = BlockAnchorStore();

  /// 底栏方向感知隐显（拍板 2026-10-01：下滑藏、上滑现、静止保持——
  /// 与首页顶栏 floating+snap 同属「读模式收 chrome、找模式亮 chrome」）。
  bool _actionBarVisible = true;

  @override
  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    // 退后台时强制落盘正在编辑的草稿
    _lifecycleSub = AppLifecycleManager.instance.onBackgrounded.listen(
      (_) => _editDraft?.flushAll(),
    );
    // Vault 敏感内容：开启 FLAG_SECURE 防截屏（离开时清除）。用 detail 维度计数，
    // 与保险箱 tab 维度互不干扰——叠在保险箱 tab 上也不会被本页 dispose 提前解除。
    if (widget.vaultContext) unawaited(SecureWindow.enterVaultDetail());
  }

  @override
  void dispose() {
    _lifecycleSub?.cancel();
    _audioPlayback.dispose();
    // 灵感区失焦即存，dispose 兜底最后一笔（速记条同款语义）
    _saveInspiration();
    _inspirationCtrl.dispose();
    if (widget.vaultContext) unawaited(SecureWindow.exitVaultDetail());
    super.dispose();
  }

  /// 灵感区落库：失焦即存，走 UpdateItemCommand（唯一写入口，R2）。
  Future<void> _saveInspiration() async {
    final text = _inspirationCtrl.text.trim();
    if (text == _item.inspirationMd?.trim()) return;
    try {
      await widget.handler.execute(
        UpdateItemCommand(id: _item.id!, inspirationMd: text),
        vaultContext: widget.vaultContext,
      );
    } on ActionException catch (e) {
      _snack(e.message);
    }
  }

  @override
  void reload() => _reload();

  Future<void> _reload() async {
    final fresh = await widget.repo.byId(_item.id!, includeDeleted: true);
    if (fresh == null) return;
    if (!mounted) return;
    setState(() {
      _item = fresh;
      // 灵感区控制器与最新快照同源：编辑中不覆盖（用户输入优先），
      // 空闲时回填（外部/AI 更新可见）
      if (_inspirationCtrl.text.trim().isEmpty ||
          _inspirationCtrl.text.trim() == (_item.inspirationMd ?? '').trim()) {
        _inspirationCtrl.text = _item.inspirationMd ?? '';
      }
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
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
    final title = DraftController(
      draftId: '$baseId:title',
      targetId: id,
      store: store,
      initialContent: _item.humanTitle ?? '',
    );
    final tldr = DraftController(
      draftId: '$baseId:tldr',
      targetId: id,
      store: store,
      initialContent: _item.humanTldr ?? '',
    );
    final body = DraftController(
      draftId: '$baseId:body',
      targetId: id,
      store: store,
      initialContent: _item.humanMd ?? _item.rawContent ?? '',
    );
    _editDraft = EditDraft(
      baseId: baseId,
      targetId: id,
      store: store,
      title: title,
      tldr: tldr,
      body: body,
    );
    await _editDraft!.loadAll(); // 优先恢复已落盘草稿
    if (!mounted) {
      _editDraft!.dispose();
      _editDraft = null;
      return;
    }

    // 批 B：正文编辑从 BottomSheet 源码 TextField 改为 fullscreen 结构化块编辑器
    // （SSOT：docs/design/rich-text-component.md §4）。标题/TL;DR 沿用草稿控制器。
    final originalBody = _editDraft!.body.text.text;
    final saved = await showBlockEditorDialog(
      context,
      title: '编辑',
      markdown: originalBody,
      titleField: _editDraft!.title.text,
      tldrField: _editDraft!.tldr.text,
      // 编辑态音频预览可播：透传页面级播放控制器（rich-text-media.md §4）
      audioPlayback: _audioPlayback,
      // 过程草稿同步：块变更即回写 body 草稿（退后台 flush 已由页面生命周期承担）
      onChanged: (md) => _editDraft!.body.text.text = md,
    );
    if (saved != true) {
      // 取消：还原正文草稿到打开前状态（过程草稿同步产生的变更作废）
      _editDraft!.body.text.text = originalBody;
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
            const Padding(
              padding: EdgeInsets.all(Insets.md),
              child: Text('重分类为（AI 未处理时的手动纠正）'),
            ),
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

  // ── 区块能力执行作用域（detail-two-zone.md §5.2 接线）：能力卡回调组装
  // 真命令（与 UI 按钮 / MCP 工具同源，R2），等待队列任务落定后抽取产出。

  /// 能力步 → 队列动作前缀（waitForTask 匹配用；translate 含 `:<lang>` 变体）。
  String? _capabilityActionOf(ContentCapability step) => switch (step.id) {
    'ocr' => Repository.taskOcrAndExtract,
    'transcribe' => Repository.taskTranscribeAudio,
    'translate' => Repository.taskTranslate,
    'summarize' => Repository.taskLlmSummarize,
    _ => null,
  };

  /// 执行链中一步：命令入队 → 等任务落定 → 从条目字段抽产出文本
  /// （OCR/转写写 human_md，翻译写 translated_md，摘要写 summary_md）。
  /// null = 无产出/失败，卡内按失败停步；真实原因仍由 `_AiTaskStatusLine`
  /// 与队列页同一份 note 承载（R1 同源，不在卡内另造文案）。
  Future<String?> _runCapabilityStep(ContentCapability step) async {
    final id = _item.id!;
    final action = _capabilityActionOf(step);
    if (action == null) return null;
    if (step is TranslateCapability) {
      // 入队前预检与页面级「翻译」同口径：必然无结果的任务不入队
      final caps = widget.caps;
      if (!caps.translationEnabled) {
        _snack('翻译已关闭：设置 → 翻译 可开启');
        return null;
      }
      caps.router?.reset(); // 语言包可能刚下载完，缓存结果作废后重判
      if (!await caps.checkTranslationAvailable()) {
        final reason = await caps.translationUnavailableReason();
        _snack('无法翻译：${reason ?? '无可用翻译引擎'}（设置 → 翻译 可下载语言包）');
        return null;
      }
    }
    try {
      await widget.handler.execute(
        step.command(id),
        vaultContext: widget.vaultContext,
      );
    } on ActionException catch (e) {
      _snack(e.message);
      return null;
    }
    if (!await _waitForTask(id, action)) return null;
    final fresh = await widget.repo.byId(id, includeDeleted: true);
    if (fresh == null) return null;
    return switch (step.id) {
      'ocr' || 'transcribe' => fresh.bodyText.trim().isEmpty
          ? null
          : fresh.bodyText,
      'translate' => fresh.hasTranslation ? fresh.translatedMd : null,
      'summarize' => () {
        final s = fresh.summaryMd?.trim() ?? '';
        return s.isEmpty ? null : s;
      }(),
      _ => null,
    };
  }

  /// 等待该条目指定动作的**最新**任务落定（listTasks 最新在前，首个匹配
  /// 行即本次触发）。消费者侧自带 20s/60s 超时与设备状态门控——门控挂起
  /// 或超 5 分钟未落定时按失败停步返回，真实进度在状态线 / 队列页可见。
  Future<bool> _waitForTask(String itemId, String actionPrefix) async {
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return false;
      final tasks = await widget.repo.listTasks(limit: 50);
      for (final t in tasks) {
        if (t['item_id'] != itemId) continue;
        final a = t['task_action'] as String?;
        final matched = actionPrefix == Repository.taskTranslate
            ? Repository.isTranslateAction(a)
            : a == actionPrefix;
        if (!matched) continue;
        final status = t['status'] as String? ?? '';
        if (status == 'pending' || status == 'processing') break;
        return status == 'completed';
      }
    }
    return false;
  }

  /// 产出回注（detail-two-zone.md §5.3 显式回注，不自动写回）：
  /// 追加为从属块（默认）/ 替换原块（仅文本块）/ 追加进灵感区。
  /// 均走 UpdateItemCommand（唯一写入口），成功后刷新页面快照。
  Future<void> _applyCapabilityOutput(ReinjectTarget target, String text) async {
    final id = _item.id!;
    final command = switch (target) {
      ReinjectTarget.append => UpdateItemCommand(
        id: id,
        humanMd: _item.bodyText.trim().isEmpty
            ? text
            : '${_item.bodyText}\n\n$text',
      ),
      ReinjectTarget.replace => UpdateItemCommand(id: id, humanMd: text),
      ReinjectTarget.inspiration => UpdateItemCommand(
        id: id,
        inspirationMd: (_item.inspirationMd?.trim().isEmpty ?? true)
            ? text
            : '${_item.inspirationMd}\n\n$text',
      ),
    };
    try {
      await widget.handler.execute(command, vaultContext: widget.vaultContext);
      await _reload();
    } on ActionException catch (e) {
      _snack(e.message);
    }
  }

  /// 独立能力分发（detail-two-zone.md §5.2 改版：类型专属功能全部拆入
  /// 三级能力页，二级页不再有内容能力 chips）：标注/分类/条码/分析入队
  /// 或打开编辑工具流，切片/整片为视频工具流。
  Future<void> _runStandaloneCapability(String capabilityId) async {
    final id = _item.id!;
    switch (capabilityId) {
      case 'annotate':
        await showAnnotationEditorPage(context, item: _item);
        await _reload();
      case 'classify':
        await _run(
          () => widget.handler.execute(
            ClassifyCommand(id),
            vaultContext: widget.vaultContext,
          ),
          '已入队分类',
        );
      case 'scan_barcode':
        await _run(
          () => widget.handler.execute(
            ScanBarcodeCommand(id),
            vaultContext: widget.vaultContext,
          ),
          '已入队条码扫描',
        );
      case 'analyze_text':
        await _run(
          () => widget.handler.execute(
            AnalyzeTextCommand(id),
            vaultContext: widget.vaultContext,
          ),
          '已开始分析文本',
        );
      case 'clip':
        await showClipEditorSheet(
          context,
          handler: widget.handler,
          item: _item,
          vaultContext: widget.vaultContext,
        );
        await _reload();
      case 'whole_mark':
        await _run(
          () => widget.handler.execute(
            MarkWholeVideoCommand(id, marked: !_item.videoWholeMarked),
            vaultContext: widget.vaultContext,
          ),
          _item.videoWholeMarked ? '已取消整片标记' : '已标记整片：下次备份将携带此视频',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 二级页无返回箭头（ui-spec §3）：出口=系统手势/返回键
        automaticallyImplyLeading: false,
        // 机器态入口对人类隐藏（2026-10-01 拍板：普通用户不进机器态，`⋯`
        // 菜单不再给开关）——长按标题切换，仅供开发 / 调试。**双态呈现能力
        // 保留**（ui-spec 硬规则：human_md / machine_json 必须可呈现）。
        title: GestureDetector(
          onLongPress: _toggleMachineMode,
          child: Text('${ContentCard.labelOf(_item.itemType)}详情'),
        ),
        // 低频 / 危险操作收进 `⋯` 菜单（ui-spec §4.3：不做按钮矩阵）
        actions: [_overflowMenu()],
      ),
      // Phase 1：主体改 CustomScrollView，正文 block 经 ItemViewTemplate.bodySlivers
      // 以 SliverList 虚拟化，数万字长文只构建可视区 widget。
      // 跨块文本选择：正文区统一包 SelectionArea（rich-text-component.md §3），
      // 块内为普通 Text，长按拖拽即可跨块复制。
      // 页面级音频播放服务作用域：行内 AudioBlock / 顶级音频区共用唯一播放器
      // RepaintBoundary：分享截图渲染边界（detail-two-zone.md §6 Theme 红线
      // ——复用页面既有边界，天然继承 Theme/MediaQuery，不重建离屏树）。
      body: AudioPlaybackService(
        controller: _audioPlayback,
        child: BlockCapabilityExecutor(
          onRunStep: _runCapabilityStep,
          onApply: _applyCapabilityOutput,
          onEditOutput: (raw) => showBlockTextPage(context, initialText: raw),
          onRunStandalone: _runStandaloneCapability,
          // MVP 接线口径（detail-two-zone.md §5.3 块附件通道落地前的过渡）：
          // 产出落条目级字段（正文/译文/摘要），链每次全新开始、Reset 仅归零
          // 卡内状态不清条目数据——无「已落库步」即无续跑死锁可解除。
          onReset: () async {},
          loadPersistedOutputs: () => const {},
          child: RepaintBoundary(
          key: _bodyBoundaryKey,
          child: BlockAnchorRegistry(
          store: _blockAnchors,
          child: SelectionArea(
          // 划词菜单 = 文本块唯一 AI 入口（§5.1 二次改版）：菜单项经
          // BlockAnchorStore 反查选区命中块。builder 给的 context 在
          // Overlay 里、取不到页面 InheritedWidget，故用页面 context。
          contextMenuBuilder: (_, state) => _selectionMenu(state),
          child: NotificationListener<UserScrollNotification>(
            onNotification: (n) {
              if (n.metrics.axis != Axis.vertical) return false;
              // 只在「滚动方向变化」时切状态，静止（idle）保持现状
              if (n.direction == ScrollDirection.reverse &&
                  _actionBarVisible) {
                setState(() => _actionBarVisible = false);
              } else if (n.direction == ScrollDirection.forward &&
                  !_actionBarVisible) {
                setState(() => _actionBarVisible = true);
              }
              return false;
            },
            child: CustomScrollView(
            slivers: [
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  Insets.xl,
                  Insets.md,
                  Insets.xl,
                  0,
                ),
              ),
              ...ItemViewTemplate(
                item: _item,
                machineMode: _machineMode,
              ).bodySlivers(context),
              SliverToBoxAdapter(child: _attachStatusLine()),
              // 灵感区（ui-spec §4.3 两区改版）：摘要/标签切换 + 刷新重生成
              SliverToBoxAdapter(child: _inspirationSection()),
              if (_item.hasTranslation)
                SliverToBoxAdapter(child: _appendix('译文', _item.translatedMd!)),
              SliverToBoxAdapter(
                child: _AiTaskStatusLine(repo: widget.repo, item: _item),
              ),
              SliverToBoxAdapter(child: _sourceLine()),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
              SliverToBoxAdapter(
                child: PoeticText(
                  sloganFor(SloganKeys.detailFooter),
                  large: false,
                  align: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
        ),
        ),
        ),
        ),
      ),
      // 公共操作条（两区改版）：工作区 / 分享 / 删除。方向感知隐显：
      // 下滑阅读收起（读模式收 chrome），上滑操作弹回（找模式亮 chrome），
      // 静止保持；键盘弹出（灵感区输入）时顺带隐藏——纯干扰。
      bottomNavigationBar: ClipRect(
        child: AnimatedAlign(
          alignment: Alignment.bottomCenter,
          heightFactor: _actionBarVisible && !_keyboardVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: _actionBar(),
        ),
      ),
    );
  }

  /// 划词菜单（detail-two-zone.md §5.1 二次改版 2026-10-01）：文本块撤销
  /// 常驻 ✨（入口密度 = 块密度，一行文本一个图标导致长文泛滥），改在系统
  /// 选字菜单里追加「AI 处理本段」项——入口随选区走，与长按选字不抢手势。
  ///
  /// 命中块由 [BlockAnchorStore.hitTest] 按菜单锚点反查；未命中（如选区落在
  /// 非能力区）就不追加，退回纯净的系统菜单。
  Widget _selectionMenu(SelectableRegionState state) =>
      buildBlockCapabilityMenu(context, state);

  /// 键盘是否可见（灵感区输入时底栏让位，避免遮挡与视觉挤压）。
  bool get _keyboardVisible => MediaQuery.of(context).viewInsets.bottom > 0;

  /// 公共操作条（ui-spec §4.3 两区改版 + 2026-10-01 重划）：全类型固定
  /// 3 项——**编辑 / 工作区 / 分享**。
  /// - 删除移入 `⋯` 菜单（危险操作不占底栏常驻位，且带二次确认）；
  /// - 分享 = 内容导出链（离屏截图 / PDF，按内容分流），**唯一分享路径**
  ///   （菜单里的纯文本直分享已移除，同一动作不设两个入口）；
  /// - 摘要与标签已移入灵感区（`_inspirationSection`），不再占底栏。
  ///
  /// Wrap 而非 Row：本机逻辑屏宽仅 331dp（1272px / DPR 3.84），Row 溢出在
  /// 调试态画黄黑斜纹警示条、release 直接裁切（2026-10-01 真机「斜黄条」）。
  /// 不用 OverflowBar——它放不下时是「每项各占一行」的竖排（AlertDialog
  /// 动作语义），不是换行；不用 BottomAppBar——它把子级高度钉死（实测
  /// h=56），两行必竖向溢出。
  Widget _actionBar() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceAround,
            runAlignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _barAction(
                icon: Icons.edit_outlined,
                label: '编辑',
                onPressed: _edit,
              ),
              _barAction(
                icon: Icons.workspaces_outlined,
                label: '工作区',
                onPressed: _workspaceHint,
              ),
              _barAction(
                icon: Icons.share_outlined,
                label: '分享',
                onPressed: _exportPdf,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底栏操作项（mymind 形态，ui-spec §4.3）：icon + label 横排、深色胶囊底。
  /// 删除已移入 `⋯` 菜单（红色文字 + 二次确认），底栏不再有 danger 形态。
  Widget _barAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = enabled ? scheme.onSurfaceVariant : scheme.outline;
    final bg = scheme.surfaceContainerHigh;
    return InkWell(
      onTap: enabled ? onPressed : null,
      customBorder: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: ShapeDecoration(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }

  /// 机器态开关（入口对人类隐藏，见 AppBar 标题长按）：双态呈现能力保留，
  /// 只是不给普通用户按钮（2026-10-01 拍板）。
  void _toggleMachineMode() => setState(() => _machineMode = !_machineMode);

  /// `⋯` 菜单：低频 / 危险操作（2026-10-01 重划）——解除编辑 / 重分类 /
  /// 重新处理 / 保险箱 + **删除**（末位红字，走二次确认）。
  ///
  /// 移出项：**编辑**与**分享**收敛到底栏唯一入口（同一动作不设两个入口）、
  /// **机器态**入口改为长按标题（人类不进机器态）。媒体原文件导出分享在
  /// 正文区的导出行（item_view_template），不受本菜单影响。
  Widget _overflowMenu() {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      onSelected: _onMenu,
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        if (_item.editLocked)
          const PopupMenuItem<String>(value: 'unlock', child: Text('解除编辑')),
        if (_item.sourceType == InboxItem.typeImage &&
            _item.itemType == InboxItem.typeImage)
          const PopupMenuItem<String>(value: 'reclassify', child: Text('重分类')),
        const PopupMenuItem<String>(value: 'reprocess', child: Text('重新处理')),
        if (!_item.isVault)
          const PopupMenuItem<String>(value: 'vault_in', child: Text('移入保险箱'))
        else if (widget.vaultContext)
          const PopupMenuItem<String>(value: 'vault_out', child: Text('移出保险箱')),
        // 删除：危险项置末位 + 红字（底栏不再常驻删除，误触成本归零）。
        PopupMenuItem<String>(
          value: 'delete',
          child: Text('删除', style: TextStyle(color: scheme.error)),
        ),
      ],
    );
  }

  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'delete':
        await _confirmDelete();
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

  /// 分享（detail-two-zone.md §6 分流）：预览 Sheet 勾选产物内容（灵感区
  /// 默认关）→ 无音视频走离屏截图 PNG（超 8000px 降级 PDF）→ 含音视频
  /// 走 PDF。失败给可行动提示（R1）。
  Future<void> _exportPdf() async {
    if (_item.bodyText.trim().isEmpty) {
      _snack('没有可分享的文本内容');
      return;
    }
    final scope = await showShareScopeSheet(context);
    if (!mounted || scope == null) return;
    _snack('正在准备分享内容…');
    try {
      String? path;
      final hasMedia = _item.itemType == InboxItem.typeAudio ||
          _item.itemType == InboxItem.typeVideo;
      if (!hasMedia) {
        try {
          // 复用页面既有 RepaintBoundary（Theme 红线）；超长降级 PDF
          path = await BodyScreenshotRenderer.renderToFile(_bodyBoundaryKey);
        } on TooTallException {
          path = null;
        }
      }
      path ??= await ItemPdfExporter.export(_item);
      if (!mounted) return;
      if (path == null) {
        _snack('分享失败：未生成文件，请重试');
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      if (mounted) _snack('分享失败：$e');
    }
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
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// AI 产出区 + 灵感区（detail-two-zone.md §3 重新定义后拆分）：
  /// 摘要/标签切换器（机器产出，只读+刷新）与灵感区（人的碎片想法，
  /// 可编辑文本、失焦即存）分家——两者交互模式不同，不混一个组件。
  Widget _inspirationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _aiOutputSection(),
        _inspirationTextArea(),
      ],
    );
  }

  /// AI 产出区（detail-two-zone.md §3 拍板 2026-10-01）：摘要/标签**平行
  /// 并置**不再页签互斥——两者形态互补（几行文字 + 一行胶囊），叠放总高
  /// 很低，扫一眼全有，切换成本归零。标签支持手动增删（用户权威，AI 提取
  /// 只是代劳）；各自独立刷新。
  Widget _aiOutputSection() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = _item.summaryMd?.trim() ?? '';
    final hasSummary = summary.isNotEmpty;
    final hasTags = _item.tags.isNotEmpty;
    final canProcess = _item.bodyText.trim().isNotEmpty;

    Widget sectionHeader(String label, String refreshTooltip, VoidCallback? onRefresh, {VoidCallback? onAdd}) {
      return Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (onAdd != null)
            IconButton(
              tooltip: '手动添加标签',
              icon: Icon(Icons.add, size: 18, color: scheme.onSurfaceVariant),
              onPressed: onAdd,
            ),
          IconButton(
            tooltip: refreshTooltip,
            icon: Icon(
              Icons.refresh,
              size: 18,
              color: canProcess ? scheme.onSurfaceVariant : scheme.outline,
            ),
            onPressed: onRefresh,
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 摘要（AI 产出，可刷新重生成）
          sectionHeader(
            '摘要',
            '重新生成摘要',
            canProcess
                ? () => _run(
                    () => widget.handler.execute(
                      SummarizeCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
                    '已开始生成摘要',
                  )
                : null,
          ),
          const SizedBox(height: Insets.xs),
          if (hasSummary)
            RichTextView(markdown: summary, shrinkWrap: true)
          else
            _inspirationEmpty('还没有摘要，点右上刷新生成'),
          const SizedBox(height: Insets.lg),
          // ── 标签（AI 提取 + 手动增删；AI 刷新按并集合并不冲掉手动标签）
          sectionHeader(
            '标签',
            '重新提取标签（只增不删）',
            canProcess
                ? () => _run(
                    () => widget.handler.execute(
                      ExtractTagsCommand(_item.id!),
                      vaultContext: widget.vaultContext,
                    ),
                    '已开始提取标签',
                  )
                : null,
            onAdd: _editTags,
          ),
          const SizedBox(height: Insets.xs),
          if (hasTags)
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final t in _item.tags) Chip(label: Text(t)),
              ],
            )
          else
            _inspirationEmpty('还没有标签：点右上刷新由 AI 提取，或点 + 手动添加'),
        ],
      ),
    );
  }

  /// 标签手动编辑（detail-two-zone.md §3 拍板 2026-10-01）：BottomSheet
  /// chips 编辑器，增删自由；保存走 UpdateItemCommand 整表替换（=用户
  /// 权威快照，空表保存即清空）；AI 刷新另走并集合并互不冲突。
  Future<void> _editTags() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TagEditorSheet(initial: _item.tags),
    );
    if (result == null) return;
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, tags: result),
        vaultContext: widget.vaultContext,
      ),
      '标签已保存',
    );
  }

  /// 灵感区：人的碎片想法，可编辑文本区（点即聚焦、失焦即存）。
  Widget _inspirationTextArea() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '灵感',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          TextField(
            controller: _inspirationCtrl,
            minLines: 2,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: '写下你的灵感…',
              filled: true,
              fillColor: scheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md),
                borderSide: BorderSide.none,
              ),
            ),
            style: theme.textTheme.bodyMedium,
            onTapOutside: (_) => _saveInspiration(),
          ),
        ],
      ),
    );
  }

  Widget _inspirationEmpty(String text) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
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
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xs),
          RichTextView(markdown: body, shrinkWrap: true),
        ],
      ),
    );
  }

  /// 末尾来源小字（把「从哪来、什么时候」说清楚）。
  /// mymind 形态（ui-spec §4.3）：居中、更弱化（outline 色，仅存档感）。
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
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
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

/// 标签编辑 Sheet（手动增删，detail-two-zone.md §3 拍板 2026-10-01）：
/// InputChip 删 + 输入即加（去重去空）；「保存」回传最终清单由调用方
/// 走 UpdateItemCommand 整表替换，取消不动数据。
class _TagEditorSheet extends StatefulWidget {
  const _TagEditorSheet({required this.initial});

  final List<String> initial;

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late final List<String> _tags = [...widget.initial];
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _add() {
    final t = _ctrl.text.trim();
    if (t.isEmpty || _tags.contains(t)) {
      _ctrl.clear();
      return;
    }
    setState(() {
      _tags.add(t);
      _ctrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: Insets.lg,
        right: Insets.lg,
        top: Insets.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + Insets.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('编辑标签', style: theme.textTheme.titleMedium),
          const SizedBox(height: Insets.md),
          if (_tags.isNotEmpty)
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final t in _tags)
                  InputChip(
                    label: Text(t),
                    onDeleted: () => setState(() => _tags.remove(t)),
                  ),
              ],
            )
          else
            Text(
              '暂无标签，输入添加',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          const SizedBox(height: Insets.md),
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '输入标签，回车添加',
              filled: true,
              fillColor: scheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: Insets.sm),
              FilledButton(
                onPressed: () => Navigator.pop(context, _tags),
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
