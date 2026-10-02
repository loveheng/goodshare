import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../ai/capability.dart';

import '../data/repository.dart';
import '../doc/attach.dart';

import '../doc/edit_session.dart';
import '../models/item.dart';
import '../service/settings_store.dart';
import '../ui/annotation_editor_page.dart';
import '../ui/clip_editor_sheet.dart';
import '../ui/audio_playback_service.dart';
import '../ui/body_screenshot.dart';
import '../ui/block_capability_host.dart';

import '../ui/block_text_page.dart';

import '../ui/item_view_template.dart';
import '../ui/pdf_export.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/rich_text_view.dart';
import '../ui/share_scope_sheet.dart';
import '../ui/tokens.dart';
import 'package:file_picker/file_picker.dart';
import '../doc/rich_text.dart';
import '../share/attachments.dart';
import '../ui/media_blocks.dart';
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

  /// 就地编辑会话（脊柱 EditSession）：进入编辑态创建，退出 / 提交后销毁。
  EditSession? _editSession;
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
  }

  @override
  void dispose() {
    _lifecycleSub?.cancel();
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

  /// 解锁门禁：合并收集条目默认 `editLocked`，动作层直接拒绝 `update`（设计 §4.9，
  /// UI 置灰只是快路径不是安全边界）。故进入任何编辑前先 `unlock_edit`，走二次确认
  /// + 触觉反馈；仍锁定（命令被拒）即返回 false 止步，不让用户进编辑器后才撞
  /// 「保存被拒」。返回 true = 已解锁或本就未锁定，可继续编辑。
  Future<bool> _ensureUnlocked() async {
    if (!_item.editLocked) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除编辑锁定？'),
        content: const Text(
          '这条是合并收集的条目，默认锁定以防误改。解除后即可编辑。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解除并编辑'),
          ),
        ],
      ),
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

  /// 进入编辑态：先过解锁（合并模式条目），再建就地编辑会话（脊柱）。
  Future<void> _enterEdit() async {
    if (!await _ensureUnlocked()) return;
    setState(() {
      _editSession = EditSession(_item.bodyText);
      _editing = true;
    });
  }

  /// 退出编辑态（不提交）：会话丢弃。
  void _exitEdit() {
    setState(() {
      _editSession = null;
      _editing = false;
    });
  }

  /// 丢弃确认：编辑态下返回键 / 侧滑被拦截时询问（危险操作二次确认口径）。
  Future<bool> _confirmDiscardEdit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃未保存的改动？'),
        content: const Text('退出编辑态后，本次编辑的内容不会保存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 提交：会话序列化 → `UpdateItemCommand(humanMd)` → 回读态。
  ///
  /// **无改动时明说「无改动」，不假装成功**——否则用户以为存过了。
  Future<void> _commitEdit() async {
    final session = _editSession;
    if (session == null) return;
    final md = session.markdown;
    setState(() {
      _editSession = null;
      _editing = false;
    });
    if (md == _item.bodyText) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无改动')));
      }
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

  /// 就地编辑态正文：替换只读 `ItemViewTemplate.bodySlivers` 为可编辑渲染
  /// （消费 [EditSession]，逐块 TextField + 块级工具栏）。TL;DR / 标签 / 灵感区在
  /// 编辑态不展示——本拍板只改正文，退出编辑后照常渲染。
  List<Widget> _editBodySlivers(EditSession session) => [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '就地编辑：修改正文块后点「保存」提交',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _EditBody(key: ValueKey(session), session: session),
        ),
      ];

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
  /// 或打开编辑工具流，切片/提取音轨/字幕导出为媒体工具流。
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
      case 'extract_audio':
        await extractAudioTrack(context, _item);
      case 'export_subtitle':
        await exportSubtitles(context, id);
    }
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
              SliverAppBar(
                automaticallyImplyLeading: false,
                floating: true,
                snap: true,
                backgroundColor: Theme.of(context).colorScheme.surface,
                elevation: 0,
                titleSpacing: Insets.md,
                title: _buildTitle(),
              ),
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  Insets.xl,
                  Insets.md,
                  Insets.xl,
                  0,
                ),
              ),
              ...(_editing && _editSession != null
                  ? _editBodySlivers(_editSession!)
                  : ItemViewTemplate(
                      item: _item,
                      machineMode: _machineMode,
                    ).bodySlivers(context)),
              if (!_editing) ...[
                SliverToBoxAdapter(child: _attachStatusLine()),
                // 灵感区（ui-spec §4.3 两区改版）：摘要/标签切换 + 刷新重生成
                SliverToBoxAdapter(child: _inspirationSection()),
                if (_item.hasTranslation)
                  SliverToBoxAdapter(
                    child: _appendix('译文', _item.translatedMd!),
                  ),
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
          child: _actionBar(),
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

  /// 公共操作条（ui-spec §4.3 两区改版 + 2026-10-01 重划）：全类型固定
  /// 3 项——**编辑 / 工作区 / 分享**。
  /// - 删除移入 `⋯` 菜单（危险操作不占底栏常驻位，且带二次确认）；
  /// - 分享 = 内容导出链（离屏截图 / PDF，按内容分流），**唯一分享路径**
  ///   （菜单里的纯文本直分享已移除，同一动作不设两个入口）；
  /// - 摘要与标签已移入灵感区（`_inspirationSection`），不再占底栏。
  ///
  /// Wrap 而非 Row：本机逻辑屏宽仅 331dp（1272px / DPR 3.84），Row 溢出在
  /// 顶栏标题（长按原地编辑，2026-10-02 拍板）：编辑态为 TextField，否则为
  /// 可长按文本。随 SliverAppBar 滚动隐显。
  Widget _buildTitle() => _editingTitle
      ? TextField(
          controller: _titleCtrl,
          focusNode: _titleFocus,
          autofocus: true,
          maxLines: 1,
          style: Theme.of(context).textTheme.titleLarge,
          decoration: const InputDecoration.collapsed(hintText: '标题'),
          onSubmitted: (_) => _commitTitleEdit(),
        )
      : GestureDetector(
          onLongPress: _editTitle,
          behavior: HitTestBehavior.opaque,
          child: Semantics(
            button: true,
            label: '标题，长按可修改标题',
            child: Text(
              _item.humanTitle?.isNotEmpty == true ? _item.humanTitle! : '未命名',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );

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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 编辑/保存：锁定条目显示「编辑」（点按先解锁再进编辑器）；
              // 解锁后（含合并收集条目解除锁定、普通条目本就未锁定）显示「保存」，
              // 读态=「编辑」（进入编辑态），编辑态=「保存」（提交落库）——**label 即实际行为**。
              // 修正此前 label 由 editLocked 决定、但两者都打开块编辑器的名实不符。
              _barAction(
                icon: _editing ? Icons.save_outlined : Icons.edit_outlined,
                label: _editing ? '保存' : '编辑',
                onPressed: _onPrimaryAction,
              ),
              // 「⋯」溢出（分享/删除/机器码/保险箱）置底栏中间（2026-10-02 拍板：
              // 横向三点 + 居中；分享与低频/危险同收溢出，底栏只留 编辑/工作区 常显）。
              _overflowBarButton(),
              _barAction(
                icon: Icons.workspaces_outlined,
                label: '工作区',
                onPressed: _workspaceHint,
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
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: ShapeDecoration(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: fg),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium
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

  /// `⋯` 底栏第 4 项（2026-10-02 拍板下沉底栏，居中）：点击后从底部升起 mymind 风格
  /// 功能面板（非 Material 浮层），含 分享 · 删除 · 机器码 · 保险箱。面板用错峰入场
  /// 动画（逐项淡入 + 上移 + 微缩放）体现「功能从底部浮现」的轻盈感，圆角面板 +
  /// 柔阴影 + 点击遮罩关闭，整体去 Material 列表范式。
  Widget _overflowBarButton() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _openOverflowSheet,
      customBorder: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: ShapeDecoration(
          color: scheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
        ),
        child: Icon(
          Icons.more_horiz,
          size: 22,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 从底部升起 mymind 风格功能面板（见 `_OverflowSheet`）。分享/删除/机器码/保险箱
  /// 按当前态条件收录（机器码仅开关开；保险箱仅未入箱或 vaultContext 下可移出）。
  void _openOverflowSheet() {
    final items = <_SheetItem>[
      _SheetItem(Icons.share_outlined, '分享', () {
        _exportPdf();
      }),
      if (!_item.isVault || widget.vaultContext)
        _SheetItem(Icons.lock_outline, !_item.isVault ? '移入保险箱' : '移出保险箱', () {
          if (!_item.isVault) {
            _run(
              () => widget.handler.execute(SetVaultCommand(_item.id!, true)),
              '已移入保险箱',
            );
          } else {
            _run(
              () => widget.handler.execute(
                SetVaultCommand(_item.id!, false),
                vaultContext: true,
              ),
              '已移出保险箱',
            );
          }
        }),
      _SheetItem(Icons.delete_outline, '删除', () {
        _confirmDelete();
      }, danger: true),
      if (_machineModeEnabled)
        _SheetItem(Icons.terminal_outlined, '机器码', () {
          _toggleMachineMode();
        }, checked: _machineMode),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha:0.35),
      builder: (ctx) => _OverflowSheet(items: items),
    );
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

/// `⋯` 功能面板的单列条目描述（文件级私有，供 `_OverflowSheet` 使用）。
class _SheetItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool checked;
  const _SheetItem(this.icon, this.label, this.onTap,
      {this.danger = false, this.checked = false});
}

/// mymind 风格功能面板：从底部升起，圆角 + 柔阴影；条目错峰淡入 / 上移 / 微缩放。
class _OverflowSheet extends StatefulWidget {
  final List<_SheetItem> items;
  const _OverflowSheet({required this.items});

  @override
  State<_OverflowSheet> createState() => _OverflowSheetState();
}

class _OverflowSheetState extends State<_OverflowSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _tile(int index, _SheetItem item) {
    final start = (index * 0.08).clamp(0.0, 0.6);
    final end = (start + 0.5).clamp(0.0, 1.0);
    final curve = Interval(start, end, curve: Curves.easeOutCubic);
    final slide = Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: curve));
    final fade = Tween<double>(begin: 0, end: 1)
        .animate(CurvedAnimation(parent: _ctrl, curve: curve));
    final scale = Tween<double>(begin: 0.92, end: 1)
        .animate(CurvedAnimation(parent: _ctrl, curve: curve));
    final scheme = Theme.of(context).colorScheme;
    final iconColor = item.danger ? scheme.error : scheme.onSurfaceVariant;
    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: slide,
        child: ScaleTransition(
          scale: scale,
          child: InkWell(
            onTap: () {
              Navigator.pop(context);
              item.onTap();
            },
            borderRadius: BorderRadius.circular(Radii.lg),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, size: 26, color: iconColor),
                  const SizedBox(height: 8),
                  Text(
                    item.label,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(
                          color: item.danger ? scheme.error : scheme.onSurface,
                        ),
                  ),
                  if (item.checked)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Icon(Icons.check, size: 14, color: scheme.primary),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.md),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
              Insets.md, Insets.md, Insets.md, Insets.lg),
          decoration: ShapeDecoration(
            color: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha:0.18),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: Insets.md),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: _tile(i, widget.items[i]),
                      ),
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

