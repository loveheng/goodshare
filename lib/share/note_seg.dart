// 段模型 + 段↔草稿行/保存模型序列化（编辑器拆解 P1b：从编辑器抽出，供纯
// 逻辑引擎 ComposerDoc 与编辑器共用，无 UI 装配依赖）。
//
// 段持有 ctrl/focus/key 三个 Flutter 活引用（方案 A：段模型不动以免破坏现有
// widget 测试），但本文件不操作焦点、不触发重建——那些归 State 反射。
import 'dart:io';

import 'package:flutter/material.dart' show FocusNode, GlobalKey;
import '../share/attachments.dart' show resolveLocalMediaSrc;
import '../share/note_composer.dart'
    show NoteAudioSegment, NoteImageSegment, NoteSegment, NoteTextSegment, NoteVideoSegment;
import '../share/quick_note_span_codec.dart' show QuickNoteSpans;
import '../share/quick_note_text_actions.dart'
    show seedTextTruth, serializeTextTruthSpans;
import '../ui/span_text_controller.dart' show SpanTextEditingController;

/// 段身份计数器：文本真相模型下段是持久对象，拆/合/撤销都按 id 定位，
/// 不再依赖段在序列里的下标（编辑器拆解 P1a）。
int _segSeq = 0;
String _newSegId() => 'seg_${++_segSeq}';

/// 段：文本或行内媒体（作曲器的最小单元）。
sealed class NoteSeg {}

class NoteTextSeg extends NoteSeg {
  NoteTextSeg([String text = '']) : id = _newSegId(), spans = seedTextTruth(text) {
    // 活引用：排版时取 spans 最新 runs/levelRuns（拆分时替换 spans 对象，
    // 闭包自动跟随——无陈旧窗口，与详情页同一机制）
    ctrl = SpanTextEditingController(
      text: spans.plain,
      runsProvider: () => spans.runs,
      levelRunsProvider: () => spans.levelRuns,
      codeRangesProvider: () => [
        for (final c in spans.codeRuns) (c.start, c.end),
      ],
    );
  }

  /// 所见即所得段状态（2026-10-03 速记同源化拍板）：plain = 编辑区唯一文本，
  /// 含线级标记（`- `/`# `），行级身份由 deriveLineRuns 派生视图表达（文本
  /// 变更后重派生）；runs（行内样式）仍坐标模型（§8）。控制器文本与
  /// [spans.plain] 恒同源（变更点成对更新）；序列化出口后移至保存/落草稿时。
  /// 媒体插入拆段时整体替换本对象——runsProvider 活闭包自动跟随。
  /// 段身份（持久对象，拆/合/撤销按 id 而非下标定位）。
  final String id;

  QuickNoteSpans spans;

  final FocusNode focus = FocusNode();
  final GlobalKey key = GlobalKey();

  late final SpanTextEditingController ctrl;

  void dispose() {
    ctrl.dispose();
    focus.dispose();
  }
}

class NoteMediaSeg extends NoteSeg {
  NoteMediaSeg(this.url, {required this.kind, this.label = ''});

  /// 行内媒体 url（`local://` 相对标记，SSOT：rich-text-media.md §2——
  /// 绝不写绝对路径，iOS 沙盒路径会变；IO/渲染经 [resolveLocalMediaSrc] 解析）。
  /// 非 final：媒体替换钩子（长按换文件/音频重录）就地改写。
  String url;

  /// 媒体类别：图片 / 录音 / 视频（便签内嵌视频附件态，2026-10-01 拍板）。
  final NoteMediaKind kind;

  /// 媒体说明：图=alt、音/视频=label（详情已有条目携带的自定义说明；
  /// 空串=默认文案，序列化时按 kind 取默认）。
  String label;

  /// 本体文件（渲染预览与删除清理共用同一解析口）。
  File get file => File(resolveLocalMediaSrc(url));
}

enum NoteMediaKind { image, audio, video }

/// 撤销文字连击合并窗（连续输入合并为一步）与快照栈深上限。
const Duration kUndoCoalesce = Duration(milliseconds: 800);
const int kUndoCap = 100;

/// 草稿行快照：段序列 → 行编码（与 QuickNoteDraft/静态缓存同源；
/// 媒体段第 3 位携带 alt/label，空省略）。
List<List<String>> noteSegsToDraftRows(List<NoteSeg> segs) => [
  for (final s in segs)
    switch (s) {
      NoteTextSeg(:final spans) => ['t', serializeTextTruthSpans(spans)],
      NoteMediaSeg(:final url, :final label, kind: NoteMediaKind.image) =>
        label.isEmpty ? ['i', url] : ['i', url, label],
      NoteMediaSeg(:final url, :final label, kind: NoteMediaKind.audio) =>
        label.isEmpty ? ['a', url] : ['a', url, label],
      NoteMediaSeg(:final url, :final label, kind: NoteMediaKind.video) =>
        label.isEmpty ? ['v', url] : ['v', url, label],
    },
];

/// 段序列 → 保存用 NoteSegment（序列化出口后移的唯一收口；媒体说明空值
/// 按默认回填，与 serializeNoteMd 的默认口径一致）。
List<NoteSegment> noteSegsToNoteSegments(List<NoteSeg> segs) => [
  for (final s in segs)
    switch (s) {
      NoteTextSeg(:final spans) => NoteTextSegment(
        serializeTextTruthSpans(spans),
      ),
      NoteMediaSeg(:final url, :final label, kind: NoteMediaKind.image) =>
        NoteImageSegment(url, alt: label),
      NoteMediaSeg(:final url, :final label, kind: NoteMediaKind.audio) =>
        NoteAudioSegment(url, label: label.isEmpty ? '录音' : label),
      NoteMediaSeg(:final url, :final label, kind: NoteMediaKind.video) =>
        NoteVideoSegment(url, label: label.isEmpty ? '视频' : label),
    },
];
