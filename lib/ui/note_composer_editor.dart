import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'smart_floating_hub.dart';

import '../app/lifecycle_manager.dart';
import 'toast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../doc/rich_text.dart'
    show InlineMark, MediaSuffix, SpanListKind, SpanListRun, classifyMediaUrl;
import '../share/attachments.dart'
    show copyToAppDir, resolveLocalMediaSrc, toLocalMediaUrl;
import '../share/note_composer.dart' show NoteSegment;
import '../share/note_video_policy.dart';
import '../share/quick_note_span_codec.dart';
import '../share/quick_note_text_actions.dart' show deriveLineRuns, seedTextTruth;
import 'theme/block_presentation.dart' show BlockKind, blockPresentationOf, lineKindOf;
import 'audio_playback_service.dart';
import 'audio_record_sheet.dart';
import 'format_dial.dart';
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



/// 悬浮球打字退隐后的恢复停顿（停笔多久渐显回来）。
const Duration kHubDimRestoreDelay = Duration(milliseconds: 1500);



/// 硬件键盘撤销/重做意图（挂编辑器顶层 Shortcuts，见 build）。
class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

/// 悬浮球停靠缘（四缘吸附持久化维度之一；另一维=缘上分数位置）。
enum _DockEdge { left, right, top, bottom }