/// 就地编辑正文载体：逐块 TextField + 块级工具栏，变更**全部**经
/// [EditSession.apply] 走统一事务入口（edit_session.dart 设计红线）。
///
/// - 文本编辑 → [CommitTextOp]；清空某块即删除（rebuildBlock 返回 null 兜底）。
/// - 块级结构操作（上移/下移/插入/删除）→ 对应 [EditOp]，应用后整体重同步控制器，
///   保证 index 与 `blocks` 始终对齐（结构变更后旧控制器失效，必须重建）。
/// - 单项待办块附带勾选框（[EditBlock.todoDone] 经 [CommitTextOp.todoDone] 回写）。
///
/// 本载体替代旧 `block_editor_dialog` 的全部正文编辑能力（2026-10-02 形态收敛）。
/// 粘贴拆块拦截器：检测单次粘贴事件（含空行 `\n\n` 的整块插入，区别于逐字输入），
/// 拒绝本次字符落入单块，延迟到帧后由 [_EditBodyState._splitPasted] 经 [SplitOp]
/// 拆块并整体重同步控制器。仅段落/引用块会被拆，其它块由 SplitOp 原样提交。
/// 编辑态媒体块编辑器：在 `TextField` 之外提供「预览 + 标签 + 替换媒体」。
///
/// 护栏（用户拍板）：可视状态 100% 派生自传入的 [block]/[labelController]，不持有
/// 任何本地私有状态（无 `_currentUrl`）；替换成功经 [onReplace] 上抛，由顶层走
/// [ReplaceMediaOp] 经 [EditSession.apply] 落事务——取消即整体回滚，不与文字修改
/// 形成脏状态分裂。
class MediaBlockEditor extends StatelessWidget {
  const MediaBlockEditor({
    super.key,
    required this.block,
    required this.labelController,
    required this.onLabelChanged,
    required this.onReplace,
  });

