// 编辑器内容引擎（拆解 P1b，2026-10-07）：段序列 + 撤销栈 + 文本/结构编辑
// 纯逻辑，独立于 State 的挂载 / 焦点 / 重建 / 落盘。
//
// 边界（方案 A）：引擎直接持有 [NoteSeg]（含 ctrl/focus 引用，段模型不动以免
// 破坏现有 widget 测试），但**不操作焦点（不 requestFocus）、不 setState、不
// 调用宿主回调**——这些由 State 据 [EditOutcome] 反射。引擎改完段状态后把
// 结果累积进 `_pending`，State 经 [consumeOutcome] 取走并统一做焦点/重建/落盘/
// 撤销钮态。撤消合并等重入场景靠 [EditOutcome.merge] 累积（OR），不会覆盖丢失。
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show KeyEventResult;

import '../doc/rich_text.dart'
    show
        InlineMark,
        InlineRun,
        SpanListRun,
        adjustRuns,
        spanChangeRange,
        toggleInlineMarkRuns;
import '../share/attachments.dart' show MediaTrashSession;
import '../share/note_seg.dart'
    show
        NoteMediaKind,
        NoteMediaSeg,
        NoteSeg,
        NoteTextSeg,
        kUndoCap,
        kUndoCoalesce,
        noteSegsToDraftRows;
import '../share/quick_note_span_codec.dart';
import '../share/quick_note_line_shape.dart' show parseLine;
import '../share/quick_note_text_actions.dart'
    show
        LineKindTarget,
        TextActionResult,
        TextEditKind,
        backspaceOutdent,
        deriveLineRuns,
        enterWithMarker,
        planTextEdit,
        renumberOrderedGroup,
        setLineKindAction,
        setLineLevel;
import '../share/quick_note_text_actions.dart' as qa
    show detectStructuralDeletion, toggleTodo;

/// 引擎编辑结果：State 据其反射焦点/重建/落盘/撤销钮态。引擎只认 segId +
/// offset，绝不持有 FocusNode（P1b 拆解边界）。
class EditOutcome {
  const EditOutcome({
    this.focusSegId,
    this.focusCaret = -1,
    this.needsRebuild = false,
    this.undoRedoChanged = false,
    this.textEdited = false,
    this.clearActiveMarks = false,
    this.removedSegs = const [],
  });

  final String? focusSegId;
  final int focusCaret;
  final bool needsRebuild;
  final bool undoRedoChanged;
  final bool textEdited;
  final bool clearActiveMarks;

  /// 已被引擎从序列移除、待 State 帧尾 dispose 的段（合并/媒体移除产生的
  /// 孤立文本段；其 TextField 需先随重建卸载再回收，dispose 顺序不能倒）。
  final List<NoteSeg> removedSegs;

  EditOutcome merge(EditOutcome o) => EditOutcome(
        focusSegId: o.focusSegId ?? focusSegId,
        focusCaret: o.focusSegId != null ? o.focusCaret : focusCaret,
        needsRebuild: needsRebuild || o.needsRebuild,
        undoRedoChanged: undoRedoChanged || o.undoRedoChanged,
        textEdited: textEdited || o.textEdited,
        clearActiveMarks: clearActiveMarks || o.clearActiveMarks,
        removedSegs: [...removedSegs, ...o.removedSegs],
      );
}

/// 编辑操作日志（阶段二 ops 日志化蓄力，为阶段三接 CRDT/OT 铺路）：把
/// 编辑动作显式化为纯操作序列——状态机退化为 `InsertText(pos,'a')` /
/// `FormatRange(start,end,Bold)` 形态，未来可无缝映射 Yjs/Automerge/服务端 OT。
///
/// 与撤销栈（快照制）解耦：opLog 是**增量审计流**，恒追加、不参与撤销/重做、
/// 不改变任何文本/光标/渲染行为（仅记录，引擎其余逻辑零改动）。每条 op 携带
/// [segId] 以对应文本真相下可增删的段，未来按段重放/对账即可。
sealed class EditOp {
  const EditOp();

  /// 操作作用的段 id（文本真相下段可增删；携带 segId 以便未来按段重放/对账）。
  String get segId;
}

/// 纯文本插入（IME 拼音落定 / 打字 / 粘贴选区替换的插入段）。
class InsertTextOp extends EditOp {
  const InsertTextOp(this.segId, this.pos, this.text);
  @override final String segId;
  final int pos;
  final String text;
}

/// 纯文本删除（退格 / 删键 / 选区替换的删除段）。
class DeleteOp extends EditOp {
  const DeleteOp(this.segId, this.start, this.end);
  @override final String segId;
  final int start;
  final int end;
}

/// 行内格式切换（选区加粗/斜体/下划线/代码/链接/删除线/高亮）。
class FormatRangeOp extends EditOp {
  const FormatRangeOp(this.segId, this.start, this.end, this.mark);
  @override final String segId;
  final int start;
  final int end;
  final InlineMark mark;
}

/// 结构操作（段拆分/合并/换档/勾选/媒体增删/软换行等离散动作）。
class StructureOp extends EditOp {
  const StructureOp(this.segId, this.kind, {this.detail});
  @override final String segId;
  final String kind;

  /// 可选元数据（媒体 url、档位 level 等），供未来重放/观测。
  final String? detail;
}

/// 撤销快照：整编辑器草稿行 + 焦点段下标 + 光标偏移（快照制 undo/redo）。
class _UndoEntry {
  const _UndoEntry(this.rows, this.focusIndex, this.caret);

