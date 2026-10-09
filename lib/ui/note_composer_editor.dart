import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/lifecycle_manager.dart';
import 'toast.dart';
import 'package:image_picker/image_picker.dart';

import '../doc/rich_text.dart'
    show InlineMark, MediaSuffix, SpanListKind, SpanListRun, classifyMediaUrl;
import '../share/attachments.dart'
    show copyToAppDir, resolveLocalMediaSrc, toLocalMediaUrl;
import '../share/note_composer.dart' show NoteSegment;
import '../share/note_video_policy.dart';
import '../share/quick_note_span_codec.dart';
import '../share/quick_note_text_actions.dart'
    show deriveLineRuns, seedTextTruth, LineKindTarget;
import 'theme/block_presentation.dart' show BlockKind, blockPresentationOf, lineKindOf;
import 'audio_playback_service.dart';
import 'audio_record_sheet.dart';
import 'goodshare_image.dart';
import 'image_viewer.dart';
import 'confirm_dialog.dart';
import 'media_blocks.dart';
import 'note_video_capture_page.dart';
import 'span_text_controller.dart';
import '../share/note_seg.dart';
import 'composer_doc.dart';

/// 段模型（[NoteSeg]/[NoteTextSeg]/[NoteMediaSeg]/[NoteMediaKind]）与段↔草稿行
/// 序列化（[noteSegsToDraftRows]）原定义于本文件，拆解 P1b 迁至 [note_seg]；
/// 此处按需再导出，保持既有 widget 测试「import 本文件即用」零改动（段结构不变）。
export '../share/note_seg.dart';
import 'tag_editor_sheet.dart';
import 'tokens.dart';
import 'video_cover.dart';

/// 统一作曲编辑器（2026-10-03 编辑器统一拍板）：速记便签与详情页编辑态
/// **同一实现**——分段作曲层（光标处插媒体卡）+ 动作行工具层 + 全域拖动
/// 悬浮球格式转盘（四缘吸附），全程无 md 标记（所见即所得，序列化出口后移）。
///
/// 分层约束：本组件是**纯编辑器**——保存路由、草稿持久化、面板外壳均归宿主：
/// - 段变更 → [NoteComposerEditor.onDirty]（携带草稿行快照，宿主防抖落盘）
///   与 [NoteComposerEditor.onChanged]（轻量通知，宿主刷新内容感知 CTA 等）；
/// - 保存：宿主经 [NoteComposerEditorState.segs] / [NoteComposerEditorState.toNoteSegments]
///   取段序列自行序列化（速记走 CollectCommand/TextCollector，详情走 UpdateItemCommand）；
/// - 媒体替换（长按换文件/音频重录）为可选钩子 [NoteComposerEditor.onMediaReplace]：
///   详情页注入以保留既有能力，速记不传（与作曲页形态完全一致）。
///
/// 挂载约束：宿主必须给**有界高度**（Expanded/SizedBox）——作曲层 ListView
/// 与转盘面板的 Stack 挂载（bounded + hit-test）封装在本组件内部，宿主零感知。
class NoteComposerEditor extends StatefulWidget {
  const NoteComposerEditor({
    super.key,
    this.initialRows = const [],
    this.onDirty,
    this.onChanged,
    this.pendingTags,
    this.onPendingTagsChanged,
    this.onMediaReplace,
    this.audioController,
    this.hintText = '记点什么…',
  });

  /// 初始段（草稿行编码 `['t',md] / ['i',url,alt?] / ['a',url,label?] /
  /// ['v',url,label?]`，与 QuickNoteDraft/静态缓存同源）。空则起手一段文本。
  final List<List<String>> initialRows;

  /// 段变更（结构变更与文字变更都回调），携带草稿行快照——宿主自行决定
  /// 防抖/flush 时机（dispose 前最后一次回调即最新态，宿主可缓存兜底）。
  final void Function(List<List<String>> rows)? onDirty;

  /// 任意变更的轻量通知（宿主 setState 刷新内容感知等）。
  final VoidCallback? onChanged;

  /// 动作行标签按钮的当前挂签（配合 [onPendingTagsChanged]；回调为 null
  /// 时按钮整体隐藏——详情页标签走独立标签区）。
  final List<String>? pendingTags;
  final void Function(List<String> tags)? onPendingTagsChanged;

  /// 媒体替换钩子（详情页注入）：长按图/视频/音频卡 = 换文件 / 重录（统一
  /// 长按，2026-10-04 拍板）。钩子内自行改 [NoteMediaSeg.url]；返回后组件
  /// 统一标脏重渲染。
  final Future<void> Function(NoteMediaSeg seg)? onMediaReplace;

  /// 注入音频播放控制器（单实例红线：宿主页已有控制器时传入复用）；
  /// 缺省组件自建自毁（速记条场景）。
  final AudioPlaybackController? audioController;

  /// 首段空态提示语。
  final String hintText;

  @override
  State<NoteComposerEditor> createState() => NoteComposerEditorState();
}



/// 视频来源二选一（note-video.md §1）。
enum _VideoSource { album, camera }

/// 工具层固定高度（动作行单行图标；2026-10-04 四缘吸附拍板后格式行退役
/// ——悬浮球迁顶层 Stack 全域拖动，不再占常驻行位）。作曲层滚动视口底边
/// 按它上移让位——改这里必须同步考虑光标让位。
const double kComposerToolLayerHeight = 48;

/// 列表凹槽宽（文本段左侧画 • / 待办勾选框的留白）。**只有含列表行的文本段**
/// 才启用（无列表段直接返回原 TextField，保持既有排版逐像素不变）。
const double kListGutterWidth = 28;



/// 硬件键盘撤销/重做意图（挂编辑器顶层 Shortcuts，见 build）。
class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class NoteComposerEditorState extends State<NoteComposerEditor> {
  /// 内容引擎（拆解 P1b）：段序列 + 撤销栈 + 文本/结构编辑纯逻辑；State
  /// 只负责挂载/焦点/重建/落盘，经 [ComposerDoc] 反射 [EditOutcome]。
  late final ComposerDoc _doc;

  /// 切后台回来自动收盘（④）；统一订阅 AppLifecycleManager 广播（R6）。
  StreamSubscription<AppLifecycleState>? _lifecycleSub;

  /// 音频播放作用域：媒体卡复用 [MediaAudioBar]，但**不**自持 AudioPlayer
  ///（单实例红线）——宿主注入时复用宿主控制器，缺省自建自毁。
  AudioPlaybackController? _ownAudioCtl;
  AudioPlaybackController get _audioCtl =>
      widget.audioController ?? (_ownAudioCtl ??= AudioPlaybackController());

  /// 行内格式激活集（先选后打，与详情页同一拍板）：作用于激活段光标处
  /// **之后输入**的文字（多段 composer 无「聚焦块」概念，按光标所在段
  /// 作用，光标离开段即失效）。
  final Set<InlineMark> _activeMarks = {};

  /// 贴键浮层打样面板（问题#1 引导层·Step 3）显隐：点聚焦段侧轨 chip 展开，
  /// 选完/滚动/场景切换经 [_closeFormatDial] 收。
  bool _blockPanelOpen = false;

  bool _sending = false;

  /// 相册长视频「仍要添加」确认后暂存的落盘路径（>5min 非阻断流专用）。
  String? _pendingVideoPath;

  /// 动作行横滚区控制器（2026-10-08 拍板：钉住撤销/重做，其余横滚）。
  final ScrollController _toolScroll = ScrollController();

  /// 横滚区是否**真的**可滚（内容宽 > 视口）——决定右缘渐隐遮罩显隐：
  /// affordance 不许骗人（不能滚却画渐隐，会被读成「UI 被截断」）。
  bool _toolScrollable = false;

