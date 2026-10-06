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
import '../ai/subtitle.dart' show AsrCue, parseSrtVtt;
import '../ai/workflow.dart' show WorkflowStep;

import '../data/block_artifacts.dart'
    show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import '../doc/attach.dart';
import '../doc/rich_text.dart';
import '../ui/confirm_dialog.dart';
import '../ui/content_card.dart' show ContentCard;
import '../ui/toast.dart';
import '../ui/overflow_sheet.dart';
import '../ui/tag_editor_sheet.dart';

import '../models/item.dart';
import '../media/block_media.dart';
import '../models/annotation.dart';
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
  StreamSubscription<AppLifecycleState>? _lifecycleSub;

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

  /// 机器态开关：由 AppBar `⋯` 菜单控制（双态入口保留但降权，不在正文流里常驻）。
  bool _machineMode = false;

  /// 机器码全局开关（设置页，默认关闭，2026-10-02 拍板）：关闭时 `⋯` 菜单
  /// 不出现「机器码」项——普通人无入口，但双态呈现能力仍可被 AI/MCP 产出。
  bool _machineModeEnabled = false;

  /// 灵感区 AI 产出区已改平行并置（见 _aiOutputSection），无页签状态。

  /// 灵感区文本编辑控制器（用户私密碎片，失焦即存——速记条同款语义）。
  final _inspirationCtrl = TextEditingController();

  /// 分享截图渲染边界（detail-two-zone.md §6：复用页面既有 RepaintBoundary）。
  final _bodyBoundaryKey = GlobalKey();

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
    // §8.3：dispose 是最后一道 flush 点——先 flush 完再 dispose 控制器
    // （反过来会把 _disposed 置真，令 flush 的落库回调整体空转）。
    final ai = _aiSession;
    if (ai != null) unawaited(ai.flush().whenComplete(ai.dispose));
    _audioPlayback.dispose();
    // 灵感区失焦即存，dispose 兜底最后一笔（速记条同款语义）
    _saveInspiration();
    _inspirationCtrl.dispose();
    _titleCtrl.dispose();
    _titleFocus.dispose();
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
    final fresh = await widget.repo.byId(_item.id!, includeDeleted: true, includeVault: true);
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
    for (final a in arts) {
      kinds.add(a.kind);
      if (a.text?.trim().isNotEmpty ?? false) text[a.kind] = a.text!;
      if (a.filePath?.isNotEmpty ?? false) files[a.kind] = a.filePath!;
      // 耗时归卡头（§4 三段式），摘要行只留 kind 自身语义——两处都放会重复
      final elapsed = a.elapsedMs; // 执行侧实测（queue_consumer 注入）
      if (elapsed != null) elapsedMs[a.kind] = elapsed;
      final cues = a.cueCount; // 解码在数据层（arch-guard R2：UI 不内联 jsonDecode）
      final summary = switch (a.kind) {
        BlockArtifactKind.subtitle => cues == null ? null : '$cues 段',
        BlockArtifactKind.audioFile => a.filePath?.split('/').last,
        _ => cues == null ? null : '$cues 段',
      };
      // 空摘要不写进 meta：产物卡会把它当有效摘要行渲染成空白中部
      if (summary != null && summary.isNotEmpty) meta[a.kind] = summary;
    }
    return BlockArtifactsView(
      kinds: kinds,
      text: text,
      meta: meta,
      filePath: files,
      elapsedMs: elapsedMs,
    );
  }

  /// 执行工作流步骤：组装 block 命令入队（与 UI 顶级按钮 / MCP 同源，R2）→
  /// 等任务落定 → 按任务状态返回成败（产物是否落库由页面重载后从表读，§3.3）。
  Future<bool> _runWorkflowStep(WorkflowStep step, String blockKey, String? sourceKind) async {
    final id = _item.id!;
    final head = 'block_${step.id}';
    if (step.id == 'translate') {
      // 入队前预检：与条目级翻译同口径（引擎不可用不入队空耗）
      final caps = widget.caps;
      if (!caps.translationEnabled) {
        _snack('翻译已关闭：设置 → 翻译 可开启');
        return false;
      }
      caps.router?.reset();
      if (!await caps.checkTranslationAvailable()) {
        final reason = await caps.translationUnavailableReason();
        _snack('无法翻译：${reason ?? '无可用翻译引擎'}（设置 → 翻译 可下载语言包）');
        return false;
      }
      // 同文预检（2026-10-06 拍板）：入队前判源产物语言，源语==目标语 → 提示
      // 「无须翻译」，不入队也不算失败（成功路径的零工作分支）；引擎侧同判定
      // （completed+note）作兜底双保险，见 _runWorkflowStep 落定分支。
      final sourceText = sourceKind != null
          ? await _blockArtifactText(blockKey, sourceKind)
          : null;
      if (sourceText != null && detectSourceLanguage(sourceText) == caps.targetLang) {
        _snack('源文本已是${languageLabel(caps.targetLang)}，无须翻译');
        return false;
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
        return false; // 不可达：spec 编译期封闭
    }
    try {
      await widget.handler.execute(command, vaultContext: widget.vaultContext);
    } on ActionException catch (e) {
      _snack(e.message);
      return false;
    }
    final (ok, note) = await _waitForBlockTask(id, head, blockKey);
    // 同文兜底提示（引擎判定 completed 无产物，2026-10-06 拍板「这也算成功」）：
    // 必须把原因转给用户，不能看起来像静默失败（R1 同一份状态）。
    // 匹配「需翻译」同时覆盖无须/无需两种历史措辞（存量任务行）。
    if (ok && mounted && step.id == 'translate' && (note?.contains('需翻译') ?? false)) {
      _snack(note!);
    }
    return ok;
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
                          slivers: [
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
                                        : ItemViewTemplate(
                                            item: _item,
                                            machineMode: _machineMode,
                                          ).bodySlivers(context)),
                                  if (!_editing) ...[
                                    SliverToBoxAdapter(
                                      child: _attachStatusLine(),
                                    ),
                                    // 灵感区（ui-spec §4.3 两区改版）：摘要/标签切换 + 刷新重生成
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

  /// 公共操作条（ui-spec §4.3 两区改版）：全类型固定 5 项，连成一个**无分隔线的
  /// 整体胶囊**——编辑 / 分享 / ⋯ / 工作区 / 删除（与全站底栏同款样式）。
  /// - 编辑↔保存按态切换（label 即实际行为）；分享 = 内容导出链（离屏截图 /
  ///   PDF，按内容分流），**唯一分享路径**（菜单里的纯文本直分享已移除）；
  /// - 删除红色 + 二次确认，已由 `⋯` 移回底栏常驻连接组（单一入口）；
  /// - 摘要与标签已移入灵感区（`_inspirationSection`），不占底栏；`⋯` 面板仅收
  ///   权限开关（保险箱/对AI可见/允许AI编辑/机器码）。
  ///
  /// Wrap 而非 Row：本机逻辑屏宽仅 331dp（1272px / DPR 3.84），Row 溢出在
  /// 顶栏标题（长按原地编辑，2026-10-02 拍板）：编辑态为 TextField，否则为
  /// 可长按文本。随 SliverAppBar 滚动隐显。
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
  /// 公共操作条（ui-spec §4.3）：编辑 / 分享 / ⋯ / 工作区 / 删除 五个按钮连成
  /// **一个无分隔线的整体胶囊**（与全站底栏同款样式：surfaceContainerHigh 底 +
  /// Radii.lg 圆角），项间不再各自分立。编辑↔保存按态切换（label 即实际行为）；
  /// 分享为唯一导出入口；删除红色 + 二次确认；`⋯` 仅收权限开关（保险箱/对AI可见/
  /// 允许AI编辑/机器码），单一入口不重复。
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
                _barCell(
                  icon: Icons.workspaces_outlined,
                  label: '工作区',
                  onPressed: _workspaceHint,
                ),
                _barCell(
                  icon: Icons.delete_outline,
                  label: '删除',
                  danger: true,
                  onPressed: _confirmDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底栏连接胶囊内的单个点击单元（mymind 形态，ui-spec §4.3）：icon + label 横排，
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

  /// 机器态开关（入口对人类隐藏，见 AppBar 标题长按）：双态呈现能力保留，
  /// 只是不给普通用户按钮（2026-10-01 拍板）。
  void _toggleMachineMode() => setState(() => _machineMode = !_machineMode);

  /// 重分类（方向二拍板 2026-10-05：人工全放开）——类型选择器 + 跨形态
  /// 后果确认（媒体↔文本转移改变详情页渲染形态与 AI 管线路由，须明示）。
  Future<void> _reclassify() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('重分类为'),
        children: [
          for (final t in InboxItem.allTypes)
            if (t != _item.itemType)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, t),
                child: Text(ContentCard.labelOf(t)),
              ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    const mediaTypes = {
      InboxItem.typeImage,
      InboxItem.typeVideo,
      InboxItem.typeAudio,
    };
    final fromMedia = mediaTypes.contains(_item.itemType);
    final toMedia = mediaTypes.contains(chosen);
    if (fromMedia != toMedia) {
      final ok = await confirmDialog(
        context,
        title: '改为「${ContentCard.labelOf(chosen)}」？',
        content: fromMedia
            ? '原${ContentCard.labelOf(_item.itemType)}附件将不再以播放器/图片形态显示，AI 处理也按新类型执行。'
            : '新类型以媒体文件为主体（当前无附件文件时详情页将显示缺失占位），正文转为附属内容。',
        confirmText: '重分类',
      );
      if (!ok) return;
    }
    if (!mounted) return;
    await _run(
      () => widget.handler.execute(
        ReclassifyCommand(_item.id!, chosen),
        vaultContext: widget.vaultContext,
      ),
      '已重分类为${ContentCard.labelOf(chosen)}',
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
        machineMode: _machineMode,
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
      onMachineToggle: _toggleMachineMode,
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
      onReclassify: _reclassify,
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
        // 截图路径按勾选真实裁剪：置 _shareScope → 等排版落定 → 截图 → 还原
        //（2026-10-05 修：此前 scope 拿到即弃，勾选零作用、灵感区照进产物）。
        setState(() => _shareScope = scope);
        await WidgetsBinding.instance.endOfFrame;
        await WidgetsBinding.instance.endOfFrame;
        try {
          try {
            // 复用页面既有 RepaintBoundary（Theme 红线）；超长降级 PDF
            path = await BodyScreenshotRenderer.renderToFile(_bodyBoundaryKey);
          } on TooTallException {
            path = null;
          }
        } finally {
          if (mounted) setState(() => _shareScope = null);
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
    final hasTags = _item.tags.isNotEmpty;

    // 分区动作行（卡内右上角）：内容语义归 SectionLegendCard 签名，按钮只管操作。
    Widget sectionActions(
      String refreshTooltip,
      VoidCallback? onRefresh, {
      VoidCallback? onAdd,
    }) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
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
                ),
                if (hasSummary)
                  RichTextView(markdown: summary, shrinkWrap: true)
                else
                  _inspirationEmpty('还没有摘要，点右上刷新生成'),
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
        ],
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

  /// 灵感区：人的碎片想法，可编辑文本区（点即聚焦、失焦即存）。
  Widget _inspirationTextArea() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: SectionLegendCard(
        legend: '灵感',
        child: TextField(
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
      ),
    );
  }

  Widget _inspirationEmpty(String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.outline),
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