  final List<List<String>> rows;
  final int focusIndex;
  final int caret;
}

class ComposerDoc {
  ComposerDoc(List<List<String>> initialRows) {
    _rebuildSegs(initialRows);
    _ensureTrailingText();
    _present = _snapshot();
  }

  // ---------- 段序列 + 撤消栈（引擎持有，State 经 getter 只读访问） ----------
  final List<NoteSeg> segs = [];
  String? activeSegId;

  /// 编辑操作日志（阶段二 ops 日志化蓄力）：每个编辑动作追加一条 [EditOp]，
  /// 恒追加、不参与撤销/重做、零行为变更。环形保留最近 [kOpLogCap] 条。
  final List<EditOp> opLog = [];
  static const int kOpLogCap = 200;

  void _recordOp(EditOp op) {
    opLog.add(op);
    if (opLog.length > kOpLogCap) opLog.removeAt(0);
  }

  final List<_UndoEntry> _undoStack = [];
  final List<_UndoEntry> _redoStack = [];
  _UndoEntry? _present;
  DateTime _presentAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _presentWasTextEdit = false;

  /// 媒体回收站会话（移除媒体=入桶延迟删除，撤销移除还原文件）：桶按
  /// 媒体父目录各自建立，dispose 清本会话桶；账目=原绝对路径→回收站路径。
  final MediaTrashSession _mediaTrash = MediaTrashSession();
  final Map<String, String> _mediaTrashByPath = {};

  /// 草稿行快照缓存（P2 性能防线）：文字连击只重序列化变更段，未动段复用。
  final Map<NoteSeg, List<String>> _segRowsCache = {};

  EditOutcome? _pending;

  // ---------- 对外查询 ----------
  NoteTextSeg? get activeText {
    // 活跃段以 UI 注入的 id 为准（替代 hasFocus 轮询）；无焦点态/装载后回退
    // 最后一段文本（与焦点轮询「无焦点=末段」语义一致）。
    if (activeSegId != null) {
      for (final s in segs) {
        if (s is NoteTextSeg && s.id == activeSegId) return s;
      }
    }
    final idx = segs.lastIndexWhere((s) => s is NoteTextSeg);
    if (idx < 0) return null;
    return segs[idx] as NoteTextSeg;
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 草稿行编码（changedSegId 命中则只重序列化该段，复用缓存）。
  List<List<String>> toRows([String? changedSegId]) {
    NoteSeg? changed;
    if (changedSegId != null) {
      for (final s in segs) {
        if (s is NoteTextSeg && s.id == changedSegId) {
          changed = s;
          break;
        }
      }
    }
    if (changed == null) _segRowsCache.clear();
    return [
      for (final s in segs)
        if (identical(s, changed))
          _segRowsCache[s] = noteSegsToDraftRows([s]).single
        else
          _segRowsCache[s] ??= noteSegsToDraftRows([s]).single,
    ];
  }

  EditOutcome? consumeOutcome() {
    final o = _pending;
    _pending = null;
    // 结构导入/替换等仅 beginStructuralStep 记账、无终态 _mergePending 的路径，
    // 在此补刷 present=变更后态，保证重做回到正确 POST（与 _mergePending 同口径）。
    _present = _snapshot();
    return o;
  }

  void _mergePending(EditOutcome o) {
    _pending = _pending == null ? o : _pending!.merge(o);
    // 变更后刷新活态基线（present=变更后态）：撤销恢复 PRE、重做才能回到正确的
    // POST——这是文本真相下撤销/重做对称的关键（原 _onSegChanged 末尾
    // `_present = _snapshot()` 语义）。
    _present = _snapshot();
  }

  // ---------- 装载 / 重置 ----------
  /// 草稿行 → 段序列（初始/恢复共用）：`['t',md]` 文本段播种为无标记态
  ///（seedTextTruth 剥行内标记、保留线级前缀），媒体段第 3 位说明随段。
  void _rebuildSegs(List<List<String>> rows) {
    segs
      ..clear()
      ..addAll([
        for (final row in rows)
          switch (row.first) {
            'i' => NoteMediaSeg(
              row[1],
              kind: NoteMediaKind.image,
              label: row.length > 2 ? row[2] : '',
            ),
            'a' => NoteMediaSeg(
              row[1],
              kind: NoteMediaKind.audio,
              label: row.length > 2 ? row[2] : '',
            ),
            'v' => NoteMediaSeg(
              row[1],
              kind: NoteMediaKind.video,
              label: row.length > 2 ? row[2] : '',
            ),
            _ => NoteTextSeg(row.length > 1 ? row[1] : ''),
          },
      ]);
    // 装载重建：旧段全部释放（State 负责 dispose），活跃 id 失效——清空后活跃
    // 段回退末段（与 activeText「无焦点=末段」语义一致），焦点由 UI 后续注入。
    activeSegId = null;
    _segRowsCache.clear();
  }

  /// 不变量：媒体段之后恒有文本段（用户在媒体后继续书写）。
  void _ensureTrailingText() {
    if (segs.isEmpty || segs.last is NoteMediaSeg) segs.add(NoteTextSeg());
  }

  /// 草稿行快照重建段序列（宿主草稿恢复用；旧段全部释放由 State 负责 dispose，
  /// 不触发脏通知——装载不是用户变更）。撤消栈保留。
  void loadRows(List<List<String>> rows) {
    _rebuildSegs(rows);
    _ensureTrailingText();
  }

  /// 程序化整篇替换（AI 还原 / 恢复 AI 改动）：在 [loadRows] 之上额外清空
  /// 撤销/重做栈（程序化替换不是用户编辑，保留旧栈会让 Ctrl+Z 退回被替换版）。
  void replaceAll(List<List<String>> rows) {
    _rebuildSegs(rows);
    _ensureTrailingText();
    _undoStack.clear();
    _redoStack.clear();
    _present = _snapshot();
    _presentAt = DateTime.now();
    _presentWasTextEdit = false;
  }

  /// 释放所有文本段控制器/焦点 + 清回收站（State.dispose 调用）。
  void disposeAll() {
    for (final s in segs) {
      if (s is NoteTextSeg) s.dispose();
    }
    _mediaTrash.purge();
  }

  // ---------- 撤销/重做（快照制） ----------
  void undo() => _applyFrom(_undoStack, _redoStack);
  void redo() => _applyFrom(_redoStack, _undoStack);

  void _applyFrom(List<_UndoEntry> from, List<_UndoEntry> to) {
    final present = _present;
    if (from.isEmpty || present == null) {
      _mergePending(const EditOutcome());
      return;
    }
    final entry = from.removeLast();
    to.add(present);
    _present = entry;
    _presentAt = DateTime.now();
    _presentWasTextEdit = false; // 恢复后下一次输入恒开新步
    final beforePaths = {
      for (final s in segs)
        if (s is NoteMediaSeg) s.file.path,
    };
    _rebuildSegs(entry.rows);
    _ensureTrailingText();
    _syncMediaFiles(beforePaths); // 媒体文件对账（撤销移除还原/重做移除入桶）
    final i = entry.focusIndex;
    String? focusSegId;
    var focusCaret = 0;
    if (i >= 0 && i < segs.length) {
      final s = segs[i];
      if (s is NoteTextSeg) {
        focusCaret = entry.caret.clamp(0, s.spans.plain.length);
        s.spans
          ..selBase = focusCaret
          ..selExtent = focusCaret;
        focusSegId = s.id;
      }
    }
    // 撤销/重做恒重建（原 _applyFrom 末尾无条件 setState）+ 媒体对账可能改文件
    _mergePending(EditOutcome(
      focusSegId: focusSegId,
      focusCaret: focusCaret,
      needsRebuild: true,
    ));
  }

  _UndoEntry _snapshot() {
    var focusIndex = -1;
    var fallback = -1;
    var caret = 0;
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      if (s is! NoteTextSeg) continue;
      if (fallback < 0) fallback = i;
      if (activeSegId != null && s.id == activeSegId) {
        focusIndex = i;
        final sel = s.ctrl.selection;
        caret = sel.isCollapsed
            ? sel.extentOffset.clamp(0, s.spans.plain.length)
            : 0;
        break;
      }
    }
    if (focusIndex < 0) focusIndex = fallback;
    return _UndoEntry(noteSegsToDraftRows(segs), focusIndex, caret);
  }