  @override
  void initState() {
    super.initState();
    _lifecycleSub = AppLifecycleManager.instance.states.listen((s) {
      if (s == AppLifecycleState.resumed) _closeFormatDial();
    }); // ④ 切后台回来自动收盘
    _doc = ComposerDoc(widget.initialRows); // 引擎构造即重建段序列 + 设撤销基线
    // 失焦自动闭合转盘：全局焦点变化 → 全场无焦点即武装延时器（期间回焦撤销）
    WidgetsBinding.instance.focusManager.addListener(_onFocusChanged);
    // 动作行横滚区：可滚性需布局后实测（首帧 + 视口变化双路刷新，见
    // [_syncToolScrollable]）。
    _toolScroll.addListener(_syncToolScrollable);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncToolScrollable());
  }

  /// 动作行横滚区可滚性刷新：只在真能滚时才显右缘渐隐。视口变化（旋转 / 键盘
  /// 起落 / 侧栏）由 [ScrollMetricsNotification] 转 post-frame 驱动——回调发生在
  /// build/layout 期，直接 setState 会撞断言。
  void _syncToolScrollable() {
    if (!_toolScroll.hasClients) return;
    final can = _toolScroll.position.maxScrollExtent > 1;
    if (can != _toolScrollable && mounted) setState(() => _toolScrollable = can);
  }

  /// 焦点变化 → 记录活跃段 id（活跃段真相源；无焦点段时不改写，保留上次值）。
  void _onFocusChanged() {
    for (final s in _doc.segs) {
      if (s is NoteTextSeg && s.focus.hasFocus) {
        _doc.activeSegId = s.id;
        break;
      }
    }
  }

  /// 外部意图收盘（返回键/拖动滚动/动作行/切后台，2026-10-05 拍板四路径）。
  void _closeFormatDial() {
    if (_blockPanelOpen && mounted) setState(() => _blockPanelOpen = false);
  }

  @override
  void dispose() {
    _lifecycleSub?.cancel();
    WidgetsBinding.instance.focusManager.removeListener(_onFocusChanged);
    _toolScroll.dispose();
    _doc.disposeAll();
    _ownAudioCtl?.dispose();
    super.dispose();
  }

  // ---------- 宿主接口 ----------

  /// 当前段序列（宿主保存时读取；勿持有跨帧引用）。
  List<NoteSeg> get segs => _doc.segs;

  /// 段层面是否「有东西」（媒体或非空文本；标签/待办等宿主级状态由宿主并）。
  bool get hasContent => _doc.segs.any(
    (s) =>
        s is NoteMediaSeg ||
        (s is NoteTextSeg && s.spans.plain.trim().isNotEmpty),
  );

  /// 保存用段模型（序列化出口后移：此刻才落 human_md 文本）。
  List<NoteSegment> toNoteSegments() => noteSegsToNoteSegments(_doc.segs);

  /// 草稿行快照重建段序列（宿主草稿恢复/保存后清空用；旧段全部释放，
  /// 不触发脏通知——装载不是用户变更）。
  /// 草稿行快照重建段序列（宿主草稿恢复/保存后清空用；旧段全部释放，
  /// 不触发脏通知——装载不是用户变更）。
  void loadRows(List<List<String>> rows) {
    for (final s in _doc.segs) {
      if (s is NoteTextSeg) s.dispose();
    }
    _doc.loadRows(rows); // 引擎重建段序列
    if (mounted) setState(() {});
  }

  /// 程序化整篇替换（AI 还原 / 恢复 AI 改动，ai-writeback-revert §8.4）：
  /// 在 [loadRows] 之上额外**清空撤销/重做栈**。
  ///
  /// 为什么必须清：程序化替换不是用户编辑，若保留旧栈，用户随后 `Ctrl+Z`
  /// 会把文本退回被替换掉的那个版本，而状态机并未捕捉这次回退 → 悬浮条说
  /// 「已还原」、正文却是 AI 版（UI 态与文本 mismatch）。清空是唯一确定性
  /// 做法；代价见设计稿 §8.4「已知产品折损」——AI 操作之前的原生打字历史
  /// 一并丢弃，MVP 接受（Roadmap 改插自定义 Undo Boundary 保留历史）。
  void replaceAll(List<List<String>> rows) {
    for (final s in _doc.segs) {
      if (s is NoteTextSeg) s.dispose();
    }
    _doc.replaceAll(rows); // 引擎清栈 + 重建
    if (mounted) setState(() {});
  }

  /// 焦点拉回写作区（无焦点段时落最后一段文本——宿主展开面板等场景）。
  void requestFocusFirst() {
    _doc.activeText?.focus.requestFocus();
  }

  // ---------- 内部：段序列管理 ----------








  void _undo() {
    _doc.undo();
    _applyOutcome(_doc.consumeOutcome());
  }

  void _redo() {
    _doc.redo();
    _applyOutcome(_doc.consumeOutcome());
  }

  /// 焦点所在文本段；无焦点回退最后一段文本（拍完照回来焦点归零的常态）。
  /// 当前活跃文本段 id：焦点变化由 [_onFocusChanged] 写入，替代 `hasFocus`
  /// 轮询——撤销快照与活跃段查表以此为唯一真相源（编辑器拆解 P1a）。
  NoteTextSeg? get _activeText => _doc.activeText;

  /// 段 id → 段对象（焦点反射按 id 定位，引擎不持有 FocusNode，拆解 P1b 边界）。
  NoteSeg? _segById(String id) {
    for (final s in _doc.segs) {
      if (s is NoteTextSeg && s.id == id) return s;
    }
    return null;
  }

  /// 把引擎 [EditOutcome] 反射为 UI 副作用：重建（结构变更/撤销钮翻转）、
  /// 焦点（经 segId 定位，绝不持有 FocusNode）、帧尾释放被并段、落盘/保存回调。
  /// 引擎只认 id/offset（拆解 P1b 边界）。
  void _applyOutcome(EditOutcome? out, {bool textEdited = false}) {
    if (out == null) return;
    if (out.clearActiveMarks) _activeMarks.clear();
    final rebuild = out.needsRebuild || out.undoRedoChanged;
    if (rebuild && mounted) setState(() {});
    final focusSegId = out.focusSegId;
    if (focusSegId != null) {
      final seg = _segById(focusSegId);
      if (seg is NoteTextSeg) _focusSeg(seg, offset: out.focusCaret);
    }
    if (out.removedSegs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final s in out.removedSegs) {
          if (s is NoteTextSeg) s.dispose();
        }
      });
    }
    widget.onDirty?.call(_doc.toRows());
    widget.onChanged?.call();
  }

  /// 媒体插入（光标处拆段）：纯逻辑委托 [_doc]，引擎算段序列变更 +
  /// 焦点反射（媒体后文本段段首），State 据 [EditOutcome] 落焦/重建/落盘。
  void _insertMedia(
    String url, {
    required NoteMediaKind kind,
    String label = '',
  }) {
    _doc.insertMedia(url, kind: kind, label: label);
    _applyOutcome(_doc.consumeOutcome());
  }

  /// 移除媒体段：文件入回收站、相邻文本段合并、光标自动定位（引擎内部
  /// 完成段序列变更与撤消记账，焦点经 [EditOutcome] 反射）。
  void _removeMedia(NoteMediaSeg m) {
    _doc.removeMedia(m);
    _applyOutcome(_doc.consumeOutcome());
  }



  void _focusSeg(NoteTextSeg seg, {int offset = -1}) {
    if (offset >= 0) {
      seg.ctrl.value = TextEditingValue(
        text: seg.ctrl.text,
        selection: TextSelection.collapsed(offset: offset),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      seg.focus.requestFocus();
      final ctx = seg.key.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 180),
          alignment: 0.15,
        );
      }
    });
  }

  // ---------- 内部：段首退格跨段合并 ----------

  /// 段级按键门（输入阻碍审计 P1-1 + 回车拆块拍板，2026-10-04）：
  /// - 段首退格：光标**塌缩在段首**且无 IME 组合时并入上一文本段（合并点
  ///   光标语义，与删媒体合并一致）。拦截条件从严：有选区/组合期/首段一律
  ///   放行原生行为。上一段是媒体卡**不**拦截——退格顺手删录音/照片文件太
  ///   危险（移除走卡片按钮，与回收站语义同源）。
  /// - Shift+Enter：块内软换行——手动插 `\n` 并打 suppress 标志（下一次
  ///   文字变更不拆段）；无修饰回车**不拦**，与软键盘同路（文本变更含
  ///   `\n` → 拆段物化）。
  KeyEventResult _segKeyGate(NoteTextSeg seg, KeyEvent event) {
    // Shift+Enter 软换行（组合期/选区放行：前者=提交拼音，后者=替换文本
    // 经变更路径照常拆段）
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isShiftPressed &&
        event is! KeyUpEvent) {
      final v = seg.ctrl.value;
      if (v.composing.isValid && !v.composing.isCollapsed) {
        return KeyEventResult.ignored;
      }
      if (!v.selection.isCollapsed) return KeyEventResult.ignored;
      _doc.shiftEnter(seg);
      _applyOutcome(_doc.consumeOutcome(), textEdited: true);
      return KeyEventResult.handled;
    }
    // 无修饰回车（Shift 分支已在上方处理）：落在列表行 → 就地起新项 / 空项
    // 退出列表；非列表行原样放行，走既有拆段。
    if (event.logicalKey == LogicalKeyboardKey.enter && event is! KeyUpEvent) {
      final r = _doc.enterOnListLine(seg);
      if (r == KeyEventResult.handled) _applyOutcome(_doc.consumeOutcome());
      return r;
    }
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final v = seg.ctrl.value;
    if (!v.selection.isCollapsed || v.composing.isValid && !v.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    // 行首退格出列/退挡（B3 语义，文本真相）：光标塌缩在标记行行首（前一字符
    // 为 \n 或文本首）时删标记回正文；否则放行既有逻辑（段首合并/原生删字符）。
    final caret = v.selection.extentOffset;
    final atLineStart = caret == 0 || v.text.codeUnitAt(caret - 1) == 0x0A;
    if (atLineStart) {
      if (_doc.backspaceOutdentAt(seg, caret)) {
        _applyOutcome(_doc.consumeOutcome());
        return KeyEventResult.handled;
      }
    }
    if (v.selection.extentOffset != 0) {
      return KeyEventResult.ignored;
    }
    final i = _doc.segs.indexOf(seg);
    if (i <= 0) return KeyEventResult.ignored; // 首段无处可并
    final prev = _doc.segs[i - 1];
    if (prev is! NoteTextSeg) return KeyEventResult.ignored;
    _doc.mergeIntoPrev(seg, prev);
    _applyOutcome(_doc.consumeOutcome());
    return KeyEventResult.handled;
  }



  /// 文字变更点：把控制器最新值交给引擎，引擎算 plan、改段状态、记账，
  /// 结果经 [EditOutcome] 由 [_applyOutcome] 反射（焦点/重建/落盘）。
  void _onSegChanged(NoteTextSeg seg) {
    final beforeKind = lineKindOf(seg.spans.plain, 0);
    _doc.applyTextEdit(seg, seg.ctrl.value, activeMarks: _activeMarks.toList());
    // 文字变更恒触发悬浮球退隐（打字即收，与原文案一致——引擎纯逻辑不替 UI
    // 决定退隐，故此处显式声明 textEdited）。
    _applyOutcome(_doc.consumeOutcome(), textEdited: true);
    // ⑤ 列表/标题格式自动保住：段首行结构标记被编辑冲掉（删光重打 / 整体替换）
    // 导致从结构型退化成 plain 时，自动恢复为该结构型（如空列表项 / 空标题），
    // 避免"格式静默丢失"；主动退出仍走浮层选 plain / 段首退格（不经此路径，不误恢复）。
    final afterKind = lineKindOf(seg.spans.plain, 0);
    if (beforeKind != BlockKind.plain && afterKind == BlockKind.plain) {
      _doc.setLineKind(seg, _targetOf(beforeKind));
      _applyOutcome(_doc.consumeOutcome());
    }
  }



  // ---------- 内部：媒体获取链（两宿主同源） ----------

  /// 拍照：复制进私有目录 → **插入光标处**。
  Future<void> _photo() async {
    _closeFormatDial(); // ③ 场景切换：媒体/标签动作前收转盘
    await _pickAndInsert(
      () => ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400),
      failMsg: '图片保存失败',
    );
  }

  /// 相册选图插入。
  Future<void> _pickAlbumImage() async {
    _closeFormatDial(); // ③ 场景切换：媒体/标签动作前收转盘
    await _pickAndInsert(
      () =>
          ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400),
      failMsg: '图片保存失败',
    );
  }

  Future<void> _pickAndInsert(
    Future<XFile?> Function() pick, {
    required String failMsg,
  }) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final file = await pick();
      if (file == null) return;
      final saved = await copyToAppDir(file.path);
      if (saved == null) {
        ToastManager.show(failMsg, kind: ToastKind.error);
        return;
      }
      _insertMedia(await toLocalMediaUrl(saved), kind: NoteMediaKind.image);
    } catch (e) {
      if (mounted) ToastManager.show('插图失败：$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 录音：弹统一录音框（audio_record_sheet），完成回传路径即**插入光标处**
  /// 播放条（仅存音频，转写走详情页手动触发）。
  Future<void> _record() async {
    _closeFormatDial(); // ③ 场景切换：媒体/标签动作前收转盘
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final path = await showAudioRecordSheet(context);
      if (path == null) return; // 用户取消/丢弃（弹框内已提示）
      _insertMedia(await toLocalMediaUrl(path), kind: NoteMediaKind.audio);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 视频入口二选一面板（相册首位——主路径收集心智，note-video.md §1）。
  Future<void> _pickVideoSource() async {
    _closeFormatDial(); // ③ 场景切换：媒体/标签动作前收转盘
    final source = await showModalBottomSheet<_VideoSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              subtitle: const Text('支持 MP4 / MOV，建议 5 分钟内'),
              onTap: () => Navigator.pop(ctx, _VideoSource.album),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍摄视频'),
              subtitle: const Text('最长 60 秒，自动停止'),
              onTap: () => Navigator.pop(ctx, _VideoSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    switch (source) {
      case _VideoSource.album:
        await _pickAlbumVideo();
      case _VideoSource.camera:
        await _captureVideo();
    }
  }

  /// 相册选视频（主路径）：后置校验——mp4/mov 白名单、100MB 拦截、
  /// >5min 非阻断提示（note-video.md §2）。
  Future<void> _pickAlbumVideo() async {
    final check = await _pickVideoWithGate(
      () => ImagePicker().pickVideo(source: ImageSource.gallery),
      failMsg: '视频保存失败',
    );
    // check == null = 校验通过（note_video_policy 约定）：直接插入；
    // 非 null 且非阻断（>5min）走确认弹窗后再插。
    if (check == null) {
      await _insertCheckedVideo();
      return;
    }
    if (check.blocking) return; // 拦截类已在 _pickVideoWithGate 提示
    if (!mounted) return;
    final ok = await confirmDialog(
      context,
      title: '视频较长',
      content: '嵌入可能加载较慢，仍要添加吗？',
      confirmText: '仍要添加',
    );
    if (ok == true) await _insertCheckedVideo();
  }

  /// 相机直拍视频（次路径）：自建拍摄页（拍板「自建拍摄页＋进度环」）。
  Future<void> _captureVideo() async {
    final path = await NoteVideoCapturePage.push(
      context,
      maxDuration: noteVideoCaptureMaxDuration,
    );
    if (path == null || !mounted) return; // 取消/拍摄失败
    final check = await _pickVideoWithGate(
      () async => XFile(path),
      failMsg: '视频保存失败',
    );
    if (check == null) await _insertCheckedVideo();
  }

  /// 选/拍 → 落盘 → 后置校验；通过即插入。拦截类在此统一提示，
  /// 非阻断（>5min）返回 check 交调用方走确认弹窗。
  Future<NoteVideoCheck?> _pickVideoWithGate(
    Future<XFile?> Function() pick, {
    required String failMsg,
  }) async {
    if (_sending) return null;
    _pendingVideoPath = null; // 清陈值：取消/失败不得残留上一次的待插路径
    setState(() => _sending = true);
    try {
      final file = await pick();
      if (file == null) return null;
      final saved = await copyToAppDir(file.path);
      if (saved == null) {
        ToastManager.show(failMsg, kind: ToastKind.error);
        return null;
      }
      final check = await checkNoteVideoAlbum(saved);
      if (check != null && check.blocking) {
        ToastManager.show(
          switch (check.kind) {
            NoteVideoCheckKind.unsupportedFormat => '暂不支持该格式，建议使用 MP4 或 MOV',
            NoteVideoCheckKind.tooLarge => '视频过大（>100MB），建议剪短后再嵌入',
            NoteVideoCheckKind.unreadable => '视频无法读取',
            _ => '视频校验失败',
          },
          kind: ToastKind.error,
        );
        // 拦截类：已拷入私有目录的副本立即清理，防孤儿文件
        unawaited(() async {
          try {
            final f = File(saved);
            if (await f.exists()) await f.delete();
          } catch (e) {
            debugPrint(
              '[DEGRADE] note_video_reject_copy_delete_failed path=$saved error=$e',
            );
          }
        }());
        return null;
      }
      _pendingVideoPath = saved;
      return check;
    } catch (e) {
      if (mounted) {
        ToastManager.show('视频添加失败：$e', kind: ToastKind.error);
      }
      return null;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 把已通过校验的 [_pendingVideoPath] 插入为视频段。
  Future<void> _insertCheckedVideo() async {
    final saved = _pendingVideoPath;
    if (saved == null) return;
    _pendingVideoPath = null;
    _insertMedia(await toLocalMediaUrl(saved), kind: NoteMediaKind.video);
  }

  /// 标签：给本条未保存内容挂标签（仅速记条启用）。
  Future<void> _pickTags() async {
    _closeFormatDial(); // ③ 场景切换：媒体/标签动作前收转盘
    final pending = widget.pendingTags ?? const <String>[];
    final onChanged = widget.onPendingTagsChanged;
    if (onChanged == null) return;
    // 统一标签编辑器（动词→容器词汇表：与详情页同一 Sheet 形态）
    final tags = await showTagEditor(context, initial: pending);
    if (tags != null && mounted) onChanged(tags);
  }

  // ---------- 内部：格式状态机 ----------

  /// 行内 mark 开关。
  ///
  /// 口径放宽 pending-confirm D5 一处（2026-10-08 用户实测"选中即加粗"反直觉）：
  /// **若当前段有非折叠选区**→直接把 mark 套到选中文字（所见即所得，与主流
  /// 编辑器一致），选区保持以便连续切 B/I；**无选区**才走先选后打（点亮后作用
  /// 于之后输入的文字）。**单选制**（B/I 互斥）仅在"先选后打"路径生效——选区
  /// 路径直接操作 runs，可叠加 B+I（嵌套），契合"选中即加粗/斜体"直觉。
  void _toggleMark(InlineMark mark) {
    final seg = _activeText;
    if (seg == null) return;
    final sel = seg.ctrl.selection;
    if (sel.isValid && !sel.isCollapsed) {
      _doc.applyMarkToSelection(seg, mark);
      _applyOutcome(_doc.consumeOutcome());
      seg.focus.requestFocus(); // 选区套格式后保持段聚焦，可连续切多个 mark
      return;
    }
    setState(() {
      if (!_activeMarks.remove(mark)) {
        _activeMarks
          ..clear()
          ..add(mark);
      }
    });
    // 焦点回写作区（键盘保持弹出）：选完格式即可接着打字。
    seg.focus.requestFocus();
  }

  // ---------- 渲染 ----------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 硬件键盘撤销/重做（Ctrl/Cmd+Z、Ctrl+Y / Ctrl+Shift+Z）——挂编辑器
    // 顶层 Shortcuts，比应用级文本编辑默认映射更近，优先命中本编辑器栈。
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyZ, control: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _UndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyY, control: true): _RedoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
            _RedoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            _RedoIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _UndoIntent: CallbackAction<_UndoIntent>(onInvoke: (_) => _undo()),
          _RedoIntent: CallbackAction<_RedoIntent>(onInvoke: (_) => _redo()),
        },
        child: PopScope(
          // ⑦ 返回键/侧滑手势**直接退出编辑**（一键退出，不再"先关面板再退出"
          // 看着像没反应）：格式浮层是 Stack 内临时层，随页面 pop 一起销毁，无需
          // 单独拦截。面板仍可由角标 toggle / 切后台 / 媒体动作等 [_closeFormatDial] 关闭。
          canPop: true,
          child: LayoutBuilder(
            builder: (context, cons) {
              return Stack(
                children: [
                  // 作曲层：满幅铺到工具层背后，内容超出内部滚动。
                  // 视口底边止于工具层上沿：光标与末段永不滑进工具层底下。
                  Positioned.fill(
                    child: AudioPlaybackService(
                      controller: _audioCtl,
                      child: Padding(
                        padding: const EdgeInsets.only(
                          bottom: kComposerToolLayerHeight,
                        ),
                        // ① 点空白聚焦文末（输入阻碍审计 P3）：未命中文本/媒体
                        // 的点按落到此处，光标送末段文末+弹键盘；TextField/
                        // 媒体卡的点按在手势竞用中胜出，不受影响。
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () {
                            final last = _doc.segs
                                .whereType<NoteTextSeg>()
                                .lastOrNull;
                            if (last != null) {
                              _focusSeg(last, offset: last.spans.plain.length);
                            }
                          },
                          // ② 用户拖动滚动 = 离开格式态：自动收盘（程序性滚动不受影响）
                          child: NotificationListener<ScrollUpdateNotification>(
                            onNotification: (n) {
                              if (n.dragDetails != null) _closeFormatDial();
                              return false;
                            },
                            child: ListView.builder(
                              padding: const EdgeInsets.only(top: Insets.xs),
                              itemCount: _doc.segs.length,
                              itemBuilder: (context, i) => switch (_doc.segs[i]) {
                                NoteTextSeg s => _textFieldFor(
                                  s,
                                  showHint: i == 0 && _doc.segs.length == 1,
                                ),
                                NoteMediaSeg m => _mediaCard(m),
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 工具层：独立覆盖底部，内容怎么滚都不消失（键盘弹起贴键盘上沿）
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _toolLayer(scheme),
                  ),
                  // 问题#1 引导层·Step 3 贴键浮层打样面板：点侧轨 chip 弹出，
                  // WYSIWYG 选块（含行内 B/I），对接 setLineKind。
                  if (_blockPanelOpen) _blockFormatPanel(scheme),
                ],
              );
            },
          ),
        ),
      ),
    );
  }


  /// 文本段输入框（无边界，段间自然衔接；首段空态给提示语）。
  ///
  /// span 所见即所得：控制器是 [SpanTextEditingController]（buildTextSpan
  /// 注入 runs/levelRuns 样式），编辑区全程无 md 标记；粘贴归一（空行折叠）
  /// ——md 源码按**字面**粘贴（不当语法解释）。
  Widget _textFieldFor(NoteTextSeg seg, {required bool showHint}) {
    // 段级按键门（段首退格合并 + Shift+Enter 软换行）：光标塌缩段首的退格
    // 不再静默无操作——并入上一文本段。挂本段 TextField 的**祖先** Focus 上（按键事件沿
    // 焦点链冒泡必经此处；软键盘删无可删时 Android 嵌入层转发 KEYCODE_DEL
    // 平台键事件，硬件键盘同路。挂节点自身 onKeyEvent 会被 TextField 内部
    // 焦点处理覆盖/绕过——真机与测试双双实证）。
    final field = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) => _segKeyGate(seg, event),
      child: TextField(
        key: seg.key,
        controller: seg.ctrl,
        focusNode: seg.focus,
        maxLines: null,
        onChanged: (_) {
          _onSegChanged(seg); // 文字变更：段状态随动 + 脏通知交宿主
        },
        inputFormatters: const [SpanPasteNormalizeFormatter()],
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        decoration: InputDecoration(
          hintText: showHint ? widget.hintText : null,
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: Insets.xs),
        ),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
    // 列表/待办行才加左侧凹槽（无列表段直接原样返回，排版零变化）。
    return _withFocusBadge(seg, _withListGutter(seg, field));
  }

  /// 聚焦段语义角标（问题#1 引导层·Step 1，兼浮层入口）：仅当前段获得焦点时在
  /// 段首呈现 24dp 弱化角标（H1 / H2 / ▎ / T），失焦宽度收为 0。
  ///
  /// 2026-10-08 拍板：**列表/待办段同样显示角标**（原为「凹槽已占宽，不重复」
  /// 而隐藏）。原因：待办/引用/标题档齐全后，列表行若不给角标就**没有任何改
  /// 类型的出口**（凹槽只认 • 与 ☑，改不回正文/标题），入口一致性优先于省
  /// 24dp——代价是列表段左侧共 52dp（角标 24 + 凹槽 28），331dp 窄屏正文余
  /// 279dp，可接受（原设计余 303dp）。
  Widget _withFocusBadge(NoteTextSeg seg, Widget child) {
    return ListenableBuilder(
      listenable: seg.focus,
      builder: (context, _) {
        final focused = seg.focus.hasFocus;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 24,
              // ① 入口常驻：失焦段也留一个极淡角标，避免"完全隐身"找不到格式入口；
              // 聚焦时恢复实色（opacity 1）。列表段另带凹槽，合计左侧 52dp 常驻。
              child: Opacity(
                opacity: focused ? 1.0 : 0.32,
                child: _focusBadge(seg),
              ),
            ),
            Expanded(child: child),
          ],
        );
      },
    );
  }

  /// 角标内容：取光标所在行的 [BlockKind]，用统一规约渲染低对比徽标。光标在段内
  /// 移动时经 [seg.ctrl] 监听实时重算（多行段切换行即换类型）。样式源 = 正文渲染
  /// 同源的 [blockPresentationOf]（arch-guard R7：不写裸 fontSize 字面量）。
  Widget _focusBadge(NoteTextSeg seg) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: seg.ctrl,
      builder: (context, _) {
        final caret = seg.ctrl.selection.isValid
            ? seg.ctrl.selection.extentOffset
            : 0;
        final kind = lineKindOf(seg.ctrl.text, caret);
        final spec = blockPresentationOf(kind);
        final badgeStyle = (theme.labelSmall ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            // 角标＝浮层开关（toggle）：开着再点即收（配合⑥面板保持展开后用户
            // 需一个明确出口）；关着则点开——失焦段先同步锁定活跃段再聚焦。
            if (_blockPanelOpen) {
              if (mounted) setState(() => _blockPanelOpen = false);
              return;
            }
            _doc.activeSegId = seg.id;
            seg.focus.requestFocus();
            if (mounted) setState(() => _blockPanelOpen = true);
          },
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(child: Text(spec.badge, style: badgeStyle, maxLines: 1)),
          ),
        );
      },
    );
  }

  /// 选块落地（问题#1 引导层·Step 3）：chip 浮层选中的语义 → [LineKindTarget] →
  /// [ComposerDoc.setLineKind]（已含 IME 组合态守卫 _finalizeComposing）。待办
  /// 2026-10-08 拍板回归显式档（写 `- [ ] `，翻勾选仍走 toggleTodo）；结果经
  /// [EditOutcome] 反射重建。
  /// [BlockKind] → [LineKindTarget] 映射（面板选块 / ⑤格式退化恢复共用）。
  LineKindTarget _targetOf(BlockKind kind) => switch (kind) {
        BlockKind.plain => LineKindTarget.plain,
        BlockKind.h1 => LineKindTarget.h1,
        BlockKind.h2 => LineKindTarget.h2,
        BlockKind.bullet => LineKindTarget.bullet,
        BlockKind.quote => LineKindTarget.quote,
        BlockKind.todo => LineKindTarget.todo,
      };

  /// 选块落地（问题#1 引导层·Step 3）：chip 浮层选中的语义 → [LineKindTarget] →
  /// [ComposerDoc.setLineKind]（已含 IME 组合态守卫 _finalizeComposing）。待办
  /// 2026-10-08 拍板回归显式档（写 `- [ ] `，翻勾选仍走 toggleTodo）；结果经
  /// [EditOutcome] 反射重建。
  void _applyBlockKind(BlockKind kind) {
    final seg = _activeText;
    if (seg == null) return;
    _doc.setLineKind(seg, _targetOf(kind));
    _applyOutcome(_doc.consumeOutcome());
    // ⑥ 与行内 B/I 统一：结构档选完也**保持展开**（不再选完即收），面板由
    // 角标 toggle / 返回退出等明确出口关闭，消除"同一面板两种行为难预测"。
    seg.focus.requestFocus();
  }

  /// 贴键浮层打样面板（问题#1 引导层·Step 3）：点 Step 1 chip 弹出，WYSIWYG 选块，
  /// 正式对接 [ComposerDoc.setLineKind]。锚在工具层上沿、软键盘上方，绝不挤占正文
  ///（横向滚动容 6 档）。样式源 = 正文渲染同源的 [blockPresentationOf]，所见即所选。
  ///
  /// 档位序 = **语义层级**（正文 → 标题 → 列表 → 待办 → 引用），不按频次排：
  /// 用户是「按语义找档」而非「按肌肉记忆找位置」，语义序可预测性更高；正文
  /// 作回退档置首（错误预防）。
  Widget _blockFormatPanel(ColorScheme scheme) {
    final theme = Theme.of(context).textTheme;
    final seg = _activeText;
    final current = seg == null
        ? BlockKind.plain
        : lineKindOf(
            seg.ctrl.text,
            seg.ctrl.selection.isValid ? seg.ctrl.selection.extentOffset : 0,
          );
    return Positioned(
      left: Insets.sm,
      right: Insets.sm,
      bottom: kComposerToolLayerHeight + Insets.sm,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(Radii.md),
        color: scheme.surfaceContainerHigh,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(Insets.sm),
          child: Row(
            children: [
              // 结构档：正文 → 标题（语义序，正文为回退档置首）
              for (final k in const [
                BlockKind.plain,
                BlockKind.h1,
                BlockKind.h2,
              ])
                Padding(
                  padding: const EdgeInsets.only(right: Insets.xs),
                  child: _blockTile(k, k == current, scheme, theme),
                ),
              // 行内档（2026-10-08 拍板：B/I 紧跟标题二）：与结构档间加一道
              // 细分隔——两类语义不同（块级=整行，行内=之后输入的文字），
              // 视觉分组防混读。
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(right: Insets.xs),
                color: scheme.outlineVariant,
              ),
              for (final m in const [InlineMark.bold, InlineMark.italic])
                Padding(
                  padding: const EdgeInsets.only(right: Insets.xs),
                  child: _markTile(m, _activeMarks.contains(m), scheme, theme),
                ),
              Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(right: Insets.xs),
                color: scheme.outlineVariant,
              ),
              // 结构档（续）：列表 → 待办 → 引用
              for (final k in const [
                BlockKind.bullet,
                BlockKind.todo,
                BlockKind.quote,
              ])
                Padding(
                  padding: const EdgeInsets.only(right: Insets.xs),
                  child: _blockTile(k, k == current, scheme, theme),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单档打样瓦片：徽标 + 用统一规约渲染的样例文字（所见即所选），选中高亮 primaryContainer。
  Widget _blockTile(BlockKind kind, bool selected, ColorScheme scheme, TextTheme theme) {
    final spec = blockPresentationOf(kind);
    final style = spec.resolveStyle(theme, scheme);
    final badgeStyle = (theme.labelSmall ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _applyBlockKind(kind),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(spec.badge, style: badgeStyle, maxLines: 1),
              ),
              const SizedBox(width: 8),
              Text(_blockSample(kind), style: style),
            ],
          ),
        ),
      ),
    );
  }

  /// 行内格式瓦片（B / I，2026-10-08 拍板）：**字母本体即样式预览**（B 加粗、
  /// I 斜体），激活高亮 primaryContainer。
  ///
  /// **开关型**：切换后浮层**保持展开**（可连点试错 / 再点关闭），与档位型
  /// 「选完即收」区分——沿用 format_toolbar 既有口径：块级是一次性选择，行内
  /// 是可连续启停的状态。语义受 D5 约束＝先选后打（作用于之后输入的文字）。
  Widget _markTile(
    InlineMark mark,
    bool active,
    ColorScheme scheme,
    TextTheme theme,
  ) {
    final letter = mark == InlineMark.bold ? 'B' : 'I';
    final style = (theme.titleMedium ?? const TextStyle()).copyWith(
      fontWeight: mark == InlineMark.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: mark == InlineMark.italic ? FontStyle.italic : FontStyle.normal,
      color: active ? scheme.onPrimaryContainer : scheme.onSurface,
    );
    return Material(
      color: active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _toggleMark(mark),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(letter, style: style),
        ),
      ),
    );
  }

  /// 瓦片样例文字（WYSIWYG 预览用，与真实正文同字号/行高）。
  String _blockSample(BlockKind kind) => switch (kind) {
        BlockKind.h1 => '标题一',
        BlockKind.h2 => '标题二',
        BlockKind.bullet => '列表项',
        BlockKind.quote => '引用文字',
        BlockKind.plain => '正文',
        BlockKind.todo => '待办项',
      };

  /// 列表凹槽：一行是一个列表项，标记必须**逐行对齐正文**——单个 TextField
  /// 无法内嵌可点勾选框（`buildSpanTextSpan` 加字形会让光标几何错位），故
  /// 用左侧凹槽 + 镜像 `TextPainter` 量出每行 Y 后画 • / 勾选框。
  ///
  /// ⚠️ 校平依赖：凹槽 Y = 镜像 TextPainter 的行顶 + 文本框 `contentPadding`
  /// 纵向值（Insets.xs）。换行较宽的行若插入宽度与真实输入框存在水平余量差，
  /// 行 Y 会漂移——需真机验证（本机无设备），详见 epic devlog。
  Widget _withListGutter(NoteTextSeg seg, Widget field) {
    if (seg.spans.listRuns.isEmpty) return field;
    return LayoutBuilder(
      builder: (context, cons) {
        if (!cons.maxWidth.isFinite) return field;
        final fieldW = (cons.maxWidth - kListGutterWidth).clamp(0.0, double.maxFinite);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: kListGutterWidth,
              child: ListenableBuilder(
                listenable: seg.ctrl,
                builder: (context, _) => _listMarkers(seg, fieldW),
              ),
            ),
            Expanded(child: field),
          ],
        );
      },
    );
  }

  /// 凹槽内标记列：按 [fieldW] 镜像排版，逐行定位 • / 有序序号 / 待办勾选框。
  Widget _listMarkers(NoteTextSeg seg, double fieldW) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyLarge;
    final ords = quickNoteOrderedOrdinals(seg.spans.listRuns);
    final plain = seg.ctrl.text;
    final painter = TextPainter(
      text: TextSpan(text: plain, style: base),
      textDirection: Directionality.of(context),
      maxLines: null,
    )..layout(maxWidth: fieldW);
    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) return const SizedBox.shrink();
    // 逐**逻辑行**单独排版：本 Flutter 版 LineMetrics 无 start/end 偏移
    //（只有 hardBreak/height/baseline…），故按整段量出的视觉行拿不到行号映射。
    // 改为逐层单独的 TextPainter：每行行顶=之前各行高累加，行高=该行 p.height
    //（内含其所有软换行视觉行）。同风格下行高一致，与输入框整体排版等价。
    final lines = plain.split('\n');
    final tops = <double>[]; // 每个逻辑行的行顶
    final heights = <double>[]; // 该逻辑行总高（含软换行）
    final dir = Directionality.of(context);
    var probe = 0.0;
    for (final l in lines) {
      final p = TextPainter(
        text: TextSpan(text: l, style: base),
        textDirection: dir,
        maxLines: null,
      )..layout(maxWidth: fieldW);
      tops.add(probe);
      heights.add(p.height);
      probe += p.height;
    }
    final totalHeight = probe;
    return SizedBox(
      width: kListGutterWidth,
      height: totalHeight,
      child: Stack(
        children: [
          for (final r in seg.spans.listRuns)
            () {
              final safeStart = r.start.clamp(0, plain.length);
              final logical = '\n'.allMatches(plain.substring(0, safeStart)).length;
              if (logical >= tops.length) return const SizedBox.shrink();
              return Positioned(
                left: 0,
                right: 0,
                // 行盒内垂直居中：占位高=该逻辑行行高
                height: heights[logical],
                top: tops[logical] + Insets.xs,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: switch (r.kind) {
                    SpanListKind.todo => IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 20,
                        onPressed: () => _toggleTodo(seg, r),
                        icon: Icon(
                          r.done
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          color: r.done ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                        tooltip: r.done ? '标记未完成' : '标记完成',
                      ),
                    // 序号实时取自连续组——增/删中项后自动重排，无需改正文
                    SpanListKind.ordered => Text(
                        '${ords[r.start] ?? 1}.',
                        style: base?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    SpanListKind.bullet => Icon(
                        Icons.fiber_manual_record,
                        size: 8,
                        color: scheme.onSurfaceVariant,
                      ),
                  },
                ),
              );
            }(),
        ],
      ),
    );
  }

  /// 待办勾选切换（文本真相，引擎内部改写行内 `[ ]`/`[x]` 字面）：纯逻辑委托
  /// [_doc]，结果经 [EditOutcome] 反射重建/落盘。
  void _toggleTodo(NoteTextSeg seg, SpanListRun target) {
    _doc.toggleTodo(seg, target);
    _applyOutcome(_doc.consumeOutcome());
  }

  /// 软换行（高困惑 #1/#3 统一入口）：移动端无 Shift 也能块内换行；列表项内
  /// 自动续行并入同一项。委托 [_doc.softNewline]，结果经 [EditOutcome] 反射。
  void _softBreak() {
    final seg = _doc.activeText;
    if (seg == null) return;
    _doc.softNewline(seg);
    _applyOutcome(_doc.consumeOutcome(), textEdited: true);
  }

  /// 媒体段卡片：本体预览（与阅读态同源组件）+ 右上角移除按钮。
  /// [NoteComposerEditor.onMediaReplace] 注入时：长按图/视频/音频卡 = 换
  /// 文件/重录（2026-10-04 二次拍板：音频**点按归播放**，重录统一走长按——
  /// 原「点音频卡即重录」会让「想听一下刚录的」变成「重新录一条」）。
  Widget _mediaCard(NoteMediaSeg seg) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final replace = widget.onMediaReplace;
    final exists = seg.file.existsSync();
    Widget body = switch (seg.kind) {
      NoteMediaKind.audio => SizedBox(
        // 紧凑档（2026-10-04 拍板：原 96dp 过高）；bounded 高度供
        // expandBody 撑满，点按整卡 = 播放/暂停。
        height: 64,
        width: double.infinity,
        child: MediaAudioBar(
          blockId: 'note-audio-${identityHashCode(seg)}',
          source: resolveLocalMediaSrc(seg.url),
          label: seg.label.isEmpty ? '录音' : seg.label,
          // 卡片与面板分层不靠色阶差（易糊）：描边 + 波形底纹由组件统一给，
          // 这里只给底色的档位差（面板=surface，卡片=High）
          backgroundColor: scheme.surfaceContainerHigh,
          expandBody: true,
          degrade: classifyMediaUrl(seg.url) == MediaSuffix.audioDegrade,
        ),
      ),
      // 视频卡：原生提帧封面（VideoCoverImage，失败回落图标占位）+ 中央
      // 播放钮；点按全屏预览（草稿态即给「添加了什么、能不能播」的确认）。
      NoteMediaKind.video => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: double.infinity,
          height: 220,
          child: Container(
            color: scheme.surfaceContainerHighest,
            child: exists
                ? InkWell(
                    onTap: () => showInlineVideoPlayer(
                      context,
                      url: seg.url,
                      // 编辑态无所属条目（草稿未落库），无字幕轨
                      itemId: '',
                      label: seg.label.isEmpty ? '视频预览' : seg.label,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoCoverImage(url: seg.url),
                        Center(
                          child: Icon(
                            Icons.play_circle_outline,
                            size: 44,
                            color: scheme.onSurface,
                            shadows: const [
                              Shadow(blurRadius: 8, color: Colors.black54),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : _missingCard(scheme, text: '视频文件丢失'),
          ),
        ),
      ),
      NoteMediaKind.image => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: double.infinity,
          height: 220,
          child: Container(
            color: scheme.surfaceContainerHighest,
            child: exists
                ? InkWell(
                    // 点图全屏查看（2026-10-03 拍板）：黑底缩放查看器
                    onTap: () => showImageFullScreen(context, file: seg.file),
                    child: GoodshareImage(
                      file: seg.file,
                      fit: BoxFit.cover,
                      cacheWidth: (dpr * 480).round(),
                      errorBuilder: (_, _, _) =>
                          _missingCard(scheme, text: '图片无法读取'),
                    ),
                  )
                : _missingCard(scheme, text: '图片文件丢失'),
          ),
        ),
      ),
    };
    // 长按 = 换文件 / 重录（三类媒体同口径，2026-10-04 拍板：音频不再享
    // 「点按即重录」的特权——点按一律归播放，避免误触毁掉刚录的内容）
    if (replace != null) {
      body = GestureDetector(onLongPress: () => _runReplace(seg), child: body);
    }
    // 滑动删除（2026-10-03 二次拍板：确认式，防误删）——按住媒体卡横向拖动
    // **跟手平移**，露出底下红色删除底色（icon+「删除」）；滑到卡片宽度对侧
    // 阈值（或同向快甩）松手才确认删除，否则回弹归位。音频条内 Slider 自带
    // 横拖，其在场时竞技场优先（滑进度不误删）。移除后光标自动定位（见
    // _removeMedia）。
    body = _SwipeToRemove(onConfirmed: () => _removeMedia(seg), child: body);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: body,
    );
  }

  /// 媒体替换钩子执行：钩子内自行改 seg.url；引擎先记结构撤销步，返回后
  /// 经 [EditOutcome] 反射重建/落盘（取消 = url 不变，无脏扩散）。
  Future<void> _runReplace(NoteMediaSeg seg) async {
    final hook = widget.onMediaReplace;
    if (hook == null) return;
    _doc.beginStructuralStep();
    await hook(seg);
    final out = _doc.consumeOutcome();
    _applyOutcome(
      out == null
          ? const EditOutcome(needsRebuild: true)
          : out.merge(const EditOutcome(needsRebuild: true)),
    );
  }

  Widget _missingCard(ColorScheme scheme, {required String text}) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  /// 工具层（动作行单行）：悬浮球迁顶层 Stack 全域拖动后格式行退役
  ///（2026-10-04 四缘吸附拍板），写作区让出一行高度。
  ///
  /// 转盘面板不挂本层：本层在 Positioned(bottom:0) 下收 loose 高度约束，
  /// 越界 sheet 既触发 Stack sizing 断言，又落进 hit-test 盲区（真机点不中）。
  /// 面板挂顶层「作曲层+工具层」Stack（见 build 内 children）。
  Widget _toolLayer(ColorScheme scheme) {
    return SizedBox(
      height: kComposerToolLayerHeight,
      child: _actionRow(scheme),
    );
  }

  /// 「导入 Markdown」弹框（2026-10-06 拍板）：用户在**受控输入框**里粘贴/输入
  /// md 片段 → [seedTextTruth] 解析为文本真相态（线级标记留文本，与段播种同
  /// 口径——旧播种剥掉线级标记会让导进来的待办点勾选框无字面可翻）
  /// → [insertSeededSpans] 插入当前段光标处。选此口而非钩粘贴的目的：绕开
  /// `EditableText` 粘贴链路（键盘 Ctrl+V 与移动端长按菜单两条路径、`TextInputFormatter` 只拿纯文本
  /// 拿不到 runs 结构），转换时机由用户显式触发，桌面/移动行为完全一致。
  Future<void> _openMdImport() async {
    final text = await showDialog<String>(
      context: context,
      // 独立 widget 自持控制器：退场动画期间 TextField 仍可达控制器，故生命
      // 周期必须跟 dialog 自身（挂在这里 dispose 会「use after disposed」）。
      builder: (ctx) => const _MdImportDialog(),
    );
    final md = text?.trim();
    if (md == null || md.isEmpty || !mounted) return;
    _insertSeededFragment(md);
  }

  /// 把 md 片段解析后插入当前文本段光标处（或替换选区）：全维度坐标合并
  ///（runs/levelRuns/listRuns 随窗随动）。
  void _insertSeededFragment(String md) {
    final seg = _activeText;
    if (seg == null) return;
    final frag = seedTextTruth(md);
    if (frag.plain.isEmpty) return;
    final sel = seg.ctrl.selection;
    final len = seg.spans.plain.length;
    final at = (sel.isValid ? sel.start : len).clamp(0, len);
    final replaceEnd = (sel.isValid ? sel.end : at).clamp(at, len);
    _doc.beginStructuralStep(); // 导入=结构变更，记一步撤销
    // ⚠️ 顺序红线：先整整更新段状态（spans），再写控制器文本——
    // [_onSegChanged] 以 `oldPlain = seg.spans.plain` 判插入新行，若先写 ctrl
    // 会让多行片段被误判为「敲进来的换行」而逐行拆成独立段。
    insertSeededSpans(seg.spans, frag, at, replaceEnd: replaceEnd);
    // 文本真相：片段的线级标记已进文本，行级身份必须由派生视图重算——
    // insertSeededSpans 内的 adjust* 是旧模型坐标搬运（只挪不建）。
    deriveLineRuns(seg.spans);
    final caret = (at + frag.plain.length).clamp(0, seg.spans.plain.length);
    seg.ctrl
      ..text = seg.spans.plain
      ..selection = TextSelection.collapsed(offset: caret);
    seg.spans.selBase = caret;
    seg.spans.selExtent = caret;
    final out = _doc.consumeOutcome();
    _applyOutcome(
      out == null
          ? const EditOutcome(needsRebuild: true)
          : out.merge(const EditOutcome(needsRebuild: true)),
    );
  }

  /// 动作行（2026-10-08 拍板：**钉住高频 + 其余横滚**）。
  ///
  /// 窄屏 331dp 装不下 9 个图标（实测溢出，末尾 Spacer/标签文本先被压成 0），
  /// 故拆两段：
  /// - **钉住区**（恒可见、绝不进滚动）：撤销 / 重做——误操作救命键，藏进滚动
  ///   区等于「找不到后悔药」；
  /// - **横滚区**：拍照 / 相册 / 录音 / 视频 / **md 导入** / 软换行 / 标签，
  ///   按「插入类聚合」排序（md 紧跟视频，语义同类相邻）。
  ///
  /// 可滚时右缘渐隐作 affordance（提示后面还有），不可滚时**不画**——假的截断
  /// 感比没有提示更糟。渐隐 IgnorePointer，绝不吞点击。
  Widget _actionRow(ColorScheme scheme) {
    final pendingTags = widget.pendingTags;
    final showTags = widget.onPendingTagsChanged != null;
    final hasTags = pendingTags != null && pendingTags.isNotEmpty;
    final tags = pendingTags ?? const <String>[];
    return SizedBox(
      height: kComposerToolLayerHeight,
      child: Row(
        children: [
          // ---- 钉住区 ----
          // （本行无待办入口：整段逐行转待办的保存期模式 2026-10-03 已废弃且
          // 2026-10-08 收窄推翻时**未恢复**；建行级待办档走浮层，见 BlockKind.todo）
          IconButton(
            onPressed: _doc.canUndo ? _undo : null,
            icon: const Icon(Icons.undo_outlined),
            tooltip: '撤销',
          ),
          IconButton(
            onPressed: _doc.canRedo ? _redo : null,
            icon: const Icon(Icons.redo_outlined),
            tooltip: '重做',
          ),
          // ---- 横滚区（插入类聚合；md 导入紧跟视频） ----
          Expanded(
            child: Stack(
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    // metrics 变化（旋转/键盘起落）转 post-frame 再判可滚性
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _syncToolScrollable(),
                    );
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _toolScroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: Insets.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: _sending ? null : _photo,
                          icon: const Icon(Icons.photo_camera_outlined),
                          tooltip: '拍照插入',
                        ),
                        IconButton(
                          onPressed: _sending ? null : _pickAlbumImage,
                          icon: const Icon(Icons.photo_outlined),
                          tooltip: '相册插图',
                        ),
                        IconButton(
                          onPressed: _sending ? null : _record,
                          icon: const Icon(Icons.mic_none),
                          tooltip: '录音插入',
                        ),
                        IconButton(
                          onPressed: _sending ? null : _pickVideoSource,
                          icon: const Icon(Icons.movie_creation_outlined),
                          tooltip: '视频插入',
                        ),
                        IconButton(
                          onPressed: _sending ? null : _openMdImport,
                          icon: const Icon(Icons.note_add_outlined),
                          tooltip: '导入 Markdown 片段',
                        ),
                        IconButton(
                          onPressed: _softBreak,
                          icon: const Icon(Icons.wrap_text),
                          tooltip: '换行（列表内续行）',
                        ),
                        if (showTags)
                          IconButton(
                            onPressed: _sending ? null : _pickTags,
                            icon: Badge(
                              isLabelVisible: hasTags,
                              label: Text('${pendingTags?.length ?? 0}'),
                              child: const Icon(Icons.tag),
                            ),
                            tooltip: '标签',
                          ),
                        // 标签文本：滚动区内**不给 Expanded**（无界宽会让滚动
                        // 区撑满、滚动失效），限宽截断即可——数量已在 Badge 上
                        if (showTags && hasTags)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 88),
                            child: Text(
                              tags.map((t) => '#$t').join(' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_toolScrollable)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(child: _toolScrollFade(scheme)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 横滚区右缘渐隐（可滚 affordance）：透明 → 底色，纯装饰不吞点击。
  Widget _toolScrollFade(ColorScheme scheme) => Container(
    width: 16,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          scheme.surface.withValues(alpha: 0),
          scheme.surface,
        ],
      ),
    ),
  );
}

/// 「导入 Markdown」弹框本体（2026-10-06 拍板）：自持 TextEditingController，
/// 生命周期跟随 dialog 自身——避免在宿主侧 dispose 后、退场动画仍在读数导致
/// 「used after being disposed」。
///
/// 受控输入框是**刻意的**（不钩系统粘贴）：md 片段走 [seedTextTruth] 显式
/// 解析，桌面/移动两条粘贴链路（Ctrl+V / 长按菜单）语义统一，零歧义。
class _MdImportDialog extends StatefulWidget {
  const _MdImportDialog();

  @override
  State<_MdImportDialog> createState() => _MdImportDialogState();
}

class _MdImportDialogState extends State<_MdImportDialog> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入 Markdown'),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        minLines: 4,
        maxLines: 10,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
          hintText:
              '粘贴或输入 Markdown 片段…\n'
              '支持 # 标题、**粗体**、- 列表、- [ ] 待办',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctl.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 滑动确认删除包装（2026-10-03 拍板）：子内容横向跟手平移，露出底层红色
/// 删除底色（icon+文字随进度显现）；拖过确认阈值（卡宽 60%，即「滑到另一
/// 侧」）或同向快甩后松手 = 确认删除，否则动画回弹归位。
class _SwipeToRemove extends StatefulWidget {
  const _SwipeToRemove({required this.onConfirmed, required this.child});

  final VoidCallback onConfirmed;
  final Widget child;

  @override
  State<_SwipeToRemove> createState() => _SwipeToRemoveState();
}

class _SwipeToRemoveState extends State<_SwipeToRemove> {
  double _dx = 0;
  double _fullWidth = 0;

  static const double _confirmRatio = 0.6;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        _fullWidth = cons.maxWidth;
        final progress = (_dx.abs() / (_fullWidth * _confirmRatio)).clamp(
          0.0,
          1.0,
        );
        return Stack(
          children: [
            // 删除底色：始终垫底，透明度/缩放随拖动进度显现
            Positioned.fill(
              child: Opacity(
                opacity: progress,
                child: Container(
                  alignment: _dx > 0
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Opacity(
                    opacity: progress,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline, color: Colors.white),
                        SizedBox(width: Insets.xs),
                        Text(
                          '删除',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 内容本体：跟手平移（双向都允许，语义一致）
            AnimatedSlide(
              duration: _dx == 0
                  ? const Duration(milliseconds: 180)
                  : Duration.zero,
              curve: Curves.easeOutCubic,
              offset: Offset(_dx / (_fullWidth == 0 ? 1 : _fullWidth), 0),
              child: GestureDetector(
                onHorizontalDragUpdate: (d) => setState(
                  () => _dx = (_dx + d.delta.dx).clamp(-_fullWidth, _fullWidth),
                ),
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  final crossed = _dx.abs() >= _fullWidth * _confirmRatio;
                  final fling = v.abs() > 1200 && (v.sign == _dx.sign);
                  if (crossed || (fling && _dx.abs() > 48)) {
                    widget.onConfirmed();
                    return; // 不回弹（行随即被移除）
                  }
                  setState(() => _dx = 0); // 回弹归位
                },
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }
}
