import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../app/lifecycle_manager.dart';
import '../ai/video_clips.dart' show parseClipsJson;
import '../ai/capabilities.dart';
import '../ai/capability.dart';
import '../ai/translation.dart' show detectSourceLanguage, languageLabel;
import '../ai/subtitle.dart'
    show AsrCue, SubtitleStore, parseSrtVtt, usableCues;
import '../ai/workflow.dart' show WorkflowStep;

import '../data/block_artifacts.dart'
    show BlockArtifactInput, BlockArtifactKind, BlockArtifactMeta;
import '../data/repository.dart';
import '../doc/attach.dart';
import 'package:rich_text/markdown_subset.dart';
import '../ui/confirm_dialog.dart';
import '../ui/toast.dart';
import '../ui/overflow_sheet.dart';
import '../ui/tag_editor_sheet.dart';

import '../models/item.dart';
import '../media/block_media.dart';
import '../models/annotation.dart';
import '../models/template.dart';
import '../service/host_launch_channel.dart';
import '../service/settings_store.dart';
import '../ui/actions/item_actions.dart';
import '../ui/ai_diff.dart';
import '../ui/ai_revision_sheet.dart';
import '../ui/ai_session.dart';
import '../ui/annotation_editor_page.dart';
import '../ui/audio_record_sheet.dart';
import '../ui/clip_editor_sheet.dart';
import '../ui/audio_playback_service.dart';
import '../ui/body_screenshot.dart';
import '../ui/block_capability_host.dart';
import '../ui/media_blocks.dart' show SubtitleScope, showInlineVideoPlayer;
import '../ui/machine_view_page.dart';
import '../ui/workflow_track.dart' show BlockArtifactsView;

import '../ui/block_text_page.dart';

import '../ui/item_view_template.dart';
import '../ui/content_body.dart' show TodoInteractionScope;
import '../ui/pdf_export.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/section_legend.dart';
import '../ui/rich_text_view.dart';
import '../ui/share_scope_sheet.dart';
import '../ui/tokens.dart';
import 'task_queue_page.dart';

import 'template_preview_page.dart';

import 'package:file_picker/file_picker.dart';

import '../share/attachments.dart';
import '../share/note_composer.dart';
import '../ui/note_composer_editor.dart';
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
    // 模板任务明示「原文不会被修改」（ai-template.md §5 规约 4：等待期就给确定感）
    if (action.startsWith('${Repository.taskTemplateApply}:')) {
      return '模板处理中… 交由 AI 按模板生成，完成后自动出现在下方（原文不会被修改）';
    }
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
    // 任务级覆盖变体（transcribe_audio:<mode>:<lang>，MCP transcribe_item）与裸动作同文案
    _ when action.startsWith('${Repository.taskTranscribeAudio}:') =>
      '转写已结束，但没有识别出任何文本。常见原因：音频不是中文（请在「设置 → 语音转写模型」'
          '换到「全能 · 多语种」或「全球 · Whisper」）、模型未下载、音频无语音',
    // 模板任务完成但无产出（ai-template.md §5 规约 4）：给可行动下一步
    _ when action.startsWith('${Repository.taskTemplateApply}:') =>
      '模板处理已结束但没有产出：可重新「按模板处理」，或换个模板试试',
    _ => '处理已结束但未产出内容，可在「AI 任务队列」查看',
  };
}