  /// 变更点记账：textEdit=文字连击（可合并），否则结构步（恒独立入栈）。
  void _trackUndo({required bool textEdit}) {
    final now = DateTime.now();
    final coalesce =
        textEdit && _present != null && _presentWasTextEdit && now.difference(_presentAt) < kUndoCoalesce;
    final wasUndoEmpty = _undoStack.isEmpty;
    final wasRedoEmpty = _redoStack.isEmpty;
    if (!coalesce) {
      final present = _present;
      if (present != null) {
        _undoStack.add(present);
        if (_undoStack.length > kUndoCap) _undoStack.removeAt(0);
        _redoStack.clear();
      }
    }
    _present = _snapshot();
    _presentAt = now;
    _presentWasTextEdit = textEdit;
    final undoRedoChanged =
        _undoStack.isEmpty != wasUndoEmpty || _redoStack.isEmpty != wasRedoEmpty;
    _mergePending(EditOutcome(undoRedoChanged: undoRedoChanged));
  }

  /// 结构操作（媒体增删/段合并/换档/替换媒体）在**变更前**调用：把当前
  /// 活态（含真实焦点/光标）压入撤销栈。文字路径不能用它——文字变更点
  /// 时变更已应用，活态快照=变更后；而结构步的焦点段可能随变更离场（段首退格
  /// 合并），必须趁其在场时取快照。
  void beginStructuralStep({bool asTextEdit = false}) {
    final now = DateTime.now();
    // 回车拆段并入打字连击窗：连打带敲回车=一步撤销（asTextEdit 且窗口内）
    final coalesce =
        asTextEdit && _present != null && _presentWasTextEdit && now.difference(_presentAt) < kUndoCoalesce;
    final wasUndoEmpty = _undoStack.isEmpty;
    final wasRedoEmpty = _redoStack.isEmpty;
    if (!coalesce) {
      _undoStack.add(_snapshot());
      if (_undoStack.length > kUndoCap) _undoStack.removeAt(0);
      _redoStack.clear();
    }
    _present = _snapshot(); // 此刻尚未变更，present=变更前活态
    _presentAt = now;
    _presentWasTextEdit = asTextEdit; // 连击链延续
    final undoRedoChanged =
        _undoStack.isEmpty != wasUndoEmpty || _redoStack.isEmpty != wasRedoEmpty;
    _mergePending(EditOutcome(undoRedoChanged: undoRedoChanged));
  }