  final RichBlock block;
  final TextEditingController labelController;
  final void Function(String) onLabelChanged;
  final void Function(String url) onReplace;

  Future<void> _pickAndReplace(BuildContext context) async {
    final type = switch (block) {
      ImageBlock() => FileType.image,
      AudioBlock() => FileType.audio,
      VideoBlock() => FileType.video,
      _ => FileType.any,
    };
    final files = await FilePicker.pickFiles(type: type);
    if (files.isEmpty) return; // 用户取消
    final path = files.single.path;
    if (path == null) return;
    final saved = await copyToAppDir(path);
    if (saved == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('媒体文件保存失败')));
      }
      return;
    }
    final url = await toLocalMediaUrl(saved);
    onReplace(url);
  }

  @override
  Widget build(BuildContext context) {
    final preview = switch (block) {
      ImageBlock() => InlineMediaImage(block: block as ImageBlock),
      AudioBlock() => InlineMediaAudio(block: block as AudioBlock),
      VideoBlock() => InlineMediaVideo(block: block as VideoBlock),
      _ => const SizedBox.shrink(),
    };
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: preview,
        ),
        const SizedBox(height: 6),
        TextField(
          controller: labelController,
          onChanged: onLabelChanged,
          maxLines: null,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.all(10),
            hintText: switch (block) {
              ImageBlock() => '图片说明（alt）',
              AudioBlock() => '音频标签',
              VideoBlock() => '视频标签',
              _ => null,
            },
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _pickAndReplace(context),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('替换媒体'),
          ),
        ),
        const SizedBox(height: 2),
        Divider(color: scheme.outlineVariant),
      ],
    );
  }
}