/// 悬浮球边长（MD 最小触控 48dp；SmartFloatingHub.size 同值）。
const double _hubSize = 48;



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

  /// 转盘面板显隐：点圆钮展开；空选松手/选完生效即收；写作区失焦延时自动收。
  bool _formatSheetOpen = false;

  /// 转盘展开期写作区失焦自动闭合（2026-10-03 拍板「失去区域焦点一段时间
  /// 之后闭合，而不是点击空白」）：任一文本段失焦且全场无焦点时武装一次性
  /// 延时器，期间焦点回到写作区即撤销；替代旧「点空白收合」全屏命中层
  ///（命中层吞掉列表滚动/点按，且语义上空白不该是唯一出口）。
  Timer? _dialBlurTimer;
  static const Duration _dialBlurCloseDelay = Duration(milliseconds: 1500);

  /// 分级退场 pending（V11）：非 null = 转盘正播退场动画，播完（onExitDone）
  /// 才摘除面板。打字即收=keyPressed（80ms）、失焦超时=timeout（400ms）。
  DialDismissReason? _dialPendingClose;

  /// 悬浮球停靠位（2026-10-04 四缘吸附拍板）：缘 + 缘上分数位置。持久化
  /// key 与速记条历史同源（旧 `quick_note_dial_dock_left` 布尔键首次恢复
  /// 时迁移）——速记与详情编辑共享同一停靠记忆。
  static const String _kDialDockEdgeKey = 'quick_note_dial_dock_edge';
  static const String _kDialDockFracKey = 'quick_note_dial_dock_frac';
  static const String _kDialDockLeftLegacyKey = 'quick_note_dial_dock_left';
  static (_DockEdge, double)? _dialDockPersisted;
  _DockEdge _dialDockEdge = _dialDockPersisted?.$1 ?? _DockEdge.right;

  /// 缘上分数（0=缘起点，1=缘终点；默认 1 = 右缘下段，与旧版默认位同址）。
  double _dialDockFrac = _dialDockPersisted?.$2 ?? 1.0;

  /// 悬浮球拖拽边界（顶层 Stack LayoutBuilder 实测写入；null=未布局）。
  Rect? _hubBounds;

  /// 悬浮球位置（SmartFloatingHub SSOT）：dx=-1 为未初始化哨兵，首次布局
  /// 或边界尺寸变化时按 [_dialDockEdge]×[_dialDockFrac] 重播种（键盘起落
  /// /旋转后相对位置随分数保持）；拖拽/吸附由组件写入，松手回写停靠位。
  final ValueNotifier<Offset> _hubPos = ValueNotifier(const Offset(-1, 0));

  bool _sending = false;

  /// 相册长视频「仍要添加」确认后暂存的落盘路径（>5min 非阻断流专用）。
  String? _pendingVideoPath;

  @override
  void initState() {
    super.initState();
    _lifecycleSub = AppLifecycleManager.instance.states.listen((s) {
      if (s == AppLifecycleState.resumed) _closeFormatDial();
    }); // ④ 切后台回来自动收盘
    unawaited(_restoreDialDock());
    _doc = ComposerDoc(widget.initialRows); // 引擎构造即重建段序列 + 设撤销基线
    // 失焦自动闭合转盘：全局焦点变化 → 全场无焦点即武装延时器（期间回焦撤销）
    WidgetsBinding.instance.focusManager.addListener(_onFocusChanged);
  }

  /// 全场焦点扫描：任一文本段持有焦点=true（转盘手势/系统弹层不触发）。
  bool _anyTextFocused() =>
      _doc.segs.any((s) => s is NoteTextSeg && s.focus.hasFocus);

  void _onFocusChanged() {
    // 记录当前焦点段 id（活跃段真相源）；无焦点段时不改写，保留上次值。
    for (final s in _doc.segs) {
      if (s is NoteTextSeg && s.focus.hasFocus) {
        _doc.activeSegId = s.id;
        break;
      }
    }
    if (!_anyTextFocused()) _undimHub(); // 焦点离场：球恢复常显
    if (!_formatSheetOpen) return;
    if (_anyTextFocused()) {
      _dialBlurTimer?.cancel();
      _dialBlurTimer = null;
    } else {
      _dialBlurTimer ??= Timer(_dialBlurCloseDelay, () {
        _dialBlurTimer = null;
        if (mounted && _formatSheetOpen && !_anyTextFocused()) {
          // 超时闭合（V11）：400ms 柔和收缩退场，播完摘除
          setState(() => _dialPendingClose = DialDismissReason.timeout);
        }
      });
    }
  }

  /// 外部意图收盘（返回键/拖动滚动/动作行/切后台，2026-10-05 拍板四路径）：
  /// 统一走分级退场管道（keyPressed 同级极速淡出），挂起反悔的「打断=强
  /// 确认」由转盘内部处置——外部收盘绝不丢已选项。
  void _closeFormatDial() {
    if (!_formatSheetOpen || _dialPendingClose != null) return;
    _dialBlurTimer?.cancel();
    _dialBlurTimer = null;
    setState(() => _dialPendingClose = DialDismissReason.keyPressed);
  }

  @override
  void dispose() {
    _dialDockPersisted = (_dialDockEdge, _dialDockFrac);
    _lifecycleSub?.cancel();
    WidgetsBinding.instance.focusManager.removeListener(_onFocusChanged);
    _hubPos.dispose();
    _hubDimTimer?.cancel();
    _dialBlurTimer?.cancel();
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


  /// 悬浮球打字退隐（输入阻碍审计 P3：球停在文字边缘会盖字/压选择手柄）：
  /// 打字期间降透明度让位正文，停顿 [kHubDimRestoreDelay] 渐显回来。
  bool _hubDimmed = false;
  Timer? _hubDimTimer;





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

  /// 把引擎 [EditOutcome] 反射为 UI 副作用：悬浮球退隐（打字）、重建（结构
  /// 变更/撤销钮翻转）、焦点（经 segId 定位，绝不持有 FocusNode）、帧尾释放
  /// 被并段、落盘/保存回调。引擎只认 id/offset（拆解 P1b 边界）。
  void _applyOutcome(EditOutcome? out, {bool textEdited = false}) {
    if (out == null) return;
    if (textEdited || out.textEdited) _dimHubWhileTyping();
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
    _doc.applyTextEdit(seg, seg.ctrl.value, activeMarks: _activeMarks.toList());
    // 文字变更恒触发悬浮球退隐（打字即收，与原文案一致——引擎纯逻辑不替 UI
    // 决定退隐，故此处显式声明 textEdited）。
    _applyOutcome(_doc.consumeOutcome(), textEdited: true);
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

  /// 激活角标文本：mark 优先（2026-10-04 单选拍板后恒单项），无 mark 显
  /// 档位（H1/H2）。
  String? _dialBadge(int level) {
    if (_activeMarks.isNotEmpty) {
      const abbr = <InlineMark, String>{
        InlineMark.bold: 'B',
        InlineMark.italic: 'I',
        InlineMark.underline: 'U',
      };
      return [
        for (final m in _activeMarks)
          if (abbr[m] != null) abbr[m]!,
      ].join('·');
    }
    return switch (level) {
      1 => 'H1',
      2 => 'H2',
      _ => null, // 正文档位不外显
    };
  }

  /// 档位选择（转盘 标题扇区 H1/H2、正文直选）：纯逻辑委托 [_doc]，引擎写/删
  /// `# ` 前缀——标记本就在文本里（文本真相），结果经 [EditOutcome] 反射
  /// 焦点/重建/落盘。
  void _pickLevel(int level) {
    final seg = _doc.activeText;
    if (seg == null) return;
    _doc.setListLevel(seg, level);
    _applyOutcome(_doc.consumeOutcome());
  }

  /// 行内 mark 开关（高困惑 #2 修复：选区与未来输入分流）：
  /// - 有选区 → 直接套到选中文字（[ComposerDoc.applyMarkToSelection]），随即收转盘；
  /// - 塌缩 → 激活 mark，作用于之后输入的文字（原「先选后打」模型保留）。
  /// 单选制（B/I/U 互斥，新选替换旧选，再点同项关闭）不变。
  void _toggleMark(InlineMark mark) {
    final seg = _doc.activeText;
    if (seg != null && !seg.ctrl.selection.isCollapsed) {
      _doc.applyMarkToSelection(seg, mark);
      _applyOutcome(_doc.consumeOutcome());
      _closeFormatDial();
      return;
    }
    setState(() {
      if (!_activeMarks.remove(mark)) {
        _activeMarks
          ..clear()
          ..add(mark);
      }
    });
    _dialFocusWriting();
  }

  /// 转盘手势期把焦点拉回写作区（键盘保持弹出）：三级联动瞬间与选完格式
  /// 之后调用——2026-10-03 拍板「选完格式有键盘事件，转盘自动闭合」的
  /// 键盘侧实现（转盘闭合由选择回调内的收合完成）。
  void _dialFocusWriting() {
    _activeText?.focus.requestFocus();
  }

  /// 悬浮球打字退隐：打字即降透明度让位正文，停顿后渐显恢复。
  void _dimHubWhileTyping() {
    _hubDimTimer?.cancel();
    if (!_hubDimmed) setState(() => _hubDimmed = true);
    _hubDimTimer = Timer(kHubDimRestoreDelay, () {
      if (mounted && _hubDimmed) setState(() => _hubDimmed = false);
    });
  }

  void _undimHub() {
    _hubDimTimer?.cancel();
    _hubDimTimer = null;
    if (_hubDimmed) setState(() => _hubDimmed = false);
  }

  // ---------- 内部：转盘停靠（四缘吸附） ----------

  /// 停靠位 → 球左上角坐标（相对拖拽边界顶左；分数沿缘映射到可动程）。
  Offset _dockOffset(Rect bounds) {
    final maxX = (bounds.width - _hubSize).clamp(0.0, double.infinity);
    final maxY = (bounds.height - _hubSize).clamp(0.0, double.infinity);
    final along = _dialDockFrac.clamp(0.0, 1.0);
    return switch (_dialDockEdge) {
      _DockEdge.left => Offset(0, maxY * along),
      _DockEdge.right => Offset(maxX, maxY * along),
      _DockEdge.top => Offset(maxX * along, 0),
      _DockEdge.bottom => Offset(maxX * along, maxY),
    };
  }

  /// 球位（吸附后）→ 停靠位（缘=球心距最近边，分数=另一轴可动程占比）。
  void _syncDockFromHubPos() {
    final b = _hubBounds;
    if (b == null) return;
    final p = _hubPos.value;
    final maxX = (b.width - _hubSize).clamp(0.0, double.infinity);
    final maxY = (b.height - _hubSize).clamp(0.0, double.infinity);
    final dLeft = p.dx, dRight = maxX - p.dx;
    final dTop = p.dy, dBottom = maxY - p.dy;
    if (math.min(dLeft, dRight) <= math.min(dTop, dBottom)) {
      _dialDockEdge = dLeft <= dRight ? _DockEdge.left : _DockEdge.right;
      _dialDockFrac = maxY <= 0 ? 0 : (p.dy / maxY).clamp(0.0, 1.0);
    } else {
      _dialDockEdge = dTop <= dBottom ? _DockEdge.top : _DockEdge.bottom;
      _dialDockFrac = maxX <= 0 ? 0 : (p.dx / maxX).clamp(0.0, 1.0);
    }
  }

  /// 拖拽松手（吸附落定）→ 回写停靠位并持久化（SmartFloatingHub.onDragEnd）。
  Future<void> _persistDialDock() async {
    _syncDockFromHubPos();
    _dialDockPersisted = (_dialDockEdge, _dialDockFrac);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDialDockEdgeKey, _dialDockEdge.name);
    await prefs.setDouble(_kDialDockFracKey, _dialDockFrac);
  }

  /// 恢复停靠位（新键缺失时迁移旧布尔键；无历史保持默认右下=旧默认位）。
  Future<void> _restoreDialDock() async {
    final prefs = await SharedPreferences.getInstance();
    final edgeName = prefs.getString(_kDialDockEdgeKey);
    _DockEdge? edge;
    double frac = 1.0;
    if (edgeName != null) {
      for (final v in _DockEdge.values) {
        if (v.name == edgeName) edge = v;
      }
      frac = prefs.getDouble(_kDialDockFracKey) ?? 1.0;
    } else {
      final legacyLeft = prefs.getBool(_kDialDockLeftLegacyKey);
      if (legacyLeft != null) {
        edge = legacyLeft ? _DockEdge.left : _DockEdge.right;
      }
    }
    final resolved = edge;
    if (resolved == null || !mounted) return;
    setState(() {
      _dialDockEdge = resolved;
      _dialDockFrac = frac;
      final b = _hubBounds;
      if (b != null) _hubPos.value = _dockOffset(b);
    });
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
          // ① 返回键/侧滑手势：转盘开着先收盘（分级退场），再按才走页面返回
          canPop: !_formatSheetOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeFormatDial();
          },
          child: LayoutBuilder(
            builder: (context, cons) {
              // 悬浮球拖拽边界 = 作曲层视口（工具层上沿以上）：四缘吸附的「缘」
              // 即写作区四边——底缘吸附落在动作行上沿，永不遮动作行图标
              final bounds = Rect.fromLTWH(
                0,
                0,
                cons.maxWidth,
                math.max(0, cons.maxHeight - kComposerToolLayerHeight),
              );
              // 首次布局（哨兵 dx=-1）或边界尺寸变化（键盘起落/旋转）：按停靠
              // 位（缘×分数）重播种，相对位置随分数保持；拖拽期边界不变不抢拽
              if (_hubPos.value.dx < 0 ||
                  _hubBounds == null ||
                  _hubBounds!.size != bounds.size) {
                _hubPos.value = _dockOffset(bounds);
              }
              _hubBounds = bounds;
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
                  // 选区口径明示条（骑在工具层上沿）。**必须恒为 Positioned**——
                  // Stack 里出现非 Positioned 的子节点会改变 Stack 自身尺寸
                  // 计算，整层命中测试随之失效（空白点击/点球双双哑火，实测）。
                  _selectionHint(scheme),
                  // 悬浮球（收起态常驻「Tt」，全域拖动四缘吸附——2026-10-04 拍板）
                  _hub(bounds, scheme, Theme.of(context).textTheme),
                  // 转盘面板挂顶层 Stack（bounded + Clip.none 约束已封装在本组件内）。
                  // 收合出口：空选松手/选完生效/hub 回根 + 失焦 1.5s 自动闭合
                  //（2026-10-03 拍板：不再用「点空白」全屏命中层——它吞列表滚动与
                  // 外部点按，且语义上闭合不该依赖点空白）。
                  ?_formatDialPanel(scheme, bounds),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 提示条的「隐藏态」：占位必须是 **Positioned + 零尺寸**（见 Stack 命中
  /// 纪律），绝不能退化成裸 SizedBox——那会被 Stack 当成非定位子节点。
  static const Widget _hintPlaceholder = Positioned(
    left: 0,
    top: 0,
    child: SizedBox.shrink(),
  );

  /// 格式口径提示条（高困惑 #2 修复后口径更新）：
  /// - 有选区：标记直接套到选中文字，无需提示；
  /// - 塌缩：说明「格式将作用于之后输入的文字」（先选后打模型保留）。
  /// 只在转盘展开期出现，不打扰平时书写。
  Widget _selectionHint(ColorScheme scheme) {
    if (!_formatSheetOpen) return _hintPlaceholder;
    final seg = _activeText;
    if (seg == null) return _hintPlaceholder;
    return ListenableBuilder(
      listenable: seg.ctrl,
      builder: (context, _) {
        if (!seg.ctrl.selection.isCollapsed) return _hintPlaceholder;
        return Positioned(
          left: 0,
          right: 0,
          bottom: kComposerToolLayerHeight,
          child: IgnorePointer(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.lg,
                vertical: Insets.sm,
              ),
              color: scheme.surfaceContainerHighest,
              child: Text(
                '格式将作用于之后输入的文字',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      },
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
          // 打字即时收（V11）：指尖触键菜单即灭——80ms 极速淡出退场，
          // 不挡光标处候选框；播完（onExitDone）才真正摘除
          if (_formatSheetOpen && _dialPendingClose == null) {
            _dialBlurTimer?.cancel();
            _dialBlurTimer = null;
            setState(() => _dialPendingClose = DialDismissReason.keyPressed);
          }
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

  /// 聚焦段语义角标（问题#1 引导层·Step 1 只读侧轨）：仅当前段获得焦点时在段首
  /// 呈现 24dp 弱化角标（H1 / H2 / ▎ / T），失焦宽度收为 0，绝不挤压 360dp 正文。
  /// 列表/待办行已有常驻左侧凹槽（•/☑/序号，见 [_withListGutter]），不重复占宽。
  Widget _withFocusBadge(NoteTextSeg seg, Widget child) {
    return ListenableBuilder(
      listenable: seg.focus,
      builder: (context, _) {
        final focused = seg.focus.hasFocus;
        final isList = seg.spans.listRuns.isNotEmpty;
        final show = focused && !isList;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: show ? 24 : 0,
              child: show ? _focusBadge(seg) : null,
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
        return SizedBox(
          width: 24,
          height: 24,
          child: Center(child: Text(spec.badge, style: badgeStyle, maxLines: 1)),
        );
      },
    );
  }

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
          showSlider: true,
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

  /// 悬浮球：SmartFloatingHub 全域拖动 + 四缘吸附（收起态常驻「Tt」）——
  /// 拖拽/磁吸/tap 分流在通用组件，本层只剩业务接线：点按开合转盘、
  /// 松手回写停靠位并持久化。展开期藏球（转盘 hub 即格式按钮本体）。
  Widget _hub(Rect bounds, ColorScheme scheme, TextTheme textTheme) {
    final active = _activeText;
    final seg = active?.spans;
    final caret = seg == null ? 0 : (seg.selExtent).clamp(0, seg.plain.length);
    final level = seg == null ? 0 : quickNoteLevelAt(seg, caret);
    final badge = _dialBadge(level);
    final litNow = level > 0 || _activeMarks.isNotEmpty;
    return SmartFloatingHub(
      positionNotifier: _hubPos,
      bounds: bounds,
      size: const Size(_hubSize, _hubSize),
      onTap: () {
        _undimHub(); // 主动点球 = 要用它，立即恢复常显可点（否则退隐期吞点击）
        setState(() => _formatSheetOpen = !_formatSheetOpen);
        _activeText?.focus.requestFocus(); // 点按抢焦点，拉回写作区
      },
      onDragEnd: _persistDialDock, // 吸附落定 → 停靠位回写+持久化
      child: ListenableBuilder(
        listenable: Listenable.merge([if (active != null) active.ctrl]),
        builder: (context, _) {
          // 展开期藏球：转盘内整圆 hub 即格式按钮本体（同位同职责，
          // 双显会重叠出「两个按钮」——真机实证）
          if (_formatSheetOpen) return const SizedBox.shrink();
          // 退隐期不仅「看不见」，还必须**不可命中**：球压住选择手柄或吞掉
          // 正文点击，比视觉遮挡更致命（P3-2 的真实痛点）。
          return IgnorePointer(
            ignoring: _hubDimmed,
            child: AnimatedOpacity(
              opacity: _hubDimmed ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 240),
              child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 球面本体：激活点亮 primaryContainer
              Semantics(
                // 无障碍（ui-spec §6.0）：自绘 hub 无语义文本，补中文 label
                button: true,
                label: '格式工具，点按展开格式转盘',
                child: Container(
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(
                    color: litNow
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    shape: const CircleBorder(),
                  ),
                  child: Text(
                    'Tt',
                    // 装饰字形（非正文排版）：整档取 M3 titleSmall（=14，与原
                    // 裸字面量同值），不写 fontSize 字面量（arch-guard R7）
                    style: (textTheme.titleSmall ?? const TextStyle()).copyWith(
                      fontWeight: FontWeight.w700,
                      color: litNow
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              // 激活角标（收起后仍可见）
              if (badge != null)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: ShapeDecoration(
                      color: scheme.primary,
                      // 全系统去胶囊（ui-spec §2.3）：Stadium 退役，角标属小件走
                      // Radii.sm——高度约 13px，md12 会超过半径一半成伪装胶囊。
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(Radii.sm),
                        ),
                      ),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 格式转盘面板（点圆钮展开、点空白/空选松手收合）。
  ///
  /// 组件已配置化（DialSpec，缺省=默认菜单与真机定标几何）；宿主只负责
  /// 语义映射：分类/叶子 index → 档位与 mark 落地（Aa=0 直选正文、
  /// H=0 三级 H1/H2、BIU=2 三级 B/I/U）。
  Widget? _formatDialPanel(ColorScheme scheme, Rect bounds) {
    final active = _activeText;
    if (!_formatSheetOpen || active == null) return null;
    final seg = active.spans;
    final caret = (seg.selExtent).clamp(0, seg.plain.length);
    final level = quickNoteLevelAt(seg, caret);
    final badge = _dialBadge(level);
    const inlineMarks = [
      InlineMark.bold,
      InlineMark.italic,
      InlineMark.underline,
    ];
    // 面板定位（2026-10-04 四缘吸附）：hub 圆心 = 悬浮球球心，面板内锚点
    // 位置由象限给（FormatDial.anchorInPanel 同一数学，不宿主重推）；扇出
    // 象限 = 水平/竖直各取朝屏内半区（向手心泛化到四缘）
    final hubCenter = _hubPos.value + const Offset(_hubSize / 2, _hubSize / 2);
    final openRight = hubCenter.dx < bounds.center.dx;
    final openDown = hubCenter.dy < bounds.center.dy;
    final side = switch ((openRight, openDown)) {
      (true, true) => DialSide.downRight,
      (true, false) => DialSide.upRight,
      (false, true) => DialSide.downLeft,
      (false, false) => DialSide.upLeft,
    };
    const geo = DialGeometry();
    final panelSize = FormatDial.panelSize(geo);
    final anchor = FormatDial.anchorInPanel(panelSize, side, geo);
    return Positioned(
      left: hubCenter.dx - anchor.dx,
      top: hubCenter.dy - anchor.dy,
      child: Material(
        color: Colors.transparent,
        child: FormatDial(
          side: side,
          currentLabel: badge ?? 'Aa', // hub 盘面字：正文档位业界标识
          hubLit: level > 0 || _activeMarks.isNotEmpty,
          disabledCategories: level > 0 ? const {2} : null, // 互斥：标题行行内盘置灰
          onCategorySelect: (_) => _pickLevel(0), // Aa 直选正文
          onLeafSelect: (cat, leaf) => switch (cat) {
            0 => _pickLevel(leaf == 0 ? 1 : 2), // H → H1/H2
            _ => _toggleMark(inlineMarks[leaf]), // BIU → B/I/U
          },
          appliedInner: {
            if (level > 0) 0 else 1,
            if (_activeMarks.isNotEmpty) 2,
          },
          appliedLeaf: {
            0: {if (level == 1) 0, if (level == 2) 1},
            2: {
              for (var i = 0; i < inlineMarks.length; i++)
                if (_activeMarks.contains(inlineMarks[i])) i,
            },
          },
          // 三级随二级联动瞬间 + 选完生效时拉回键盘（2026-10-03 拍板）
          onLeavesChanged: _dialFocusWriting,
          // 分级退场（V11）：带原因进 pending，转盘播完动画再摘除
          onDismiss: (reason) => setState(() => _dialPendingClose = reason),
          closing: _dialPendingClose,
          onExitDone: () => setState(() {
            _formatSheetOpen = false;
            _dialPendingClose = null;
          }),
        ),
      ),
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

  /// 动作行：拍照 / 相册 / 录音 / 视频（/ 标签——速记条启用）。
  /// 拍照与相册是**就地插图**；视频入口收敛为二选一面板（相册首位）。
  Widget _actionRow(ColorScheme scheme) {
    final pendingTags = widget.pendingTags;
    final showTags = widget.onPendingTagsChanged != null;
    return SizedBox(
      height: kComposerToolLayerHeight,
      child: Row(
        children: [
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
          IconButton(
            onPressed: _softBreak,
            icon: const Icon(Icons.wrap_text),
            tooltip: '换行（列表内续行）',
          ),
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
          if (showTags)
            IconButton(
              onPressed: _sending ? null : _pickTags,
              icon: Badge(
                isLabelVisible: pendingTags != null && pendingTags.isNotEmpty,
                label: Text('${pendingTags?.length ?? 0}'),
                child: const Icon(Icons.tag),
              ),
              tooltip: '标签',
            ),
          // 待办模式入口已移除（2026-10-03 用户拍板「去掉待办列表」）。
          // 标签文本吃剩余空间（Expanded）：窄屏下恒不溢出——固定子项过多
          // 时文本收缩为 0，比 ConstrainedBox 的硬宽度安全。
          if (showTags && pendingTags != null && pendingTags.isNotEmpty)
            Expanded(
              child: Text(
                pendingTags.map((t) => '#$t').join(' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }
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