  // ---------- 文本变更点（原 _onSegChanged 纯逻辑） ----------
  /// 控制器文本 → 段状态随动（行内 runs 字符级 + 激活 mark 落插入段 + 行级
  /// 档位按行重 snap），选择区同源记账。
  void syncSegFromCtrl(NoteTextSeg seg, {List<InlineMark> activeMarks = const []}) {
    final text = seg.ctrl.text;
    final (s0, e0) = spanChangeRange(seg.spans.plain, text);
    final insLen = text.length - seg.spans.plain.length + (e0 - s0);
    seg.spans.runs = adjustRuns(seg.spans.runs, s0, e0, insLen);
    if (insLen > 0) {
      for (final m in activeMarks) {
        seg.spans.runs.add(InlineRun(s0, s0 + insLen, m));
      }
    }
    seg.spans.plain = text;
    deriveLineRuns(seg.spans);
    seg.spans
      ..selBase = seg.ctrl.selection.baseOffset
      ..selExtent = seg.ctrl.selection.extentOffset;
  }

  bool _isListLineAt(NoteTextSeg seg, int caret) {
    final line = quickNoteLineRangeAt(seg.spans, caret);
    return line != null && quickNoteListRunAt(seg.spans, line.$1) != null;
  }

  /// 文字变更点：UI 把 ctrl 的 next 交来，引擎算 plan、改 spans、按需拆/合段，
  /// 结果累积进 _pending（activeMarks=当前格式化激活态，落插入段用）。
  void applyTextEdit(
    NoteTextSeg seg,
    TextEditingValue next, {
    List<InlineMark> activeMarks = const [],
  }) {
    final oldPlain = seg.spans.plain;
    // 路径分流判据（纯函数，share 层表驱动单测钉住）：软键盘无 shift 语义、
    // 粘贴无按键事件，行级动作只能从**文本变更侧**判据，物理无修饰回车同路
    // 收敛。四条入口在此合一，判据不再散落到各分支里。
    final plan = planTextEdit(
      oldPlain: oldPlain,
      newText: next.text,
      composing: next.composing.isValid && !next.composing.isCollapsed,
      isListLineAt: (at) => _isListLineAt(seg, at),
    );
    // 非列表回车（打字/拆段）使空项退列 latch 失效；列表回车需在分支内自行维护。
    if (plan.kind != TextEditKind.listEnter) _armedEmptyExit = null;
    switch (plan.kind) {
      case TextEditKind.listEnter:
        // 与物理回车同源——去掉 IME 已插入的 \n，交给 enterWithMarker 统一
        // 决定（续标记/空项退出），再写回。
        beginStructuralStep(asTextEdit: true);
        final base = next.text.replaceRange(plan.start, plan.start + 1, '');
        // 中困惑 #C 防误退（软键盘主路）：空项首次回车回退插入的 \n，保留列表，
        // 需再按一次才退列；新建空项（latch 已武装）维持「再按即退」自然手势。
        final emptyStart = _emptyItemLineStartAt(base, plan.start);
        if (emptyStart != null && _armedEmptyExit != (seg.id, emptyStart)) {
          _armedEmptyExit = (seg.id, emptyStart);
          final keep = emptyStart + parseLine(base.substring(emptyStart)).markerEnd;
          seg.ctrl
            ..text = base
            ..selection = TextSelection.collapsed(offset: keep);
          seg.spans
            ..plain = base
            ..selBase = keep
            ..selExtent = keep;
          deriveLineRuns(seg.spans);
          _mergePending(const EditOutcome(textEdited: true));
          return;
        }
        final r = enterWithMarker(base, plan.start);
        final result = r ?? TextActionResult(next.text, plan.start + 1);
        _commitEnter(seg, result);
        _recordOp(StructureOp(seg.id, 'listEnter'));
        _mergePending(const EditOutcome(
          needsRebuild: true,
          clearActiveMarks: true,
        ));
        return;
      case TextEditKind.splitLines:
        // 先随动段状态（含 \n 的全文本），再按新插 \n 逐一物化为独立段；
        // undo 记账与打字同窗连击（连打带敲回车=一步）。
        syncSegFromCtrl(seg, activeMarks: activeMarks);
        beginStructuralStep(asTextEdit: true);
        _recordOp(StructureOp(seg.id, 'splitLines'));
        _materializeNewlines(seg, plan.start, plan.inserted);
        _mergePending(const EditOutcome(clearActiveMarks: true));
        return;
      case TextEditKind.inline:
        break; // 落到下方随动
      }
      // B+ 收口（治 #3 编辑期空洞序号）：删除型结构性变更（跨行/含 marker）在
      // 内存中一次性合成最终文本，与本次编辑原子落盘、记单步撤销；IME 组合态
      // 绝热（门禁1），普通删字 O(1) 放行（门禁2 detectStructuralDeletion）。
      var finalText = next.text;
      var finalCaret = next.selection.extentOffset;
      if (!next.composing.isValid && // 门禁1：组合态绝不重写文本
          qa.detectStructuralDeletion(oldPlain, next.text)) {
        final (rt, rc) = renumberOrderedGroup(next.text, finalCaret);
        finalText = rt;
        finalCaret = rc;
      }
      seg.ctrl
        ..text = finalText
        ..selection = TextSelection.collapsed(offset: finalCaret);
      // 「打字落定」由派生视图自动表达（`- ` 留在文本里即列表项）。
      syncSegFromCtrl(seg, activeMarks: activeMarks);
      // ops 日志：文本变更 = 插入/删除（据 LCS 夹出区间，与 _trackUndo 同口径）。
      final (s0, e0) = spanChangeRange(oldPlain, finalText);
      final insLen = finalText.length - oldPlain.length + (e0 - s0);
      if (insLen > 0) {
        _recordOp(InsertTextOp(seg.id, s0, finalText.substring(s0, s0 + insLen)));
      }
      if (e0 > s0) {
        _recordOp(DeleteOp(seg.id, s0, e0));
      }
      _trackUndo(textEdit: true);
  }