class _PasteSplitFormatter extends TextInputFormatter {
  _PasteSplitFormatter(this.index, this.state);

  final int index;
  final _EditBodyState state;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // 单块编辑框内不存在合法 `\n\n`（段落为行内、引用仅以单 `\n` 连接子段），
    // 故出现空行即判定为粘贴（并兼容 Windows 的 \r\n\r\n）。
    final text = newValue.text.replaceAll('\r\n', '\n');
    if (!text.contains(RegExp(r'\n[ \t]*\n'))) return newValue;
    // 拒绝本次变更，避免多段文本短暂落入单块；帧后由会话事务拆块重同步。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state._splitPasted(index, text);
    });
    return oldValue;
  }
}

class _EditBody extends StatefulWidget {
  const _EditBody({required super.key, required this.session});

  final EditSession session;

  @override
  State<_EditBody> createState() => _EditBodyState();
}

class _EditBodyState extends State<_EditBody> {
  late List<TextEditingController> _controllers = _buildControllers();

  List<TextEditingController> _buildControllers() => [
        for (var i = 0; i < widget.session.blocks.length; i++)
          TextEditingController(text: widget.session.editTextOf(i))
      ];

  /// 重同步控制器到最新 `blocks`（结构变更后调用）。
  void _resync() {
    for (final c in _controllers) {
      c.dispose();
    }
    _controllers = _buildControllers();
  }