/// 队列任务动作 → 人类可读名（任务队列页 / 待办条共用，ai-template.md §5 规约 4：
/// 不把 `template_apply:<uuid>` 裸串丢给用户）。未知动作原样返回（不造词）。
String aiTaskActionLabel(String? action) {
  final a = action;
  if (a == null || a.isEmpty) return '处理';
  if (a.startsWith('${Repository.taskTemplateApply}:')) return '模板处理';
  if (Repository.isTranscribeAction(a)) return '转写';
  if (a.startsWith(Repository.taskClipPrefix)) return '视频切片';
  return switch (a) {
    Repository.taskOcrAndExtract => '识别文字',
    Repository.taskClassifyImage => '识别分类',
    Repository.taskScanBarcode => '识别条码',
    Repository.taskAnalyzeText => '分析文本',
    Repository.taskTranslate => '翻译',
    Repository.taskLlmSummarize => '摘要',
    Repository.taskLlmTags => '提取关键词',
    Repository.taskExtractPalette => '主色提取',
    Repository.taskNormalizeDocument => '文档归一化',
    _ when a.startsWith('${Repository.taskTranslate}:') => '翻译',
    _ when a.startsWith('block_') => '块能力',
    _ => a,
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
/// §3.12.3 形态 B 徽标：远程任务 pending 久未被宿主认领时**替换无意义的 spinner**。
///
/// 灰底小胶囊 + 「等待 Goodhub 启动」，整枚可点 → 一键唤醒宿主（[_WaitingHostBadge.onTap]）。
/// DB 维持 `pending` 不变——本徽标是纯 UI 展示态，不引入 WAITING_HOST 存储态；
/// 宿主被唤起后任务转 processing，判据自然失效、徽标消失。
class _WaitingHostBadge extends StatelessWidget {
  const _WaitingHostBadge({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_empty, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: Insets.xs),
            Text(
              '等待 Goodhub 启动',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

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
        // P0-2（detail-page-visual-audit.md §6）：进行中不再走全局条——
        // 进度由卡内 spinner（摘要/标签/模板卡）+ AppBar 下 2dp 线性进度承接；
        // 本行只承载**终态**（失败/暂停/取消/完成但无产出的原因，R1 可观测）。
        if (status == 'pending' || status == 'processing') {
          return const SizedBox.shrink();
        }
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
  StreamSubscription<AppLifecycleState>? _lifecycleSub;

  /// 模板 id → 名称（ai-template.md §5 呈现规约 4：模板产出卡显示所用模板名）。
  /// 异步加载、失败静默（无模板时产出卡不显示名字，不挡页面）。
  Map<String, String> _templateNames = const {};

  /// 本条目 active（pending/processing）任务动作集（P0-2 卡内微观态 +
  /// 顶栏微进度，detail-page-visual-audit.md §6：摘要/标签/模板卡在对应任务
  /// 进行中时卡内转 spinner；任一 active 任务存在时 AppBar 下 2dp 线性进度
  /// 长文任意滚动位置恒可见）。刷新时机：入队/落库后 [_reload] 与 repo 通知。
  Set<String> _activeActions = const {};

  /// §3.12.3 形态 B 阈值：pending 持续超过该时长仍未被宿主认领 → UI 升级为
  /// 可操作徽标「等待 Goodhub 启动」（替换无意义 spinner）。
  ///
  /// **判据用时间阈值而非通道探测**（契约原话）：一次覆盖「通知丢失 / 宿主启动中
  /// / 宿主崩溃 / 通道瞬断」四类成因，且服务端零状态可维护。**红线**：DB 维持
  /// `pending` 不变，WAITING_HOST 只是 UI 展示态，不引入存储态。
  static const Duration _hostWaitThreshold = Duration(seconds: 10);

  /// 远程任务 pending 的入队时刻（task_action → `updated_at` 毫秒）。
  ///
  /// 仅收 [Repository.isRemoteTaskAction] 为真的任务——本地任务（OCR/转写/翻译）
  /// 由本地 QueueConsumer 消费，挂「等待宿主」是错的。pending 且未被认领时
  /// `updated_at` 恒等于入队时刻，故可直接据此算「已等时长」而不新增任何存储态。
  Map<String, int> _pendingSince = const {};

  /// 跨阈值那一刻翻转 UI 的单次定时器（**非轮询**：只在刚好到点时醒一次）。
  Timer? _hostWaitTimer;

  // ── T2：即时摘要（详情页即时入口，todos T2）。
  // 底层复用 SummarizeCommand 异步管线（非流式）；真·采样流式路径等 goodhub
  // Binder 接好再做（ai-app-split.md §3.11）。UX 三态：加载骨架 → 预览卡
  //（采用/忽略 + 时效标注）→ 失败/无变化降级（转后台处理链接）。
  bool _instantRunning = false;
  String? _instantPreview; // 已落库、待采用/忽略的新摘要
  DateTime? _instantTs; // 生成时间戳（时效标注）
  String? _instantPrevSummary; // 忽略时回滚基准
  bool _instantFailed = false;
  bool _instantNoChange = false;
  int _instantLoadingStep = 0;
  Timer? _instantTimer;
  static const List<String> _kInstantLoadingTexts = [
    '正在生成摘要…',
    '大模型推理中…',
    '马上就好…',
  ];

  /// AI 写回会话状态机（ai-writeback-revert §4/§5）：悬浮条显隐、还原 /
  /// 恢复 AI 改动、以及「用户手改即接管」的 settle 判定都归它。
  /// 读态也持有——AI 写完回后用户打开详情页就应看到待决提示。
  AiSessionController? _aiSession;

  /// 变更概览文案缓存（diff 有代价，按「基线+当前」对缓存，文本不变不重算）。
  String _aiSummary = '';
  String? _aiSummaryKey;

  /// 页面级音频播放控制器（rich-text-media.md §3 单实例红线）：唯一
  /// AudioPlayer 实例，行内 AudioBlock 与顶级音频区共用；离开页面即释放。
  final _audioPlayback = AudioPlaybackController();

  /// 机器态入口开关（设置页，默认关闭，2026-10-02 拍板）：关闭时 `⋯` 面板
  /// 不出现「机器态」项——普通人无入口；P1-5 降级后入口直达二级页
  /// `MachineViewPage`（不再切换读态正文）。
  bool _machineModeEnabled = false;

  /// 灵感区 AI 产出区已改平行并置（见 _aiOutputSection），无页签状态。
  /// 灵感输入已迁移 BottomSheet（P1-6 修订拍板），页内不再持有编辑控制器。

  /// 分享截图渲染边界（detail-two-zone.md §6：复用页面既有 RepaintBoundary）。
  final _bodyBoundaryKey = GlobalKey();

  /// 分享截图分段滚动驱动器（body_screenshot.dart 分段拼接）：滚动视图
  /// 常态无控制器，截图窗口内动态挂上驱动逐屏滚动，截完即移除。
  final _shareScrollCtrl = ScrollController();

  /// 分享截图的范围裁剪（share_scope_sheet 勾选，2026-10-05 接通）：
  /// RepaintBoundary 包住整页滚动视图，勾选过滤只能靠「渲染前改版式」——
  /// 截图前置本字段 → build 按勾选收起不分享的分区 → 截完即还原（null）。
  /// 非 null 仅存在于 _exportPdf 截图窗口内，常态交互不受影响。
  ShareScope? _shareScope;

  /// 块锚点注册中心（detail-two-zone.md §5.1 二次改版）：文本块无常驻 ✨，
  /// 划词菜单按选区锚点反查命中块——本表是菜单与块之间唯一的几何桥梁。
  /// 生命周期=页面，宿主滑出视口即自行注销。
  final _blockAnchors = BlockAnchorStore();

  /// 底栏方向感知隐显（拍板 2026-10-01：下滑藏、上滑现、静止保持——
  /// 与首页顶栏 floating+snap 同属「读模式收 chrome、找模式亮 chrome」）。
  bool _actionBarVisible = true;

  /// 标题原地编辑态（长按标题进入，不弹框，2026-10-02 拍板）：标题位置直接变
  /// TextField，回车 / 失焦即存，仅 patch `human_title`。
  bool _editingTitle = false;
  final TextEditingController _titleCtrl = TextEditingController();

  /// 页面编辑态（2026-10-02 拍板：**读态为主，可切编辑**）。
  /// 读态保留沉浸阅读（下滑藏底栏、键盘弹起让位）；编辑态开放就地编辑，
  /// 底栏**常驻**（否则打字时「保存」被键盘藏掉，就地编辑根本不可用）。
  bool _editing = false;

  /// 统一作曲编辑器（2026-10-03 编辑器统一拍板「详情编辑与新增页一模一样」）：
  /// 编辑态正文载体，保存经它取段序列。
  final GlobalKey<NoteComposerEditorState> _composerKey = GlobalKey();

  /// 编辑态初始草稿行：进入编辑时由 `human_md` 一次转换（noteMdToDraftRows），
  /// 编辑器内部自管段序列；退出/提交后置 null。
  List<List<String>>? _editRows;

  final FocusNode _titleFocus = FocusNode();

  @override
  Repository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      // 失焦即存（点外部 / 键盘收起 / 系统返回）：提交时应已先行退出编辑态，
      // 靠 _editingTitle 守卫防重复落库；mounted 防 dispose 后误触发。
      if (!_titleFocus.hasFocus && _editingTitle && mounted) _commitTitleEdit();
    });
    getMachineModeEnabled().then((v) {
      if (mounted) setState(() => _machineModeEnabled = v);
    });
    // 卡内微观态 + 顶栏微进度的初始态（打开页面即有进行中任务时 spinner 立现）
    unawaited(_loadActiveActions());
    // 模板名映射（模板产出卡展示用）；加载失败不挡页面（规约 4 的显示降级）。
    widget.repo.listTemplates().then((list) {
      if (!mounted) return;
      setState(() =>
          _templateNames = {for (final t in list) t.id: t.name});
    });
    // §8.3：切后台（App 被杀/退后台）必须强制 flush settle，否则状态/文本
    // mismatch——DB 停在旧会话态，重开时文本已是手改版却仍挂悬浮条。
    // 退后台一律订阅 AppLifecycleManager（arch-guard R6：不得裸用
    // WidgetsBindingObserver），与队列/草稿同一生命周期枢纽。
    _lifecycleSub = AppLifecycleManager.instance.onBackgrounded.listen((_) {
      unawaited(_aiSession?.flush() ?? Future<void>.value());
    });
    _aiSession = AiSessionController(
      itemId: widget.item.id ?? '',
      readItem: () => widget.repo.byId(_item.id!, includeDeleted: true, includeVault: true),
      readLatestAi: () => widget.repo.latestAiRevision(_item.id!),
      apply: (cmd) => widget.handler.execute(cmd, vaultContext: widget.vaultContext),
      readText: _currentBodyText,
    )..onTakeover = _onAiTakeover;
    _aiSession!.sync(_item);
  }

  @override
  void deactivate() {
    // 路由离开（返回键 / 侧滑）：在编辑器与状态机被回收前落定（§8.3）。
    unawaited(_aiSession?.flush() ?? Future<void>.value());
    super.deactivate();
  }

  @override
  void dispose() {
    _lifecycleSub?.cancel();
    _instantTimer?.cancel();
    _hostWaitTimer?.cancel();
    // §8.3：dispose 是最后一道 flush 点——先 flush 完再 dispose 控制器
    // （反过来会把 _disposed 置真，令 flush 的落库回调整体空转）。
    final ai = _aiSession;
    if (ai != null) unawaited(ai.flush().whenComplete(ai.dispose));
    _audioPlayback.dispose();
    // 灵感输入已迁 BottomSheet（P1-6）：浮层自带控制器生命周期，页内无兜底笔
    _titleCtrl.dispose();
    _titleFocus.dispose();
    _shareScrollCtrl.dispose();
    super.dispose();
  }

  /// 灵感区落库已收口到 [_showInspirationSheet]（BottomSheet 保存 → _run 统一
  /// 出口：execute + 触感 + toast + reload；未改动跳过不空耗乐观锁版本）。

  @override
  void reload() => _reload();

  Future<void> _reload() async {
    final fresh = await widget.repo.byId(_item.id!, includeDeleted: true, includeVault: true);
    if (fresh == null) return;
    await _loadActiveActions();
    if (!mounted) return;
    setState(() {
      _item = fresh;
    });
    // 会话态与最新快照同源（AI 可能在页面打开期间又写回了一次）。
    _aiSession?.sync(_item);
  }

  void _snack(String message, {ToastKind kind = ToastKind.info, Widget? action}) {
    ToastManager.show(message, kind: kind, action: action);
  }

  Future<void> _run(Future<Object?> Function() action, String? done) async {
    try {
      final res = await action();
      // 成功落库触感（§6.0 触感映射：medium=成功落库）
      HapticFeedback.mediumImpact();
      // 命令层可能回更具体的提示（如「已放入任务列表，前面还有 N 条」），优先展示；
      // done=null = 静默成功（勾选等控件状态即反馈的场景，弹提示反成噪音）
      if (done != null) {
        _snack(res is CommandResult ? (res.note ?? done) : done);
      }
      await _reload();
    } on ActionException catch (e) {
      _snack(e.message);
    }
  }

  // ── T2 即时摘要（todos T2）：复用 SummarizeCommand 异步管线（非流式），
  // 真·采样流式路径等 goodhub Binder 接好再做。UX：inline 骨架加载（含
  // 转后台处理链接 + 文案轮转）→ 预览卡（采用/忽略 + 时效标注）→ 失败/无变化降级。
  Future<void> _runInstantSummary() async {
    if (_instantRunning || !mounted) return;
    final prev = _item.summaryMd?.trim() ?? '';
    setState(() {
      _instantRunning = true;
      _instantPreview = null;
      _instantFailed = false;
      _instantNoChange = false;
      _instantLoadingStep = 0;
      _instantPrevSummary = prev;
    });
    _startInstantLoadingText();
    try {
      await widget.handler.execute(
        SummarizeCommand(_item.id!),
        vaultContext: widget.vaultContext,
      );
      final ok = await _waitForTask(_item.id!, Repository.taskLlmSummarize);
      await _reload();
      final generated = _item.summaryMd?.trim();
      if (!ok || generated == null || generated.isEmpty) {
        _instantFailed = true;
      } else if (generated == prev) {
        _instantNoChange = true;
      } else {
        _instantPreview = generated;
        _instantTs = DateTime.now();
        _snack('已生成摘要，可一键采用或忽略');
      }
    } on ActionException catch (e) {
      _snack(e.message);
      _instantFailed = true;
    } finally {
      _instantTimer?.cancel();
      _instantTimer = null;
      if (mounted) setState(() => _instantRunning = false);
    }
  }

  void _startInstantLoadingText() {
    _instantLoadingStep = 0;
    _instantTimer?.cancel();
    _instantTimer = Timer.periodic(const Duration(seconds: 3), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_instantLoadingStep < _kInstantLoadingTexts.length - 1) {
        setState(() => _instantLoadingStep++);
      } else {
        t.cancel();
      }
    });
  }

  /// 采用：新摘要已落库，仅收起预览卡（summary_md 即最终结果）。
  void _instantAccept() => setState(() => _instantPreview = null);

  /// 忽略：回滚到生成前的摘要（空 = 清空本次新增）。走 UpdateItemCommand 摘要回写通道。
  Future<void> _instantRevert() async {
    final prev = _instantPrevSummary ?? '';
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, summaryMd: prev),
        vaultContext: widget.vaultContext,
      ),
      prev.isEmpty ? '已忽略新摘要' : '已回滚到原摘要',
    );
    if (mounted) setState(() => _instantPreview = null);
  }

  void _openQueue() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TaskQueuePage(repo: widget.repo)),
    );
  }

  String _formatInstantTs(DateTime ts) {
    final h = ts.hour.toString().padLeft(2, '0');
    final m = ts.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildInstantLoading() {
    final scheme = Theme.of(context).colorScheme;
    final w = MediaQuery.of(context).size.width;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: Insets.sm),
          for (var i = 0; i < 6; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              height: 10,
              width: (i == 5 ? 0.5 : [0.9, 0.7, 0.95, 0.6, 0.8][i % 5]) * w,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          const SizedBox(height: Insets.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  _kInstantLoadingTexts[_instantLoadingStep],
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              TextButton(onPressed: _openQueue, child: const Text('转后台处理')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInstantPreview() {
    final scheme = Theme.of(context).colorScheme;
    final ts = _instantTs;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(Insets.sm),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outline),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichTextView(markdown: _instantPreview!, shrinkWrap: true),
                if (ts != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.xs),
                    child: Text(
                      '生成于 ${_formatInstantTs(ts)}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Insets.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _instantRevert, child: const Text('忽略')),
              const SizedBox(width: Insets.sm),
              FilledButton(onPressed: _instantAccept, child: const Text('采用')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInstantResultNote() {
    final scheme = Theme.of(context).colorScheme;
    final msg = _instantNoChange
        ? '摘要无变化（可能内容过短或模型无新产出）'
        : '摘要生成失败，可转后台查看或重试';
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              msg,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: _openQueue, child: const Text('转后台处理')),
          if (!_instantNoChange)
            TextButton(onPressed: _runInstantSummary, child: const Text('重试')),
        ],
      ),
    );
  }

  /// 摘要卡正文：T2 即时三态优先，否则回落既有展示（深度摘要 / 摄入期 TLDR / 空态）。
  Widget _summaryInstantBody(String summary, String tldrFallback, bool hasSummary) {
    if (_instantRunning) return _buildInstantLoading();
    if (_instantFailed || _instantNoChange) return _buildInstantResultNote();
    if (_instantPreview != null) return _buildInstantPreview();
    if (hasSummary) return RichTextView(markdown: summary, shrinkWrap: true);
    if (tldrFallback.isNotEmpty) {
      // 摄入期粗导语兜底：深度摘要生成后自动被其覆盖（P0-3 折叠规则）
      return RichTextView(markdown: tldrFallback, shrinkWrap: true);
    }
    return _inspirationEmpty('还没有摘要，点右上刷新生成');
  }

  /// 加载本条目 active 任务动作集（[_activeActions]）。任务状态变化不经
  /// repo 广播（仅条目写广播），故挂在 [_reload]（入队/落库/外部回写都会走）
  /// 与 initState 两口刷新——与 `_AiTaskStatusLine` 的 FutureBuilder 同源数据。
  Future<void> _loadActiveActions() async {
    final tasks = await widget.repo.listTasks();
    if (!mounted) return;
    final active = <String>{
      for (final t in tasks)
        if (t['item_id'] == _item.id &&
            (t['status'] == 'pending' || t['status'] == 'processing'))
          (t['task_action'] as String?) ?? '',
    }..remove('');
    // 形态 B 数据源：本条目「远程 + pending」任务的入队时刻（见 [_pendingSince]）。
    final since = <String, int>{
      for (final t in tasks)
        if (t['item_id'] == _item.id &&
            t['status'] == 'pending' &&
            Repository.isRemoteTaskAction(t['task_action'] as String?))
          (t['task_action'] as String): (t['updated_at'] as int?) ?? 0,
    };
    setState(() {
      _activeActions = active;
      _pendingSince = since;
    });
    _scheduleHostWaitFlip(since);
  }

  /// 卡内微观态判定（P0-2）：各卡对应任务是否进行中。
  bool get _summarizeRunning => _activeActions.contains(Repository.taskLlmSummarize);
  bool get _tagsRunning => _activeActions.contains(Repository.taskLlmTags);
  bool get _templateRunning =>
      _activeActions.any((a) => a.startsWith('${Repository.taskTemplateApply}:'));

  // ── §3.12.3 形态 B：宿主不可达时「等待宿主」替换无意义 spinner ──
  // DB 始终是 pending（红线：不引入 WAITING_HOST 存储态），此处纯按 pending
  // 持续时长派生 UI 展示——任务一旦被认领转 processing，判据自然失效、徽标消失。

  /// [match] 按任务动作匹配；模板这类动态动作串（`template_apply:<id>`）用前缀。
  bool _waitingHostOf(bool Function(String action) match) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in _pendingSince.entries) {
      if (match(e.key) &&
          now - e.value >= _hostWaitThreshold.inMilliseconds) {
        return true;
      }
    }
    return false;
  }

  bool get _summarizeWaiting =>
      _waitingHostOf((a) => a == Repository.taskLlmSummarize);
  bool get _tagsWaiting => _waitingHostOf((a) => a == Repository.taskLlmTags);
  bool get _templateWaiting =>
      _waitingHostOf((a) => a.startsWith('${Repository.taskTemplateApply}:'));

  /// 到阈值那一刻醒一次刷新 UI：**单次定时而非轮询**——取最早跨越阈值的剩余时长
  /// 设定一次 fire；已全部越界则不等（本次 setState 已生效）。到点后**重读队列**
  /// 而非仅 setState，避免任务已被认领却仍按陈旧数据显示徽标。
  void _scheduleHostWaitFlip(Map<String, int> since) {
    _hostWaitTimer?.cancel();
    _hostWaitTimer = null;
    if (since.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    int? nearest;
    for (final ts in since.values) {
      final left = ts + _hostWaitThreshold.inMilliseconds - now;
      if (left > 0 && (nearest == null || left < nearest)) nearest = left;
    }
    if (nearest == null) return;
    _hostWaitTimer = Timer(Duration(milliseconds: nearest), () {
      if (!mounted) return;
      unawaited(_loadActiveActions());
    });
  }

  /// 一键唤醒出口（契约 §3.12.3）：确认弹窗 → `goodshare/host_launch` 拉起 goodhub。
  /// 未安装 / 通道缺失 → toast 兜底；**不误报成功**（正确性由宿主侧 catch-up 兜底）。
  Future<void> _promptLaunchGoodhub() async {
    final ok = await confirmDialog(
      context,
      title: '等待 Goodhub 处理',
      content: '这条 AI 任务需要 Goodhub（AI 宿主）来消费。启动它会立即接管待处理任务；'
          '未安装则请先在设备上部署 Goodhub。',
      confirmText: '启动 Goodhub',
    );
    if (!ok || !mounted) return;
    final launched = await HostLaunchChannel().launchGoodhub();
    if (!mounted) return;
    if (!launched) _snack('未检测到 Goodhub 安装包');
  }

  /// 待办行是否已勾（渲染 lookup：todo_state_json 按行内容 hash 关联）。
  bool _todoDone(String text) {
    final h = TodoMark.hashOf(text);
    for (final m in _item.todoState) {
      if (m.hash == h) return m.done;
    }
    return false;
  }

  /// 待办勾选写路径（2026-10-05 接线，设计口径见 TodoMark.hashOf）：
  /// 勾选**不改正文**——全量重算 todoState（GC 口径：只保留当前正文中
  /// 存在的待办行，孤儿丢弃；被改文字的行自然落回「新待办、默认未勾」），
  /// 走 UpdateItemCommand + expectedVersion（乐观锁防与 AI/编辑互踩，
  /// 冲突弹动作层提示后重按即可——勾选是轻操作无长窗口）。
  Future<void> _toggleTodo(String text, bool done) async {
    final targetHash = TodoMark.hashOf(text);
    final bodyTodos = scanTodoTexts(_item.bodyText);
    final marks = <TodoMark>[];
    final seen = <String>{};
    var hit = false;
    for (final t in bodyTodos) {
      final h = TodoMark.hashOf(t);
      if (!seen.add(h)) continue; // 同文多行共享一条状态（内容寻址边界）
      if (h == targetHash) {
        hit = true;
        marks.add(TodoMark(
          hash: h,
          done: done,
          ts: done ? DateTime.now().millisecondsSinceEpoch : null,
        ));
        continue;
      }
      for (final m in _item.todoState) {
        if (m.hash == h) {
          marks.add(m);
          break;
        }
      }
    }
    // 极端时序防线：正文刚被改、目标行已不存在 → 不写（防造孤儿 + 防误勾他行）
    if (!hit) return;
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(
          id: _item.id!,
          todoState: marks,
          expectedVersion: _item.version,
        ),
        vaultContext: widget.vaultContext,
      ),
      null,
    );
  }

  Future<void> _confirmDelete() async {
    final ok = await confirmDialog(
      context,
      title: '删除这条收集？',
      content: '删除后 30 天内可在「设置 → 最近删除」恢复。',
      confirmText: '删除',
      danger: true,
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

  /// 解锁门禁：合并收集条目默认 `editLocked`，动作层直接拒绝 `update`（设计 §4.9，
  /// UI 置灰只是快路径不是安全边界）。故进入任何编辑前先 `unlock_edit`，走二次确认
  /// + 触觉反馈；仍锁定（命令被拒）即返回 false 止步，不让用户进编辑器后才撞
  /// 「保存被拒」。返回 true = 已解锁或本就未锁定，可继续编辑。
  Future<bool> _ensureUnlocked() async {
    if (!_item.editLocked) return true;
    final ok = await confirmDialog(
      context,
      title: '解除编辑锁定？',
      content: '这条是合并收集的条目，默认锁定以防误改。解除后即可编辑。',
      confirmText: '解除并编辑',
    );
    if (ok != true) return false;
    HapticFeedback.lightImpact();
    await _run(
      () => widget.handler.execute(
        UnlockEditCommand(_item.id!),
        vaultContext: widget.vaultContext,
      ),
      '已解除编辑锁定',
    );
    // _run 内含 reload：仍未解锁（命令被拒）即止
    return mounted && !_item.editLocked;
  }

  /// 底栏主按钮：**读态 = 「编辑」（进入编辑态），编辑态 = 「保存」（提交并回读态）**。
  ///
  /// 顺带修正一处语义缺陷：此前 label 由 `editLocked` 决定（`'编辑'`/`'保存'`），
  /// 但**两者都打开同一个块编辑器**——label 与行为不符。现在 **label = 实际行为**。
  Future<void> _onPrimaryAction() async {
    if (_editing) {
      await _commitEdit();
    } else {
      await _enterEdit();
    }
  }

  /// 进入编辑态：先过解锁（合并模式条目），再把 human_md 一次转换为
  /// 作曲器草稿行（noteMdToDraftRows，2026-10-03 编辑器统一）。
  Future<void> _enterEdit() async {
    if (!await _ensureUnlocked()) return;
    setState(() {
      _editRows = noteMdToDraftRows(_item.bodyText);
      _editing = true;
    });
    // 进态即自动聚焦末段+弹键盘（输入阻碍审计 P3：此前还要再点一下正文）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerKey.currentState?.requestFocusFirst();
    });
  }

  /// 退出编辑态（不提交）：编辑行丢弃。
  void _exitEdit() {
    setState(() {
      _editRows = null;
      _editing = false;
    });
  }

  /// 丢弃确认：编辑态下返回键 / 侧滑被拦截时询问（危险操作二次确认口径）。
  Future<bool> _confirmDiscardEdit() async {
    return confirmDialog(
      context,
      title: '放弃未保存的改动？',
      content: '退出编辑态后，本次编辑的内容不会保存。',
      cancelText: '继续编辑',
      confirmText: '放弃',
      danger: true,
    );
  }

  /// 提交：作曲器段序列化（serializeNoteMd）→ `UpdateItemCommand(humanMd)`
  /// → 回读态。**无改动时明说「无改动」，不假装成功**——否则用户以为存过了。
  Future<void> _commitEdit() async {
    final models = _composerKey.currentState?.toNoteSegments();
    if (models == null) return;
    final md = serializeNoteMd(models);
    setState(() {
      _editRows = null;
      _editing = false;
    });
    if (md == _item.bodyText) {
      if (mounted) _snack('无改动');
      return;
    }
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, humanMd: md),
        vaultContext: widget.vaultContext,
      ),
      '已保存',
    );
  }

  /// 当前正文（会话判定与 diff 的唯一取文口）：编辑态以编辑器**活文本**为准
  /// （保存前的手改也必须计入接管判定），读态以库里 human_md 为准。
  String _currentBodyText() {
    if (_editing) {
      final st = _composerKey.currentState;
      if (st != null) return serializeNoteMd(st.toNoteSegments());
    }
    return _item.bodyText;
  }

  /// 变更概览（按「基线 + 当前」缓存：diff 有代价，文本不变不重算）。
  String _aiSummaryFor(String baseline, String current) {
    // 长度前缀防拼接碰撞（"a b"+"c" 与 "a"+"b c" 会撞成同一个 key）。
    final key = '${baseline.length}|$baseline\u0000$current';
    if (_aiSummaryKey != key) {
      _aiSummaryKey = key;
      _aiSummary = computeAiDiff(before: baseline, after: current).summary;
    }
    return _aiSummary;
  }

  /// AI 会话悬浮条（会话关闭时零高度，不占位、不参与底栏布局）。
  Widget _aiSessionBar() {
    final ctl = _aiSession;
    if (ctl == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        if (!ctl.isOpen) return const SizedBox.shrink();
        return AiSessionBar(
          phase: ctl.phase,
          summary: _aiSummaryFor(ctl.baseline ?? '', _currentBodyText()),
          onViewDiff: _aiViewDiff,
          onRestore: _aiRestore,
          onReapply: _aiReapply,
        );
      },
    );
  }

  /// 查看对比：基线 ↔ 当前（§7 Inline Diff，只读）。
  Future<void> _aiViewDiff() async {
    final base = _aiSession?.baseline ?? '';
    if (base.isEmpty) return;
    await showAiDiffSheet(context, before: base, after: _currentBodyText());
  }

  /// 还原到 AI 动笔前（§4 AI_PENDING → RESTORED）。
  Future<void> _aiRestore() async {
    final ctl = _aiSession;
    if (ctl == null) return;
    try {
      final base = await ctl.restore();
      if (base == null) {
        _snack('没有可还原的 AI 改动');
        return;
      }
      _pushProgrammatic(base);
      await _reload();
    } on ActionException catch (e) {
      _snack(e.message);
    }
  }

  /// 换回 AI 版（§4 RESTORED → AI_PENDING，恢复源 = ai_revisions 最新条）。
  Future<void> _aiReapply() async {
    final ctl = _aiSession;
    if (ctl == null) return;
    try {
      final ai = await ctl.reapplyAi();
      if (ai == null) {
        _snack('AI 版本已不可恢复');
        return;
      }
      _pushProgrammatic(ai);
      await _reload();
    } on ActionException catch (e) {
      _snack(e.message);
    }
  }

  /// 程序化整篇替换（还原 / 恢复 AI 改动 / 插入 AI 版）：编辑态顺带清空撤销
  /// 栈（§8.4），读态无编辑器则只落库、由 [_reload] 驱动重渲染。
  void _pushProgrammatic(String md) {
    _composerKey.currentState?.replaceAll(noteMdToDraftRows(md));
  }

  /// 接管 Toast（§7：3s 自动消失、非阻断，绝不弹确认框）——恢复能力交给
  /// 历史面板，而不是拦住用户的写作流。
  void _onAiTakeover() {
    if (!mounted) return;
    _snack('已切换手动编辑', action: FilledButton.tonal(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.labelMedium,
      ),
      onPressed: _showAiHistory,
      child: const Text('查看 AI 历史'),
    ));
  }

  Future<void> _showAiHistory() async {
    final id = _item.id;
    if (id == null) return;
    final ai = await widget.repo.latestAiRevision(id);
    if (ai == null || !mounted) return;
    await showAiRevisionSheet(
      context,
      text: ai,
      onInsert: _editing ? () => _insertAiText(ai) : null,
    );
  }

  /// 历史面板「插入」= 追加到正文末尾（MVP 口径）。接管后会话已关闭，插入
  /// 是「取回内容」而非「还原」，不重建会话态；走程序化替换故撤销栈同清。
  Future<void> _insertAiText(String ai) async {
    final cur = _currentBodyText();
    final next = cur.trim().isEmpty ? ai : '${cur.trimRight()}\n\n$ai';
    _pushProgrammatic(next);
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, humanMd: next),
        vaultContext: widget.vaultContext,
      ),
      '已插入正文',
    );
  }

  /// 编辑态正文 slivers（2026-10-03 编辑器统一）：与新增作曲页**同一编辑器**
  ///（[NoteComposerEditor]，分段作曲层+动作行+可拖动格式转盘）。
  /// SliverFillRemaining 给有界高度（编辑器内部自管滚动与转盘挂载）；
  /// TL;DR / 标签 / 灵感区在编辑态不展示——本拍板只改正文，退出编辑后照常渲染。
  /// 媒体说明（alt/label）随段进出（noteMdToDraftRows 草稿行第 3 位），
  /// 编辑态可长按换媒体/点音频重录（[_replaceComposerMedia]），标签文案不可改
  ///（与作曲页形态一致）。
  List<Widget> _editBodySlivers() => [
    // 水平留白由外层 SliverPadding(Insets.xl) 统一给（勿双包）；
    // SliverFillRemaining 给编辑器有界高度（内部自管滚动与转盘挂载）。
    SliverFillRemaining(
      child: NoteComposerEditor(
        key: _composerKey,
        initialRows: _editRows ?? const [],
        // 接管检测入口（ai-writeback-revert §5）：只起/重置 settle 计时器，
        // 不做 setState——每击键整页重建是纯浪费（P2 性能防线，2026-10-04），
        // 判定与落库都在「停顿 1.5s」之后发生一次。
        onChanged: () => _aiSession?.noteUserEdit(),
        onMediaReplace: _replaceComposerMedia,
        audioController: _audioPlayback, // 页面单实例红线：复用页面控制器
      ),
    ),
  ];

  /// 编辑态媒体替换（保留能力，2026-10-04 二次拍板）：长按图/视频卡=换文件、
  /// 长按音频卡=重录替换（点按音频卡已归播放）。就地改段 url，保存时一并
  /// 落库；取消=不出编辑态整体丢弃。
  Future<void> _replaceComposerMedia(NoteMediaSeg seg) async {
    switch (seg.kind) {
      case NoteMediaKind.audio:
        final path = await showAudioRecordSheet(context);
        if (path == null) return; // 用户取消/丢弃
        seg.url = await toLocalMediaUrl(path);
      case NoteMediaKind.image:
      case NoteMediaKind.video:
        final type = seg.kind == NoteMediaKind.image
            ? FileType.image
            : FileType.video;
        final files = await FilePicker.pickFiles(type: type);
        if (files.isEmpty) return; // 用户取消
        final path = files.single.path;
        if (path == null) return;
        final saved = await copyToAppDir(path);
        if (saved == null) {
          if (mounted) _snack('媒体文件保存失败', kind: ToastKind.error);
          return;
        }
        seg.url = await toLocalMediaUrl(saved);
    }
  }

  /// 标题长按入口：**只改标题**（与内容编辑职责分离）。锁定条目先经
  /// [_ensureUnlocked] 解锁，再进入**原地内联编辑**（标题位置直接变输入框、不弹
  /// 对话框，2026-10-02 拍板）。
  Future<void> _editTitle() async {
    if (await _ensureUnlocked()) _enterTitleEdit();
  }

  /// 进入标题原地编辑：标题位置切为 TextField，自动聚焦并全选，回车 / 失焦即存，
  /// 仅 patch `human_title`（动作层 patch 语义），不动导语 / 正文。
  void _enterTitleEdit() {
    if (_editingTitle) return;
    _titleCtrl.text = _item.humanTitle ?? '';
    setState(() => _editingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _titleFocus.requestFocus();
      _titleCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _titleCtrl.text.length,
      );
    });
  }

  /// 提交标题：退出编辑态并 patch `human_title`（无变化则不落库）。
  Future<void> _commitTitleEdit() async {
    if (!_editingTitle || !mounted) return;
    final next = _titleCtrl.text.trim();
    setState(() => _editingTitle = false);
    if (next == (_item.humanTitle ?? '')) return; // 无变化
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, title: next),
        vaultContext: widget.vaultContext,
      ),
      '已修改标题',
    );
  }

  // 内容编辑（原 `_edit`：打开 fullscreen 块编辑器 dialog）已于 2026-10-02 就地编辑
  // 重构中移除——底栏「编辑」改为进入就地编辑态（见 `_enterEdit`），提交走
  // `_commitEdit`，不再有「打开另一个页面编辑」的模态路径。旧 dialog
  // （block_editor_dialog.dart）已退役，正文编辑能力由 `_EditBody` 承载。

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
      // 同文预检（2026-10-06 拍板扩展到音频/视频条目）：源语==目标语 → 提示
      // 不入队不算失败；与块级 _runWorkflowStep 翻译预检同口径（双保险兜底
      // 在引擎侧 completed+note，页侧 _waitForTask→状态线承载）。
      final src = _item.bodyText.trim();
      if (src.isNotEmpty && detectSourceLanguage(src) == caps.targetLang) {
        _snack('源文本已是${languageLabel(caps.targetLang)}，无须翻译');
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
      'ocr' ||
      'transcribe' => fresh.bodyText.trim().isEmpty ? null : fresh.bodyText,
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
  Future<void> _applyCapabilityOutput(
    ReinjectTarget target,
    String text,
  ) async {
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
  /// 或打开编辑工具流，切片/提取音轨/字幕导出为媒体工具流。
  /// 独立能力分发。
  ///
  /// [blockKey] 非 null = 图片**块**能力（块级化 2026-10-05）：分类/条码落
  /// block_artifacts、标注按 (item, blockKey) 落盘；顶级 'item' 与行内 local://
  /// 同走此路径，统一处理口径（不再区分）。null = 条目级能力（旧路径，保留）。
  Future<void> _runStandaloneCapability(
    String capabilityId, {
    String? blockKey,
  }) async {
    final id = _item.id!;
    switch (capabilityId) {
      case 'annotate':
        // 图片块标注：按 (item, blockKey) 落盘；块图片取 blockFilePath
        //（顶级 'item' 回退 item.rawFilePath）。
        String? imagePath;
        if (blockKey != null && blockKey != BlockArtifactKind.topLevelKey) {
          imagePath = await resolveBlockMediaPath(blockKey);
        }
        if (!mounted) return;
        await showAnnotationEditorPage(
          context,
          item: _item,
          blockKey: blockKey,
          imagePath: imagePath,
        );
        await _reload();
      case 'classify':
        await _run(
          () => widget.handler.execute(
            ClassifyCommand(id, blockKey: blockKey),
            vaultContext: widget.vaultContext,
          ),
          '已入队分类',
        );
        if (blockKey != null) {
          // 消费落定结果（2026-10-05 修失败盲区）：块任务 finishTask 不广播，
          // 失败无人提示、产物落库后详情页也不会自动刷新——都在这里显式补。
          final (ok, _) = await _waitForBlockTask(id, 'block_classify', blockKey);
          if (!ok && mounted) {
            _snack('分类未产出结果，可重试或到任务队列查看原因');
          }
          await _reload();
        }
      case 'scan_barcode':
        await _run(
          () => widget.handler.execute(
            ScanBarcodeCommand(id, blockKey: blockKey),
            vaultContext: widget.vaultContext,
          ),
          '已入队条码扫描',
        );
        if (blockKey != null) {
          final (ok, _) = await _waitForBlockTask(id, 'block_scan_barcode', blockKey);
          if (!ok && mounted) {
            _snack('条码扫描未产出结果，可重试或到任务队列查看原因');
          }
          await _reload();
        }
      // **当前无 UI 入口**（2026-10-05 拍板：分析文本 facets 为机器维度——
      // MCP get_item 消费、V2 聚类视角，人类展示与标签重复故撤 chip）——
      // 命令保留供 MCP（analyze_text_item），分发分支挂载即生效。
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
          blockKey: blockKey,
          vaultContext: widget.vaultContext,
        );
        await _reload();
      // 以下两项**当前无 UI 入口**（拍板 16：提取音轨并入转写、字幕导出由
      // 字幕产物卡「导出」承载）——命令与执行函数保留，供 MCP 与后续挂载点；
      // `_runStandaloneCapability` 分发表保持完整，挂载即生效。
      case 'extract_audio':
        await extractAudioTrack(context, _item);
      case 'export_subtitle':
        await exportSubtitles(context, id);
    }
  }

  // ── 块附件通道执行作用域（block-artifact-workflow.md §4 四回调注入）：
  // 行内媒体块长按进工作流页，产物读写全走 block_artifacts（条目级字段零触碰）。

  /// 装载该块产物视图（工作流轨数据源，§3.3 续跑判定的唯一事实源）。
  Future<BlockArtifactsView> _loadBlockArtifacts(String blockKey) async {
    final arts = await widget.repo.blockArtifacts.listForItem(_item.id!, blockKey: blockKey);
    final kinds = <String>{};
    final text = <String, String>{};
    final meta = <String, String>{};
    final files = <String, String>{};
    final elapsedMs = <String, int>{};
    final cues = <String, List<AsrCue>>{};
    final revisedKinds = <String>{};
    for (final a in arts) {
      kinds.add(a.kind);
      if (a.text?.trim().isNotEmpty ?? false) text[a.kind] = a.text!;
      if (a.filePath?.isNotEmpty ?? false) files[a.kind] = a.filePath!;
      // 拍板 18⑤：人工修订态（meta_json.revised）→ 卡头「已修订」+ Reset 确认文案
      if (a.revised) revisedKinds.add(a.kind);
      // 耗时归卡头（§4 三段式），摘要行只留 kind 自身语义——两处都放会重复
      final elapsed = a.elapsedMs; // 执行侧实测（queue_consumer 注入）
      if (elapsed != null) elapsedMs[a.kind] = elapsed;
      final cueCount = a.cueCount; // 解码在数据层（arch-guard R2：UI 不内联 jsonDecode）
      final summary = switch (a.kind) {
        BlockArtifactKind.subtitle => cueCount == null ? null : '$cueCount 段',
        BlockArtifactKind.audioFile => a.filePath?.split('/').last,
        _ => cueCount == null ? null : '$cueCount 段',
      };
      // 空摘要不写进 meta：产物卡会把它当有效摘要行渲染成空白中部
      if (summary != null && summary.isNotEmpty) meta[a.kind] = summary;
      // 拍板 18 一卡双视图：cue 序列事实源在 SRT 文件，parseSrtVtt 反解析
      //（文件缺失/坏段 → 空表目，双视图退化纯文本，不抛）
      if (a.kind == BlockArtifactKind.subtitle && files.containsKey(a.kind)) {
        try {
          cues[a.kind] = parseSrtVtt(await File(files[a.kind]!).readAsString());
        } catch (_) {
          // 读失败不阻断装载（增强非必需，同 parseSrtVtt 容错口径）
        }
      }
    }
    return BlockArtifactsView(
      kinds: kinds,
      text: text,
      meta: meta,
      filePath: files,
      elapsedMs: elapsedMs,
      cues: cues,
      revisedKinds: revisedKinds,
    );
  }

  /// 执行工作流步骤：组装 block 命令入队（与 UI 顶级按钮 / MCP 同源，R2）→
  /// 等任务落定 → 按**产物是否落库**返回产出 + 任务 note（R1 同一份状态，
  /// 2026-10-08）：任务 status completed ≠ 有产出——空转写 / 同文翻译等
  /// 「completed 无产物」同样返回未产出并携 note，步骤行红字展示可读原因，
  /// 不留白。**所有分支都必带原因**（2026-10-08）：note 为空会让轨上退化成
  /// 「未产出结果，可重试」，把「无须翻译 / 引擎不可用」这类重试无用的情况
  /// 伪装成可重试的失败。
  Future<(bool, String?)> _runWorkflowStep(WorkflowStep step, String blockKey, String? sourceKind) async {
    final id = _item.id!;
    final head = 'block_${step.id}';
    if (step.id == 'translate') {
      // 入队前预检：与条目级翻译同口径（引擎不可用不入队空耗）。
      // **原因一律进 note 回传**（2026-10-08）：此前四个分支都 `_snack(...) +
      // return (false, null)`，note 为空 → 轨上退化成「未产出结果，可重试」，
      // 而真实原因只在一闪而过的 snack 里——用户据此以为「重试就有」，实际是
      // 目标语言与源语相同（或引擎不可用），重试多少次都一样。现在由页级
      // Toast + 步骤行红字同一份文案承载，单一出口不重复造提示。
      final caps = widget.caps;
      if (!caps.translationEnabled) {
        return (false, '翻译已关闭：设置 → 翻译 可开启');
      }
      caps.router?.reset();
      if (!await caps.checkTranslationAvailable()) {
        final reason = await caps.translationUnavailableReason();
        return (false, '无法翻译：${reason ?? '无可用翻译引擎'}（设置 → 翻译 可下载语言包）');
      }
      // 同文预检（2026-10-06 拍板）：入队前判源产物语言，源语==目标语 → 提示
      // 「无须翻译」，不入队也不算失败（成功路径的零工作分支）；引擎侧同判定
      // （completed+note）作兜底双保险，见 _runWorkflowStep 落定分支。
      // 措辞带可行动去向：转写产出中文 + 目标语中文是这里的典型命中场景。
      final sourceText = sourceKind != null
          ? await _blockArtifactText(blockKey, sourceKind)
          : null;
      if (sourceText != null && detectSourceLanguage(sourceText) == caps.targetLang) {
        return (false,
            '源文本已是${languageLabel(caps.targetLang)}，无须翻译'
            '（想要译文就到「设置 → 翻译」把目标语言换成别的语言）');
      }
    }
    final ItemCommand command;
    switch (step.id) {
      case 'ocr':
        command = OcrCommand(id, blockKey: blockKey);
      case 'transcribe':
        command = TranscribeCommand(id, blockKey: blockKey);
      case 'translate':
        command = TranslateCommand(id, blockKey: blockKey, sourceKind: sourceKind);
      case 'summarize':
        command = SummarizeCommand(id, blockKey: blockKey);
      case 'extract_audio':
        command = ExtractAudioCommand(id, blockKey: blockKey);
      default:
        return (false, '工作流步骤「${step.id}」未接入（spec 未覆盖）');
    }
    try {
      await widget.handler.execute(command, vaultContext: widget.vaultContext);
    } on ActionException catch (e) {
      return (false, e.message); // 拒绝原因进步骤行，不再只落一闪而过的 snack
    }
    final (ok, note) = await _waitForBlockTask(id, head, blockKey);
    // 同文兜底提示（引擎判定 completed 无产物，2026-10-06 拍板「这也算成功」）：
    // 必须把原因转给用户，不能看起来像静默失败（R1 同一份状态）。
    // 匹配「需翻译」同时覆盖无须/无需两种历史措辞（存量任务行）。
    if (ok && mounted && step.id == 'translate' && (note?.contains('需翻译') ?? false)) {
      _snack(note!);
    }
    if (!ok) {
      // 等待超时 / 未找到任务时 note 为空，同样不能落回「可重试」的误导文案。
      return (false, note ?? '任务未落定（等待超时或未找到对应任务），可到任务队列查看进度');
    }
    // R1（2026-10-08）：status completed ≠ 有产出。期望产物未落库（空转写 /
    // 同文翻译兜底等）→ 按未产出返回并携 note，步骤行红字展示可读原因。
    // 条目级步骤（textSpec）produces 为空 = 产物走条目级字段，不在此判。
    if (step.produces.isNotEmpty) {
      final kinds =
          (await widget.repo.blockArtifacts.listForItem(id, blockKey: blockKey))
              .map((a) => a.kind)
              .toSet();
      if (step.produces.any((k) => !kinds.contains(k))) {
        return (false, note);
      }
    }
    return (true, note);
  }

  /// 读该块某产物的文本（同文预检的源；缺失/空返回 null）。
  Future<String?> _blockArtifactText(String blockKey, String kind) async {
    final a = await widget.repo.blockArtifacts.get(_item.id!, blockKey, kind);
    final t = a?.text;
    return (t != null && t.trim().isNotEmpty) ? t : null;
  }

  /// 等待该条目指定 block 任务的**最新**一次落定（同 [ _waitForTask] 口径，
  /// 匹配规则换为动作头 + blockKey——块串参数含 mode/lang，不能整串比对）。
  /// 返回 (是否成功, 任务 note)：note 供页侧转提示（如翻译「源文本已是中文，
  /// 无须翻译」——completed 无产物时用户需要知道为什么，R1 同一份状态）。
  Future<(bool, String?)> _waitForBlockTask(String itemId, String head, String blockKey) async {
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return (false, null);
      final tasks = await widget.repo.listTasks(limit: 50);
      for (final t in tasks) {
        if (t['item_id'] != itemId) continue;
        final parsed = Repository.parseBlockAction(t['task_action'] as String?);
        if (parsed == null || parsed.$1 != head || parsed.$2 != blockKey) continue;
        final status = t['status'] as String? ?? '';
        if (status == 'pending' || status == 'processing') break;
        return (status == 'completed', t['last_note'] as String?);
      }
    }
    return (false, null);
  }

  /// Reset 该块全部产物（表行 + 文件产物磁盘联动删除，§2.2 纪律 7）。
  Future<void> _resetBlockArtifacts(String blockKey) async {
    await widget.repo.blockArtifacts.deleteBlock(_item.id!, blockKey);
  }

  /// 块字幕装载（SubtitleScope 数据源）：查 subtitle 产物 → 读文件反解析 cue。
  /// null = 无字幕产物（播放器无字幕轨，增强非必需）。
  Future<List<AsrCue>?> _loadBlockSubtitles(String blockKey) async {
    final arts = await widget.repo.blockArtifacts.listForItem(
      _item.id!,
      blockKey: blockKey,
    );
    final sub = arts
        .where((a) => a.kind == BlockArtifactKind.subtitle)
        .firstOrNull;
    if (sub?.filePath == null) return null;
    final f = File(sub!.filePath!);
    if (!await f.exists()) return null;
    final cues = parseSrtVtt(await f.readAsString());
    return cues.isEmpty ? null : cues;
  }

  /// §3.5 跳帧联动：字幕卡点某句 cue → 全屏播放器定位到该句起点播放。
  /// cue 序号口径与工作流轨 cue 列表一致（parseSrtVtt 已过滤空文本并排序，
  /// 两侧同源同序）。
  Future<void> _onCueSeek(String blockKey, int cueIndex) async {
    final cues = await _loadBlockSubtitles(blockKey);
    if (cues == null || cueIndex < 0 || cueIndex >= cues.length) return;
    if (!mounted) return;
    // 顶级条目统一（§2.7）：blockKey='item' 没有可剥的 local:// 前缀，
    // 直接用条目 rawFilePath 绝对路径（resolveLocalMediaSrc 对非 local://
    // 原样透传）——此前 'item' 被当路径传进播放器，必然加载失败。
    final String url;
    if (blockKey == BlockArtifactKind.topLevelKey) {
      final raw = _item.rawFilePath;
      if (raw == null || raw.isEmpty) return;
      url = raw;
    } else {
      url = blockKey.startsWith('local://')
          ? blockKey.substring('local://'.length)
          : blockKey;
    }
    await showInlineVideoPlayer(
      context,
      url: url,
      itemId: _item.id!,
      label: '视频',
      startAt: Duration(milliseconds: (cues[cueIndex].start * 1000).round()),
    );
  }

  /// §4 文本产物修订（三段式「文本=全文预览可编辑」）：编辑页返回修订文本 →
  /// upsert 回 block_artifacts。**只改 text**——filePath/metaJson 原样回传，
  /// 防止「应用」读取的源产物与字幕/音轨文件失同步；人工修订零算力回退。
  Future<String?> _editBlockArtifact(
      String blockKey, String kind, String currentText) async {
    final edited = await showBlockTextPage(context, initialText: currentText);
    if (edited == null || edited.trim().isEmpty || edited == currentText) {
      return null; // 取消 / 清空 / 无变化
    }
    final old =
        await widget.repo.blockArtifacts.get(_item.id!, blockKey, kind);
    if (old == null) return null; // 产物在编辑期间被 Reset，静默放弃
    await widget.repo.blockArtifacts.upsertAll(_item.id!, blockKey, [
      BlockArtifactInput(kind,
          text: edited, filePath: old.filePath, metaJson: old.metaJson),
    ]);
    if (mounted) _snack('已保存修订');
    return edited;
  }

  /// 拍板 18③ 逐 cue 行编辑保存（subtitle 是双视图事实源）：修订 cue 序列 →
  /// 重算 SRT/VTT 文件（SubtitleStore.saveBlock 双份同出）→ 重算 transcript
  /// text 行（cue 文本 join，与 AsrReconstructor 口径一致）→ 单事务 upsert
  /// 两行（subtitle 行 meta 保 cues 数 + mode + revised:true，filePath 原样）。
  /// 一处编辑三处生效：页面双视图 / 播放器字幕轨 / 导出文件同源。
  Future<bool> _saveBlockCues(String blockKey, List<AsrCue> cues) async {
    final id = _item.id!;
    final oldSub =
        await widget.repo.blockArtifacts.get(id, blockKey, BlockArtifactKind.subtitle);
    final oldTr =
        await widget.repo.blockArtifacts.get(id, blockKey, BlockArtifactKind.transcript);
    if (oldSub == null) return false; // 产物在编辑期间被 Reset，静默放弃
    try {
      await SubtitleStore.saveBlock(id, blockKey, cues);
    } catch (e) {
      if (mounted) _snack('字幕文件保存失败：$e');
      return false;
    }
    // usableCues 口径与 AsrReconstructor 对齐（丢纯标点 cue，保 cueIndex 与
    // §3.5 跳帧联动不错位）
    final text = usableCues(cues).map((c) => c.text.trim()).join('\n');
    // mode 元数据原样保留（revised 之外的字段不可知即不造假）：从旧 meta 提不出
    // mode 就只带 cues + revised。编解码走数据层出口（arch-guard R2）。
    final metaJson = BlockArtifactMeta.encode(
      cues: cues.length,
      mode: oldSub.subtitleMode,
      revised: true,
    );
    await widget.repo.blockArtifacts.upsertAll(id, blockKey, [
      BlockArtifactInput(BlockArtifactKind.subtitle,
          text: text, filePath: oldSub.filePath, metaJson: metaJson),
      if (oldTr != null)
        BlockArtifactInput(BlockArtifactKind.transcript,
            text: text,
            metaJson: BlockArtifactMeta.encode(cues: cues.length)),
    ]);
    if (mounted) _snack('已保存修订');
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // 编辑态拦截返回（2026-10-02 就地编辑拍板）：侧滑 / 物理返回键**不得直接退页**，
    // 降级为「退出编辑态」并二次确认——否则用户一滑就丢掉正在编辑的内容。
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_editing) return;
        final discard = await _confirmDiscardEdit();
        if (discard && mounted) _exitEdit();
      },
      child: Scaffold(
        // 二级页顶栏改为 SliverAppBar（floating+snap）随滚动隐显，与首页同构
        // （2026-10-02 拍板）：顶部只留标题（内容），「⋯」危险/低频操作下沉到底栏
        // 第 4 项（拇指可达，优于顶部）。滚走藏、回滚弹；页面在顶部恒显。
        // Phase 1：主体改 CustomScrollView，正文 block 经 ItemViewTemplate.bodySlivers
        // 以 SliverList 虚拟化，数万字长文只构建可视区 widget。
        // 跨块文本选择：正文区统一包 SelectionArea（rich-text-component.md §3），
        // 块内为普通 Text，长按拖拽即可跨块复制。
        // 页面级音频播放服务作用域：行内 AudioBlock / 顶级音频区共用唯一播放器
        // RepaintBoundary：分享截图渲染边界（detail-two-zone.md §6 Theme 红线
        // ——复用页面既有边界，天然继承 Theme/MediaQuery，不重建离屏树）。
        body: Stack(
          children: [
            // P0-2 全篇级任务微进度（detail-page-visual-audit.md §6）：本条目有
            // active 任务时顶栏下 2dp 线性进度——长文任意滚动位置恒可见（钉在
            // Stack 顶层，不随 SliverAppBar 隐显）。
            if (_activeActions.isNotEmpty)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              ),
            AudioPlaybackService(
              controller: _audioPlayback,
              child: BlockCapabilityExecutor(
                onRunStep: _runCapabilityStep,
                onApply: _applyCapabilityOutput,
                onEditOutput: (raw) =>
                    showBlockTextPage(context, initialText: raw),
                onRunStandalone: (id, bk) =>
                    _runStandaloneCapability(id, blockKey: bk),
                loadAnnotationCount: (bk) async =>
                    (await AnnotationStore.load(_item.id!, bk)).length,
                // 双轨口径（block-artifact-workflow.md §9 拍板 15：**终态非过渡**）：
                // 链式卡轨服务「无持久块」的场景（文本块划词 / 未注入块通道的
                // 顶级媒体区）——产出落条目级字段（正文/译文/摘要），Reset 语义
                // 就是「归零卡内状态、不碰条目数据」，故 onReset 空实现是**正确
                // 语义**不是待补的债（卡内 chain.reset 由链式卡自己调）；
                // loadPersistedOutputs 空 = 无块产物可 restore（无「已落库步」
                // 即无续跑死锁可解除）。有 block_key 的走下面块通道四回调。
                onReset: () async {},
                loadPersistedOutputs: () => const {},
                // 块附件通道（block-artifact-workflow.md §4）：行内媒体块长按进
                // 工作流页，产物读写走 block_artifacts（四回调齐备才启用）。
                loadBlockArtifacts: _loadBlockArtifacts,
                onRunWorkflowStep: _runWorkflowStep,
                loadBlockClips: (blockKey) async => parseClipsJson(_item.clipsJson)
                    .where((c) => c.blockKey == blockKey)
                    .toList(),
                resetBlock: _resetBlockArtifacts,
                onCueSeek: _onCueSeek,
                onEditArtifact: _editBlockArtifact,
                onSaveCues: _saveBlockCues,
                child: RepaintBoundary(
                  key: _bodyBoundaryKey,
                  child: SubtitleScope(
                    itemId: _item.id!,
                    loadBlockSubtitles: _loadBlockSubtitles,
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
                        // 待办交互作用域（2026-10-05 接线）：只有走
                        // ContentBodySliver 的**正文**回落取用——摘要卡等
                        // 直用 RichTextView 的位置不受影响（AI 摘要里的
                        // `- [ ]` 样式行不是真待办，不可勾）。
                        child: TodoInteractionScope(
                          onToggle: _toggleTodo,
                          done: _todoDone,
                          child: CustomScrollView(
                          // 分享截图窗口内挂控制器（body_screenshot 分段拼接
                          // 需驱动逐屏滚动）；常态不接管用户滚动。
                          controller: _shareScope != null ? _shareScrollCtrl : null,
                          slivers: [
                            // 截图窗口内隐藏浮动 AppBar（scope 非 null 即截图态）：
                            // 否则悬浮标题会烙进每屏截图顶部。
                            if (_shareScope == null)
                              SliverAppBar(
                              automaticallyImplyLeading: false,
                              floating: true,
                              snap: true,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surface,
                              elevation: 0,
                              titleSpacing: Insets.md,
                              title: _buildTitle(),
                            ),
                            // 内容水平留白真正包住 slivers——此前是无 sliver 子项的死代码，
                            // Insets.xl 留白从未生效，正文一直贴屏幕左右边缘。
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                Insets.xl,
                                Insets.md,
                                Insets.xl,
                                0,
                              ),
                              sliver: SliverMainAxisGroup(
                                slivers: [
                                  // 分享截图范围裁剪：不勾「正文」连 TLDR/类型
                                  // 专属区一并收起（2026-10-05 接通，此前勾选零作用）
                                  if (!(_shareScope?.includeBody == false))
                                    ...(_editing && _editRows != null
                                        ? _editBodySlivers()
                                        : ItemViewTemplate(item: _item)
                                            .bodySlivers(context)),
                                  if (!_editing) ...[
                                    SliverToBoxAdapter(
                                      child: _attachStatusLine(),
                                    ),
                                    // 灵感区（ui-design §4.3 两区改版）：摘要/标签切换 + 刷新重生成
                                    SliverToBoxAdapter(
                                      child: _inspirationSection(),
                                    ),
                                    if (_item.hasTranslation)
                                      SliverToBoxAdapter(
                                        child: _appendix(
                                          '译文',
                                          _item.translatedMd!,
                                        ),
                                      ),
                                    SliverToBoxAdapter(
                                      child: _AiTaskStatusLine(
                                        repo: widget.repo,
                                        item: _item,
                                      ),
                                    ),
                                    SliverToBoxAdapter(child: _sourceLine()),
                                    const SliverToBoxAdapter(
                                      child: SizedBox(height: 24),
                                    ),
                                    SliverToBoxAdapter(
                                      child: PoeticText(
                                        sloganFor(SloganKeys.detailFooter),
                                        large: false,
                                        align: TextAlign.center,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ), // CustomScrollView
                        ), // TodoInteractionScope
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ],
        ),
        // 公共操作条（两区改版）：工作区 / 分享 / 删除。方向感知隐显：
        // 下滑阅读收起（读模式收 chrome），上滑操作弹回（找模式亮 chrome），
        // 静止保持；键盘弹出（灵感区输入）时顺带隐藏——纯干扰。
        bottomNavigationBar: ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.bottomCenter,
            // **读写分离的两套状态机**（2026-10-02 就地编辑拍板）：
            // - 读态：维持原样——方向感知隐显 + 键盘弹起让位，保沉浸阅读视野；
            // - 编辑态：**强制常驻**。就地编辑全程有键盘，若沿用读态的
            //   `!_keyboardVisible`，「保存」会在用户打字时被自己藏掉——
            //   就地编辑将直接不可用（这是此前评估出的最高危缺口）。
            heightFactor: _editing
                ? 1
                : (_actionBarVisible && !_keyboardVisible ? 1 : 0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            // AI 会话悬浮条骑在公共操作条之上（会话关闭时零高度）。
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [_aiSessionBar(), _actionBar()],
            ),
          ),
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

  /// 顶栏标题（长按原地编辑，2026-10-02 拍板）：编辑态为 TextField，否则为
  /// 可长按文本。随 SliverAppBar 滚动隐显。
  ///
  /// （2026-10-15 注释漂移修复：此处原被 `_actionBar` 的「Wrap 而非 Row」孤儿
  /// 残片占用——该残片属旧版 5 格底栏注释，v2 单行化后已随 `_actionBar` 文档
  /// 重写清理，见 `detail-page-visual-audit.md` §5 盲点 A。）
  Widget _buildTitle() {
    if (_editingTitle) {
      return TextField(
        controller: _titleCtrl,
        focusNode: _titleFocus,
        autofocus: true,
        maxLines: 1,
        style: Theme.of(context).textTheme.titleLarge,
        decoration: const InputDecoration.collapsed(hintText: '标题'),
        onSubmitted: (_) => _commitTitleEdit(),
      );
    }
    final title = _item.humanTitle?.isNotEmpty == true
        ? _item.humanTitle!
        : _timeTitle;
    // 编辑态不显示顶栏标题（2026-10-03 拍板「标题独立，与 md 无关」）：
    // 标题由一级标题行/笔记时间派生，正文首行（常即标题行）已进所见即所得
    // 编辑器，顶栏再显一份即「标题重复显示」反馈；标题修改走读态长按入口。
    if (_editing) return const SizedBox.shrink();
    // 标题栏渲染纯文本（行内标记剥壳）：标题是笔记的简短指代，下划线等行内格式
    // 只在正文阅读态呈现（与列表/搜索预览口径一致），顶栏不承载下划线，
    // 也不出现 `<u>` 残壳。下方 body 的 ContentBody 仍按富文本渲染下划线。
    // titleToPlain 额外剥行首 `#`——速记一级标题派生的存量 humanTitle 原文
    // 以 `# ` 开头，标题位不得出现 `#` 残壳（纯文本口径，2026-10-06）。
    final plainTitle = titleToPlain(title);
    final titleStyle =
        Theme.of(context).textTheme.titleLarge ?? const TextStyle();
    return GestureDetector(
      onLongPress: _editTitle,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: true,
        label: '标题，长按可修改标题',
        child: Text(
          plainTitle,
          style: titleStyle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 调试态画黄黑斜纹警示条、release 直接裁切（2026-10-01 真机「斜黄条」）。
  /// 不用 OverflowBar——它放不下时是「每项各占一行」的竖排（AlertDialog
  /// 动作语义），不是换行；不用 BottomAppBar——它把子级高度钉死（实测
  /// h=56），两行必竖向溢出。
  /// 公共操作条（ui-design §4.3；2026-10-15 底栏单行化拍板，
  /// detail-page-visual-audit.md §6 盲点 A）：**常驻裁到 3 项**——编辑 / 分享 / ⋯
  /// 连成无分隔线的整体胶囊（surfaceContainerHigh 底 + Radii.lg 圆角）。
  /// - 331dp 逻辑屏（1272px / DPR 3.84）下旧 5 格 ≈63dp/格 < 74dp 内容宽
  ///   → 横向溢出（集成测试记录的 1.4px RenderFlex 溢出即此）；3 格 ≈105dp/格，
  ///   单行彻底消灭换行/溢出隐患——**固定操作条严禁自适应折行吃屏高**；
  /// - **删除与工作区已移入 `⋯` 面板**（`ItemActions.overflowSheet`，删除首位
  ///   红字）；编辑↔保存按态切换（label 即实际行为）；分享为唯一导出入口；
  /// - `⋯` 面板收：删除 / 工作区 / 重新处理（条件）+ 权限开关（保险箱/对AI可见/
  ///   允许AI编辑/机器码），单一入口不重复。
  Widget _actionBar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.lg),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                _barCell(
                  icon: _editing ? Icons.save_outlined : Icons.edit_outlined,
                  label: _editing ? '保存' : '编辑',
                  onPressed: _onPrimaryAction,
                ),
                _barCell(
                  icon: Icons.share_outlined,
                  label: '分享',
                  onPressed: _exportPdf,
                ),
                _barCell(
                  icon: Icons.more_horiz,
                  onPressed: _openOverflowSheet,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底栏连接胶囊内的单个点击单元（mymind 形态，ui-design §4.3）：icon + label 横排，
  /// 与全站底栏同款；无自身背景，整条胶囊共用一个圆角外形。`⋯` 单元无 label 仅图标；
  /// 删除标红（danger）。
  Widget _barCell({
    required IconData icon,
    String? label,
    required VoidCallback onPressed,
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = danger ? scheme.error : scheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: fg),
              if (label != null) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: fg),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 机器态二级页导航（P1-5 降级拍板：不再切换读态正文，读态容器保持纯粹；
  /// 入口仍走 `⋯` 面板，受设置「机器码」开关门控，默认关闭）。
  void _openMachineView() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => MachineViewPage(item: _item)),
    );
  }

  /// 从底部升起 mymind 风格功能面板（见 `_OverflowSheet`）。动作序列与条件收录
  /// 规则（分享/保险箱/删除/机器码）收口到 [ItemActions] 词汇表——本方法只剩
  /// 声明挑选 + 执行通道注入（单条 execute），视觉与动画不动（2026-10-02 拍板）。
  void _openOverflowSheet() {
    final actions = ItemActions.overflowSheet(
      ItemActionContext(
        item: _item,
        vaultContext: widget.vaultContext,
        machineModeEnabled: _machineModeEnabled,
      ),
      onVault: (on) => on
          ? _run(
              () => widget.handler.execute(SetVaultCommand(_item.id!, true)),
              '已移入保险箱',
            )
          : _run(
              () => widget.handler.execute(
                SetVaultCommand(_item.id!, false),
                vaultContext: true,
              ),
              '已移出保险箱',
            ),
      onAiVisible: (on) => _run(
        () => widget.handler
            .execute(SetAiVisibleCommand(_item.id!, on), actor: CommandActor.ui),
        on ? '已对 AI 可见' : '已对 AI 隐藏',
      ),
      onAiEditable: (on) => _run(
        () => widget.handler
            .execute(SetAiEditableCommand(_item.id!, on), actor: CommandActor.ui),
        on ? '已允许 AI 编辑' : '已收回 AI 编辑授权',
      ),
      onMachineOpen: _openMachineView,
      onReprocess: () async {
        // 主动重做会覆盖现正文（动作层先重置为原文再入队），必确认
        final ok = await confirmDialog(
          context,
          title: '重新处理这条？',
          content: '将重置为原文并重新执行 AI 处理，当前的 AI 产出与正文修改会被覆盖。',
          confirmText: '重新处理',
          danger: true,
        );
        if (!ok || !mounted) return;
        await _run(
          () => widget.handler.execute(
            ReprocessCommand(_item.id!),
            vaultContext: widget.vaultContext,
          ),
          '已重新入队处理',
        );
      },
      // 底栏单行化（2026-10-15）：删除/工作区从底栏移入本面板
      onDelete: _confirmDelete,
      onOpenWorkspace: _workspaceHint,
    );
    final items = <OverflowItem>[
      for (final a in actions)
        OverflowItem(
          a.icon,
          a.label,
          () => a.onInvoke(),
          danger: a.danger,
          checked: a.checked ?? false,
          grouped: a.grouped,
        ),
    ];
    showOverflowSheet(context, items: items);
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
    // 「识别与转写文本」附录（勾选才装载）：顶级块通道的 OCR/转写产物，
    // 详情页正文里没有对应分区，只在导出侧拼入（PDF）/截图无此项。
    String? appendixText;
    if (scope.includeBlockAppendix) {
      final view = await _loadBlockArtifacts(BlockArtifactKind.topLevelKey);
      final parts = [
        view.text[BlockArtifactKind.ocrText],
        view.text[BlockArtifactKind.transcript],
      ].whereType<String>().map((t) => t.trim()).where((t) => t.isNotEmpty);
      if (parts.isNotEmpty) appendixText = parts.join('\n\n');
    }
    try {
      String? path;
      final hasMedia =
          _item.itemType == InboxItem.typeAudio ||
          _item.itemType == InboxItem.typeVideo;
      if (!hasMedia) {
        // 截图路径按勾选真实裁剪：置 _shareScope → 等排版落定 → 分段滚动
        // 截图拼接长图 → 还原（2026-10-09 修：视口截图只出一屏、长文本截断、
        // 8000px 阈值永不触发——改驱动真实滚动逐屏拼接，阈值真正生效降 PDF）。
        final restoreOffset = _shareScrollCtrl.hasClients
            ? _shareScrollCtrl.offset
            : null;
        setState(() => _shareScope = scope);
        await WidgetsBinding.instance.endOfFrame;
        await WidgetsBinding.instance.endOfFrame;
        try {
          try {
            // 复用页面既有 RepaintBoundary（Theme 红线）；超长降级 PDF。
            // 浮动 AppBar 在截图窗口内隐藏（scope 非 null 即截图态），
            // 否则会烙进每屏截图顶部。
            path = await BodyScreenshotRenderer.renderScrollableToFile(
              _bodyBoundaryKey,
              _shareScrollCtrl,
            );
          } on TooTallException {
            path = null;
          }
        } finally {
          if (mounted) {
            setState(() => _shareScope = null);
            if (restoreOffset != null && _shareScrollCtrl.hasClients) {
              _shareScrollCtrl.jumpTo(restoreOffset);
            }
          }
        }
      }
      path ??= await ItemPdfExporter.export(
        _item,
        scope: scope,
        blockAppendixText: appendixText,
      );
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
    // 分享截图范围裁剪（2026-10-05 接通）：scope 非空=截图窗口内，
    // 按勾选收起分区；常态（null）全部照常渲染。
    final showAi = _shareScope?.includeSummary ?? true;
    final showInspiration = _shareScope?.includeInspiration ?? true;
    if (!showAi && !showInspiration) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showAi) _aiOutputSection(),
        if (showInspiration) _inspirationTextArea(),
      ],
    );
  }

  /// AI 产出区（detail-two-zone.md §3 拍板 2026-10-01）：摘要/标签**平行
  /// 并置**不再页签互斥——两者形态互补（几行文字 + 一行胶囊），叠放总高
  /// 很低，扫一眼全有，切换成本归零。标签支持手动增删（用户权威，AI 提取
  /// 只是代劳）；各自独立刷新。
  Widget _aiOutputSection() {
    final canProcess = _item.bodyText.trim().isNotEmpty;
    final summary = _item.summaryMd?.trim() ?? '';
    final hasSummary = summary.isNotEmpty;
    // P0-3 收敛数据源（detail-page-visual-audit.md §6）：深度摘要未生成时，
    // 摘要卡回退展示摄入期 human_tldr（原正文流 TLDR 卡已撤，卡名统一「摘要」）
    final tldrFallback = _item.humanTldr?.trim() ?? '';
    final hasTags = _item.tags.isNotEmpty;
    final templateOutput = _item.templateOutput?.trim() ?? '';
    final hasTemplateOutput = templateOutput.isNotEmpty;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 所用模板名（呈现规约 4）：模板已删（松散关联）时退化为不显示名字。
    final templateName =
        _item.templateId == null ? null : _templateNames[_item.templateId];
    final stale = _item.isTemplateOutputStale;

    // 分区动作行（卡内右上角）：内容语义归 SectionLegendCard 签名，按钮只管操作。
    // P0-2 卡内微观态：对应任务进行中时 refresh 位替换为卡内 spinner（18px，
    // 与图标同占位），不再依赖页面底部全局状态条（detail-page-visual-audit.md §6）。
    Widget sectionActions(
      String refreshTooltip,
      VoidCallback? onRefresh, {
      VoidCallback? onAdd,
      VoidCallback? onInstant,
      bool running = false,
      // §3.12.3 形态 B：pending 久未被宿主认领时以徽标**替换** spinner（不再空转）。
      bool waitingHost = false,
    }) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (onInstant != null)
            IconButton(
              tooltip: '即时摘要',
              icon: Icon(Icons.bolt, size: 18, color: scheme.onSurfaceVariant),
              onPressed: _instantRunning ? null : onInstant,
            ),
          if (onAdd != null)
            IconButton(
              tooltip: '手动添加标签',
              icon: Icon(Icons.add, size: 18, color: scheme.onSurfaceVariant),
              onPressed: onAdd,
            ),
          // 形态 B 优先于 spinner：徽标自身即入口（点击 → 一键唤醒宿主）。
          if (waitingHost)
            _WaitingHostBadge(onTap: _promptLaunchGoodhub)
          else if (running)
            const SizedBox(
              width: 18,
              height: 18,
              child: Padding(
                padding: EdgeInsets.all(2),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
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

    // 灵感区换骑框签（detail-visual-hierarchy §2 拍板）：与公共区统一为
    // 全页一套「签名式分区」语言，消除 labelMedium 裸灰小字与正文的混淆。
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 摘要（AI 产出，可刷新重生成）
          SectionLegendCard(
            legend: '摘要',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sectionActions(
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
                  running: _summarizeRunning && !_instantRunning,
                  waitingHost: _summarizeWaiting,
                  onInstant: canProcess ? _runInstantSummary : null,
                ),
                // T2 即时摘要三态：加载骨架 → 预览卡（采用/忽略）→ 失败/无变化降级；
                // 非即时态回落既有展示（深度摘要 / 摄入期 TLDR 兜底 / 空态）。
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: _summaryInstantBody(summary, tldrFallback, hasSummary),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.md),
          // ── 标签（AI 提取 + 手动增删；AI 刷新按并集合并不冲掉手动标签）
          SectionLegendCard(
            legend: '标签',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sectionActions(
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
                  running: _tagsRunning,
                  waitingHost: _tagsWaiting,
                ),
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
          ),
          const SizedBox(height: Insets.md),
          // ── 模板产出（ai-template P2 + 呈现规约 §5）：
          // 无产出不挂空卡（规约 2 渐进披露：一行轻入口）；有产出才是完整骑框签卡。
          if (hasTemplateOutput)
            SectionLegendCard(
              legend: '模板产出',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 规约 4：显示所用模板名（单槽覆盖，用户须知道当前产出是谁的）
                      if (templateName != null) ...[
                        Icon(Icons.auto_awesome,
                            size: 14, color: scheme.onSurfaceVariant),
                        const SizedBox(width: Insets.xs),
                        Expanded(
                          child: Text(
                            '按「$templateName」生成',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ] else
                        const Spacer(),
                      // 规约 1：入口降权——18px 图标按钮，与摘要/标签 refresh 同权重；
                      // P0-2 卡内微观态：模板任务进行中显示 spinner；
                      // §3.12.3 形态 B：久未被认领时改挂可点徽标（替换 spinner）。
                      if (_templateWaiting)
                        _WaitingHostBadge(onTap: _promptLaunchGoodhub)
                      else if (_templateRunning)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: Padding(
                            padding: EdgeInsets.all(2),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        IconButton(
                          tooltip: stale ? '正文已修改，重新按模板处理' : '按模板处理',
                          icon: Icon(
                            Icons.auto_awesome,
                            size: 18,
                            color: canProcess
                                ? scheme.onSurfaceVariant
                                : scheme.outline,
                          ),
                          onPressed: canProcess ? _showTemplatePicker : null,
                        ),
                    ],
                  ),
                  // 规约 4：stale 明示（正文改后版本锚失配 = 产出可能过期）
                  if (stale)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Insets.xs),
                      child: Text(
                        '正文已修改，此产出可能过期',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ),
                  RichTextView(markdown: templateOutput, shrinkWrap: true),
                ],
              ),
            )
          else
            _templateEntryRow(),
        ],
      ),
    );
  }

  /// 模板处理轻入口（呈现规约 2：无产出不挂骑框签空卡，一行轻入口渐进披露）。
  Widget _templateEntryRow() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: InkWell(
        onTap: _showTemplatePicker,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: Insets.sm, horizontal: Insets.xs),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: Insets.sm),
              Text(
                '按模板处理',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              Icon(Icons.chevron_right, size: 16, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  /// 标签手动编辑（detail-two-zone.md §3 拍板 2026-10-01）：BottomSheet
  /// chips 编辑器，增删自由；保存走 UpdateItemCommand 整表替换（=用户
  /// 权威快照，空表保存即清空）；AI 刷新另走并集合并互不冲突。
  Future<void> _editTags() async {
    final result = await showTagEditor(context, initial: _item.tags);
    if (result == null) return;
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, tags: result),
        vaultContext: widget.vaultContext,
      ),
      '标签已保存',
    );
  }

  /// 内容生产模板（ai-template P2 + 呈现规约 3）：定制 BottomSheet 选择器——
  /// 名称 + 描述 + origin 徽标 + 模板库预览入口，页脚固定「原文不会被修改」。
  /// 已有产出时选中后确认覆盖（单槽覆盖必须明示，规约 4）。
  Future<void> _showTemplatePicker() async {
    final tpls = await widget.repo.listTemplates();
    if (!mounted) return;
    if (tpls.isEmpty) {
      _snack('还没有可用模板，请先让 AI 创建模板');
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) =>
          _TemplatePickerSheet(templates: tpls, repo: widget.repo),
    );
    if (chosen == null || !mounted) return;
    if (_item.templateOutput?.trim().isNotEmpty ?? false) {
      final ok = await confirmDialog(
        context,
        title: '覆盖当前模板产出',
        content: '该条目已有一份模板产出，用新模板处理将覆盖它。继续？',
        confirmText: '继续',
      );
      if (!ok || !mounted) return;
    }
    await _run(
      () => widget.handler.execute(
        TemplateApplyCommand(_item.id!, chosen),
        vaultContext: widget.vaultContext,
      ),
      '已提交，待 AI 按模板处理',
    );
  }

  /// 灵感区：人的碎片想法（P1-6 修订拍板：输入改 **BottomSheet**，不做
  /// Sliver 内原地形变——长 Sliver 流内动态高度 + 软键盘 = 抖动跳屏陷阱）。
  /// 卡内只做展示：有内容显文本 + 编辑图标；空态一行轻入口。点按呼出
  /// 键盘跟随浮层，保存经 UpdateItemCommand 落库后回填卡片。
  Widget _inspirationTextArea() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = _item.inspirationMd?.trim() ?? '';
    final hasText = text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: SectionLegendCard(
        legend: '灵感',
        child: hasText
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '编辑灵感',
                      icon: Icon(Icons.edit_outlined,
                          size: 18, color: scheme.onSurfaceVariant),
                      onPressed: _showInspirationSheet,
                    ),
                  ),
                  SelectableText(
                    text,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              )
            : InkWell(
                onTap: _showInspirationSheet,
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: Insets.sm, horizontal: Insets.xs),
                  child: Row(
                    children: [
                      Icon(Icons.edit_note_outlined,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: Insets.sm),
                      Text(
                        '写点灵感…',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const Spacer(),
                      Icon(Icons.chevron_right, size: 16, color: scheme.outline),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// 灵感输入浮层（P1-6）：键盘跟随（isScrollControlled + viewInsets 内边距），
  /// 保存显式按钮（不再失焦即存——浮层语义下「取消=不改动」更可预期）。
  Future<void> _showInspirationSheet() async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _InspirationSheet(initial: _item.inspirationMd ?? ''),
    );
    if (!mounted || saved == null) return;
    if (saved.trim() == (_item.inspirationMd ?? '').trim()) {
      return; // 未改动不空耗乐观锁版本
    }
    await _run(
      () => widget.handler.execute(
        UpdateItemCommand(id: _item.id!, inspirationMd: saved.trim()),
        vaultContext: widget.vaultContext,
      ),
      '已记下',
    );
  }

  Widget _inspirationEmpty(String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.outline),
    );
  }

  /// 附录章节（派生内容）：**轻分隔线 + 微标题 + 正文同款排版**，不叠卡片边框
  /// （P0-1 修订拍板：译文是全量正文镜像，不进骑框签卡——万字长文套卡即畸形；
  /// 保持与正文一致的全宽无框阅读基线，仅以分隔线划界）。
  Widget _appendix(String title, String body) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, thickness: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: Insets.md),
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
  /// mymind 形态（ui-design §4.3）：居中、更弱化（outline 色，仅存档感）。
  Widget _sourceLine() {
    // 无标题态时间已占标题位（detail-visual-hierarchy §3 拍板去重），
    // 元信息行不再重复展示。
    final untitled = _item.humanTitle?.isNotEmpty != true;
    final parts = <String>[
      if (_item.sourceApp?.isNotEmpty ?? false) _item.sourceApp!,
      if (!untitled) _fmtDate(_item.createdAt),
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

  /// 无标题态的时间标题（detail-visual-hierarchy §3 拍板）：绝对短格式——
  /// 严禁相对时间（标题位会过期）；跨年带年份。用户标题优先，时间退元信息行。
  String get _timeTitle {
    final d = DateTime.fromMillisecondsSinceEpoch(_item.createdAt);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return d.year == DateTime.now().year
        ? '${d.month}月${d.day}日 $hh:$mm'
        : '${d.year}年${d.month}月${d.day}日';
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

/// 标签编辑已抽共享组件 `lib/ui/tag_editor_sheet.dart`（动词→容器词汇表：
/// 「编辑一组小项」唯一容器，便签作曲器同用）。

/// 模板选择 BottomSheet（ai-template.md §5 呈现规约 3）：行 = 模板名 + 描述 +
/// origin 徽标（AI 托管/官方）；页头「模板库预览」入口（接只读预览页）；
/// 页脚固定「原文不会被修改」——用户核心顾虑在决策点明示。
class _TemplatePickerSheet extends StatelessWidget {
  const _TemplatePickerSheet({required this.templates, required this.repo});

  final List<Template> templates;

  /// 详情页同一 Repository 实例（「模板库预览」按钮复用，零新开数据面）。
  final Repository repo;

  /// origin → 人类语言（ADR：管理权归 AI，人类须知道模板是谁托管的）。
  static String _originLabel(String origin) => switch (origin) {
        'official' => '官方',
        'user' => '我的',
        _ => 'AI 托管',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.lg, Insets.lg, Insets.sm, Insets.sm),
            child: Row(
              children: [
                Text('按模板处理', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => TemplatePreviewPage(repo: repo),
                    ),
                  ),
                  child: const Text('模板库预览'),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: templates.length,
              itemBuilder: (ctx, i) {
                final t = templates[i];
                final desc = t.description?.trim() ?? '';
                return ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(t.name),
                  subtitle: desc.isEmpty
                      ? Text('${_originLabel(t.origin)} · ${t.workspaceId.substring(0, 8)}')
                      : Text('$desc\n${_originLabel(t.origin)}'),
                  isThreeLine: desc.isNotEmpty,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(ctx, t.id),
                );
              },
            ),
          ),
          // 页脚固定明示：只追加语义的用户承诺（呈现规约 3）
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    '按模板处理会交由 AI 生成新内容，你的原文不会被修改',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 灵感输入浮层（P1-6 修订拍板：Sliver 内不做事地动态形变，输入全部收进
/// 键盘跟随浮层）：显式「保存」按钮取代失焦即存——浮层语义下「取消=不改动」
/// 更可预期；返回非空 = 用户确认保存（未改动由页面侧 diff 跳过写入）。
class _InspirationSheet extends StatefulWidget {
  const _InspirationSheet({required this.initial});

  final String initial;

  @override
  State<_InspirationSheet> createState() => _InspirationSheetState();
}

class _InspirationSheetState extends State<_InspirationSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 键盘跟随：首帧后请求焦点，软键盘弹出与浮层抬升同窗
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 键盘跟随：浮层底边距 = 当前键盘高度
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('灵感', style: theme.textTheme.titleMedium),
              const SizedBox(height: Insets.md),
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                minLines: 4,
                maxLines: 10,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '写下你的灵感…',
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerLow,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.md),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: Insets.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: Insets.sm),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _ctrl.text),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