  /// 把本次插入的 `\n` 逐一物化为段边界：拆点=\n 前一位，`\n` 本体不进
  /// 任何段（run/level 按 splitQuickNoteSpansAt 分配两侧，标题档留上侧与
  /// 回车语义一致）。焦点/光标落最尾段末尾——打字=新空段段首、粘贴=续写位。
  void _materializeNewlines(NoteTextSeg seg, int start, String inserted) {
    var cur = seg;
    var base = 0; // cur.spans.plain 在变更后全文中的起始偏移
    for (var i = 0; i < inserted.length; i++) {
      if (inserted[i] != '\n') continue;
      final k = start + i;
      final local = k - base;
      if (local < 0 || local >= cur.spans.plain.length) continue;
      final (l, r0) = splitQuickNoteSpansAt(cur.spans, local);
      final (_, r) = splitQuickNoteSpansAt(r0, 1); // 丢弃 \n 本体
      cur.spans = l;
      // 段状态改写必须同步控制器文本（SpanTextEditingController.text 是显示
      // 与光标真相源，光改 spans 会让 TextField 显示旧全文、光标偏移越界）。
      cur.ctrl.text = l.plain;
      // 文本真相：拆段后重派生，保证 run 视图与各自 plain 逐行贴合（标记
      // 留在所在行，不跨段失真）。
      deriveLineRuns(cur.spans);
      final tail = NoteTextSeg()..spans = r;
      deriveLineRuns(tail.spans);
      tail.ctrl.text = r.plain;
      final idx = segs.indexOf(cur);
      segs.insert(idx + 1, tail);
      base = k + 1;
      cur = tail;
    }
    _mergePending(EditOutcome(
      focusSegId: cur.id,
      focusCaret: cur.spans.plain.length,
      needsRebuild: true,
      clearActiveMarks: true,
    ));
  }

  // ---------- 键盘路由（段变换内核，KeyEvent 解读在 State） ----------
  /// 段级按键门：Shift+Enter 块内软换行（手动插 \n，下一次文字变更不拆段）。
  void shiftEnter(NoteTextSeg seg) {
    final v = seg.ctrl.value;
    if (v.composing.isValid && !v.composing.isCollapsed) return;
    if (!v.selection.isCollapsed) return;
    final p = v.selection.extentOffset;
    // 程序化赋值不触发 onChanged（Flutter 只对用户编辑触发）——随动在此
    // 直接完成；若平台差异仍回调，重入 applyTextEdit 会再 syncSegFromCtrl
    // 一次（无变化），双跑安全。
    seg.ctrl.value = TextEditingValue(
      text: v.text.replaceRange(p, p, '\n'),
      selection: TextSelection.collapsed(offset: p + 1),
    );
    syncSegFromCtrl(seg);
    _recordOp(StructureOp(seg.id, 'shiftEnter'));
    _trackUndo(textEdit: true);
    _mergePending(const EditOutcome(textEdited: true));
  }

  /// 软换行（高困惑 #1/#3 统一入口）：块内插入换行不拆段。列表项内插 `\n  `
  ///（2 空格缩进 → 续行并入同一项，解决「多行同项 bullet 不可达」）；普通块插
  /// `\n`（软换行，移动端无 Shift 也可达）。
  void softNewline(NoteTextSeg seg) {
    final v = seg.ctrl.value;
    if (v.composing.isValid && !v.composing.isCollapsed) return;
    if (!v.selection.isCollapsed) return; // 选区软换行由替换路径处理
    final p = v.selection.extentOffset;
    final ins = _isListLineAt(seg, p) ? '\n  ' : '\n';
    seg.ctrl.value = TextEditingValue(
      text: v.text.replaceRange(p, p, ins),
      selection: TextSelection.collapsed(offset: p + ins.length),
    );
    syncSegFromCtrl(seg);
    _recordOp(StructureOp(seg.id, 'softNewline'));
    _trackUndo(textEdit: true);
    _mergePending(const EditOutcome(textEdited: true));
  }

  /// 空项退列防误退 latch（中困惑 #C）：空列表项首次回车不退出列表（双回车退列）。
  /// 按 `(段 id, 行首)` 作用域隔离防跨段误触；新建空项（上一回车刚生成）自动
  /// 武装，维持「再按即退」的自然双击离开手势。
  (String, int)? _armedEmptyExit;

  int _lineStartAt(String text, int caret) {
    var s = caret;
    while (s > 0 && text.codeUnitAt(s - 1) != 0x0A) {
      s--;
    }
    return s;
  }