  /// 文本编辑：逐字经 [CommitTextOp] 落会话；仅当清空块致 blocks 数变化时重同步
  /// （不逐字重同步，避免破坏光标）。
  void _onChanged(int i, String v) {
    widget.session.apply(CommitTextOp(i, v));
    if (widget.session.blocks.length != _controllers.length && mounted) {
      setState(_resync);
    }
  }

  /// 结构操作（上移/下移/插入/删除）：应用后整体重同步控制器。
  void _mutate(EditOp op) {
    widget.session.apply(op);
    if (mounted) setState(_resync);
  }

  /// 粘贴拆块：经 [SplitOp] 把整段粘贴文本按空行切成多块，再整体重同步控制器。
  void _splitPasted(int i, String full) {
    if (!mounted) return;
    widget.session.apply(SplitOp(i, full));
    setState(_resync);
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _toolbar(int i) {
    final n = widget.session.blocks.length;
    final block = widget.session.blocks[i];
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (block.todoDone != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                visualDensity: VisualDensity.compact,
                value: block.todoDone,
                onChanged: (v) {
                  block.todoDone = v ?? false;
                  widget.session.apply(
                    CommitTextOp(i, widget.session.editTextOf(i),
                        todoDone: v ?? false),
                  );
                  if (mounted) setState(() {});
                },
              ),
              Text('完成', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          tooltip: '上移',
          onPressed: i > 0 ? () => _mutate(MoveOp(i, -1)) : null,
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          tooltip: '下移',
          onPressed: i < n - 1 ? () => _mutate(MoveOp(i, 1)) : null,
          icon: const Icon(Icons.arrow_downward),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          tooltip: '在下方插入段落',
          onPressed: () => _mutate(InsertAfterOp(i)),
          icon: const Icon(Icons.add),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          tooltip: '删除块',
          onPressed: () => _mutate(DeleteOp(i)),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  /// 单个块的编辑载体：媒体块渲染 [MediaBlockEditor]（预览+标签+替换），
  /// 其余块保持 `TextField` 不变。两者均绑定 `ValueKey(blocks[i].id)`，
  /// 防结构变更（增删/移动/拆分）后 Element 错位复用。
  Widget _blockEditor(int i) {
    final id = widget.session.blocks[i].id;
    final block = widget.session.blocks[i].block;
    final isMedia =
        block is ImageBlock || block is AudioBlock || block is VideoBlock;
    final editor = isMedia
        ? MediaBlockEditor(
            key: ValueKey(id),
            block: block,
            labelController: _controllers[i],
            onLabelChanged: (v) => _onChanged(i, v),
            onReplace: (url) {
              widget.session.apply(ReplaceMediaOp(i, url));
              if (mounted) setState(() {});
            },
          )
        : TextField(
            key: ValueKey(id),
            controller: _controllers[i],
            maxLines: null,
            inputFormatters: [_PasteSplitFormatter(i, this)],
            onChanged: (v) => _onChanged(i, v),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(10),
            ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(i),
          const SizedBox(height: 4),
          editor,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < widget.session.blocks.length; i++) _blockEditor(i),
          if (widget.session.blocks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                '正文为空，点击下方添加段落',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          // 常驻「添加段落」：AppendOp；兼覆盖空正文无法起笔的缺口。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _mutate(AppendOp()),
                icon: const Icon(Icons.add),
                label: const Text('添加段落'),
              ),
            ),
          ),
        ],
      );
}