  /// 光标所在行是空列表项 → 返回其行首；否则 null。用于防误退判定与 latch 维护。
  int? _emptyItemLineStartAt(String text, int caret) {
    final start = _lineStartAt(text, caret);
    final end = text.indexOf('\n', start);
    final lineEnd = end < 0 ? text.length : end;
    if (lineEnd <= start) return null; // 整行空（含 \n 本体）非列表项
    final shape = parseLine(text.substring(start, lineEnd));
    if (shape.isList && shape.bodyStart >= lineEnd - start) return start;
    return null;
  }

  /// 应用回车结果并维护空项退出 latch：结果在光标行留下空列表项 → 武装
  /// （下一次回车退出）；续行/退出则清武装。
  /// 应用回车结果并维护空项退出 latch；同时触发有序组局部重编号（B 专项）：
  /// 回车续项 / 空项退出改变组结构，编号立即物化进 buffer（动作层离散点，
  /// 绝不进 `_onSegChanged` 字符路径）。
  void _commitEnter(NoteTextSeg seg, TextActionResult r) {
    final (nt, nc) = renumberOrderedGroup(r.text, r.caret);
    seg.spans
      ..plain = nt
      ..selBase = nc
      ..selExtent = nc;
    seg.ctrl
      ..text = nt
      ..selection = TextSelection.collapsed(offset: nc);
    deriveLineRuns(seg.spans);
    final empty = _emptyItemLineStartAt(nt, nc);
    _armedEmptyExit = empty == null ? null : (seg.id, empty);
  }

  /// 回车落在列表行：不拆段，就地起新项 / 空项退出列表。返回键盘结果给 State。
  KeyEventResult enterOnListLine(NoteTextSeg seg) {
    final v = seg.ctrl.value;
    if (v.composing.isValid && !v.composing.isCollapsed) return KeyEventResult.ignored;
    if (!v.selection.isCollapsed) return KeyEventResult.ignored;
    final caret = v.selection.extentOffset;
    // 中困惑 #C 防误退：空列表项首次回车吞键保留列表，需再按一次才退列；
    // 新建空项（latch 已武装）维持「再按即退」自然双击离开手势。
    final emptyStart = _emptyItemLineStartAt(v.text, caret);
    if (emptyStart != null && _armedEmptyExit != (seg.id, emptyStart)) {
      _armedEmptyExit = (seg.id, emptyStart);
      return KeyEventResult.handled; // 吞键：文本不变，列表保留
    }
    // 文本真相：L1 动作写真实文本（enterWithMarker 统一决定续标记/空项退出）；
    // 不适用（纯文本行）→ 放行既有拆段（State 走 applyTextEdit 的 splitLines）。
    final r = enterWithMarker(v.text, caret);
    if (r != null) {
      beginStructuralStep(asTextEdit: true);
      _commitEnter(seg, r);
      _recordOp(StructureOp(seg.id, 'listEnter'));
      _mergePending(const EditOutcome(clearActiveMarks: true));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 行首退格出列/出挡：光标塌缩在标记行行首时删标记回正文。返回是否已处理。
  /// 行首退格出列/出挡：光标塌缩在标记行行首时删标记回正文。返回是否已处理。
  /// 有序项出列会改变组结构，编号立即重编（B 专项，动作层离散点）。
  bool backspaceOutdentAt(NoteTextSeg seg, int caret) {
    final v = seg.ctrl.value;
    final r = backspaceOutdent(v.text, caret);
    if (r == null) return false; // 非列表标记行（标记已被剥掉）
    beginStructuralStep(asTextEdit: true);
    final (nt, nc) = renumberOrderedGroup(r.text, r.caret);
    seg.spans
      ..plain = nt
      ..selBase = nc
      ..selExtent = nc;
    seg.ctrl
      ..text = nt
      ..selection = TextSelection.collapsed(offset: nc);
    deriveLineRuns(seg.spans);
    _recordOp(StructureOp(seg.id, 'backspaceOutdent'));
    _mergePending(const EditOutcome(clearActiveMarks: true));
    return true;
  }

  /// 把 [seg] 并入上一文本段 [prev]（段首退格合并）：spans 平移拼接
  ///（runs/levels 零丢失），光标落合并点=prev 文末；被并段加入 removedSegs
  /// 交给 State 帧尾 dispose。
  void mergeIntoPrev(NoteTextSeg seg, NoteTextSeg prev) {
    final i = segs.indexOf(seg);
    if (i <= 0 || segs[i - 1] != prev) return;
    beginStructuralStep();
    mergeQuickNoteSpansInto(prev.spans, seg.spans);
    prev.spans
      ..selBase = prev.spans.plain.length
      ..selExtent = prev.spans.plain.length;
    prev.ctrl
      ..text = prev.spans.plain
      ..selection = TextSelection.collapsed(offset: prev.spans.plain.length);
    segs.removeAt(i);
    // 活跃段 id 随并段迁移到宿主段（被并段即将 dispose，否则下次快照按末段
    // 回退，与焦点实际落点错位）。
    if (activeSegId == seg.id) activeSegId = prev.id;
    _ensureTrailingText();
    _recordOp(StructureOp(seg.id, 'mergeIntoPrev', detail: prev.id));
    _mergePending(EditOutcome(
      focusSegId: prev.id,
      focusCaret: prev.spans.plain.length,
      needsRebuild: true,
      removedSegs: [seg],
    ));
  }

  // ---------- 媒体结构操作 ----------
  /// 把媒体插入到光标处：焦点文本段按光标位拆成两段，媒体卡居中；无焦点则
  /// 挂到末尾。插入后焦点落到媒体后的文本段（光标在段首）。
  void insertMedia(
    String url, {
    required NoteMediaKind kind,
    String label = '',
    NoteTextSeg? atSeg,
  }) {
    final active = atSeg ?? activeText;
    final media = NoteMediaSeg(url, kind: kind, label: label);
    if (active == null) {
      segs.add(media);
      _ensureTrailingText();
      final last = segs.whereType<NoteTextSeg>().last;
      _recordOp(StructureOp(last.id, 'insertMedia', detail: url));
      _mergePending(EditOutcome(
        focusSegId: last.id,
        focusCaret: 0,
        needsRebuild: true,
      ));
    } else {
      final idx = segs.indexOf(active);
      final sel = active.ctrl.selection;
      final offset =
          (sel.isValid ? sel.extentOffset : active.spans.plain.length).clamp(
        0,
        active.spans.plain.length,
      );
      // 段状态按光标位拆分：runs 截断到各自侧、行级档位留上侧（与回车语义
      // 一致），媒体两侧文本各自成段、所见即所得态零丢失。
      final (left, right) = splitQuickNoteSpansAt(active.spans, offset);
      active.spans = left;
      active.ctrl
        ..text = left.plain
        ..selection = TextSelection.collapsed(offset: left.plain.length);
      segs.insert(idx + 1, media);
      final tail = NoteTextSeg()..spans = right;
      tail.ctrl
        ..text = right.plain
        ..selection = const TextSelection.collapsed(offset: 0);
      segs.insert(idx + 2, tail);
      _recordOp(StructureOp(tail.id, 'insertMedia', detail: url));
      _mergePending(EditOutcome(
        focusSegId: tail.id,
        focusCaret: 0,
        needsRebuild: true,
      ));
    }
  }

  /// 移除媒体段：文件入回收站而非删除（延迟删除，撤销移除可还原文件）；
  /// 相邻文本段合并回一体，光标自动定位到合并点（原媒体位置），不丢焦点。
  void removeMedia(NoteMediaSeg m) {
    final i = segs.indexOf(m);
    if (i < 0) return;
    beginStructuralStep();
    segs.removeAt(i);
    NoteTextSeg? caretSeg;
    var caretOffset = 0;
    final removed = <NoteSeg>[];
    if (i > 0 && i < segs.length) {
      final a = segs[i - 1];
      final b = segs[i];
      if (a is NoteTextSeg && b is NoteTextSeg) {
        // 两侧段状态合并（b 侧 runs/levels 平移拼接），所见即所得态零丢失；
        // 光标落合并点（= 合并后左段末尾，原媒体所在处，续写直觉位）。
        mergeQuickNoteSpansInto(a.spans, b.spans);
        a.ctrl.text = a.spans.plain;
        caretOffset = a.spans.plain.length;
        removed.add(b); // 被合并文本段：State 帧尾 dispose
        segs.removeAt(i);
        caretSeg = a;
      }
    }
    _ensureTrailingText();
    caretSeg ??= segs.whereType<NoteTextSeg>().firstOrNull;
    final f = m.file;
    if (f.existsSync()) {
      final stashed = _mediaTrash.stash(f);
      if (stashed != null) {
        _mediaTrashByPath[f.path] = stashed;
      } else {
        // 入桶失败：文件保持原位成孤儿（可观测，不丢数据）
        debugPrint(
          '[DEGRADE] note_media_trash_unavailable url=${m.url} path=${f.path}',
        );
      }
    }
    _recordOp(StructureOp(caretSeg?.id ?? '', 'removeMedia', detail: m.url));
    _mergePending(EditOutcome(
      focusSegId: caretSeg?.id,
      focusCaret: caretOffset,
      needsRebuild: true,
      removedSegs: removed,
    ));
  }

  /// 撤销/重做后的媒体文件对账（同步 IO，完成即渲染）：
  /// - 行内**恢复**的媒体（撤销移除）：回收站有账且原位缺失 → 还原；
  /// - 行内**消失**的媒体（重做移除）：原位文件还在且无账 → 入回收站
  ///   （与撤销移除对称，防「重做后文件滞留原位成孤儿」）。
  void _syncMediaFiles(Set<String> beforePaths) {
    final afterPaths = {
      for (final s in segs)
        if (s is NoteMediaSeg) s.file.path,
    };
    for (final p in afterPaths) {
      final trashed = _mediaTrashByPath[p];
      if (trashed == null) continue;
      if (File(p).existsSync()) {
        _mediaTrashByPath.remove(p); // 原位已在，账目作废
        continue;
      }
      if (_mediaTrash.restore(trashed, p)) {
        _mediaTrashByPath.remove(p);
      }
    }
    for (final p in beforePaths.difference(afterPaths)) {
      if (_mediaTrashByPath.containsKey(p)) continue;
      final f = File(p);
      if (!f.existsSync()) continue;
      final stashed = _mediaTrash.stash(f);
      if (stashed != null) {
        _mediaTrashByPath[p] = stashed;
      }
    }
  }

  // ---------- 动作行格式按钮（段变换内核） ----------
  /// 待办勾选切换（文本真相）：改写行内 `[ ]`/`[x]` 字面，不动坐标 run。
  void toggleTodo(NoteTextSeg seg, SpanListRun target) {
    _finalizeComposing(seg); // #2 IME 守卫：点击勾选框前强制拼音落地
    final r = qa.toggleTodo(seg.spans.plain, target.start);
    if (r == null) return; // 非待办行（标记已被剥掉，文本真相下不应发生）
    beginStructuralStep();
    seg.ctrl
      ..text = r.text
      ..selection = TextSelection.collapsed(offset: r.caret);
    seg.spans
      ..plain = r.text
      ..selBase = r.caret
      ..selExtent = r.caret;
    deriveLineRuns(seg.spans);
    _recordOp(StructureOp(seg.id, 'toggleTodo'));
    _mergePending(const EditOutcome(
      needsRebuild: true,
      clearActiveMarks: true,
    ));
  }

  /// 档位选择（转盘 标题扇区 H1/H2、正文直选）：光标行整行直设（0 回正文），
  /// 选择区不丢；焦点拉回写作区。
  void setListLevel(NoteTextSeg seg, int level) {
    _finalizeComposing(seg); // #2 IME 守卫：转盘档位切换前强制拼音落地
    final caret = seg.spans.selExtent;
    final r = setLineLevel(seg.spans.plain, caret, level);
    if (r == null) return;
    beginStructuralStep();
    seg.ctrl
      ..text = r.text
      ..selection = TextSelection.collapsed(offset: r.caret);
    seg.spans
      ..plain = r.text
      ..selBase = r.caret
      ..selExtent = r.caret;
    deriveLineRuns(seg.spans);
    _recordOp(StructureOp(seg.id, 'setListLevel', detail: level.toString()));
    _mergePending(EditOutcome(
      focusSegId: seg.id,
      focusCaret: r.caret,
      needsRebuild: true,
      clearActiveMarks: true,
    ));
  }

  /// IME 组合态强制落地守卫（#2 前置，浮层选块/勾选框等手势触发结构动作前调用）：
  /// 用户拼音组合态（下划线挂着 nǐhǎo 未上屏）时点击格式选块，若直接改写
  /// controller 文本，Android InputConnection 遭内存突变→吞字或 IndexOutOfBounds
  /// 崩溃收起。故在第 0 毫秒先强制组合区落地（composing 区字符本已在 text 内，仅
  /// 清 composing 标记 + 收拢选区到段末），再执行原子置换。[setLineKind] /
  /// [toggleTodo] / [setListLevel] / [applyMarkToSelection] 等手势触发动作统一经
  /// 此守卫；非组合态为空操作，不影响打字链路。
  void _finalizeComposing(NoteTextSeg seg) {
    final v = seg.ctrl.value;
    if (!v.composing.isValid || v.composing.isCollapsed) return;
    final end = v.selection.isValid ? v.selection.end : v.text.length;
    // 程序化赋值不触发 onChanged（仅用户编辑触发），spans 已随组合输入随动，
    // 此处仅清 composing 视觉标记并收拢选区（composing 字符已并入纯文本）。
    seg.ctrl.value = v.copyWith(
      selection: TextSelection.collapsed(offset: end),
      composing: TextRange.empty,
    );
    seg.spans
      ..selBase = end
      ..selExtent = end;
  }

  /// 段类型直设（问题#1 引导层·语义侧轨/浮层选块）：把光标行整行直设为 [kind]
  /// 语义（plain/H1/H2/bullet/quote）。待办/有序是列表自动派生变体，不由面板
  /// 直设（待办走 [toggleTodo]、有序走回车续号），故显式类型只这五种。复用
  /// [parseLine].markerEnd 原子替换行首标记区（与 [setListLevel] 同源，零坐标
  /// 搬运），单步撤销 + op-log 记账；IME 组合态经 [_finalizeComposing] 守卫。
  void setLineKind(NoteTextSeg seg, LineKindTarget kind) {
    _finalizeComposing(seg);
    final caret = seg.spans.selExtent;
    final r = setLineKindAction(seg.spans.plain, caret, kind);
    if (r == null) return; // 已是目标（无变化，不记撤销步）
    beginStructuralStep();
    seg.ctrl
      ..text = r.text
      ..selection = TextSelection.collapsed(offset: r.caret);
    seg.spans
      ..plain = r.text
      ..selBase = r.caret
      ..selExtent = r.caret;
    deriveLineRuns(seg.spans);
    _recordOp(StructureOp(seg.id, 'setLineKind', detail: kind.name));
    _mergePending(EditOutcome(
      focusSegId: seg.id,
      focusCaret: r.caret,
      needsRebuild: true,
      clearActiveMarks: true,
    ));
  }

  /// 选区套格式（高困惑 #2 修复）：在选中区间 [start,end) 上切换 [mark]。
  /// 选区塌缩则无操作（调用方应回退到激活未来输入）。复用 [toggleInlineMarkRuns]
  /// 的坐标 run 数学；选区保持以便连续切多个 mark。
  void applyMarkToSelection(NoteTextSeg seg, InlineMark mark) {
    _finalizeComposing(seg); // #2 IME 守卫：划词套格式前强制拼音落地
    final sel = seg.ctrl.selection;
    if (sel.isCollapsed) return;
    final s = sel.start.clamp(0, seg.spans.plain.length);
    final e = sel.end.clamp(0, seg.spans.plain.length);
    if (e <= s) return;
    beginStructuralStep();
    seg.spans.runs = toggleInlineMarkRuns(seg.spans.runs, mark, s, e);
    seg.spans
      ..selBase = s
      ..selExtent = e;
    _recordOp(FormatRangeOp(seg.id, s, e, mark));
    _mergePending(EditOutcome(
      needsRebuild: true,
      clearActiveMarks: true,
    ));
  }
}
