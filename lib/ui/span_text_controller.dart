import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../doc/rich_text.dart';
import '../share/quick_note_reveal.dart' show revealAt;
import '../share/quick_note_line_shape.dart' show parseLine;

/// IME 组合期维度哨兵（不与 [InlineMark]/行级档位混淆）。
class _ComposingTag {
  const _ComposingTag();
  @override
  String toString() => 'composing';
}

const Object _composingTag = _ComposingTag();

/// 行级标题档位哨兵（速记所见即所得的「行标题」维度：详情页标题是块属性，
/// 速记一段多行、标题是行属性，故以整行 [SpanLevelRun] 表达——模型在
/// rich_text.dart，纯 Dart 侧的 codec 可直接消费）。
class _LevelTag {
  const _LevelTag(this.level);
  final int level; // 1 一级 / 2 二级
  @override
  bool operator ==(Object other) => other is _LevelTag && other.level == level;
  @override
  int get hashCode => level.hashCode;
  @override
  String toString() => 'level:$level';
}

/// 围栏代码块哨兵（S4，与 buildSpanTextSpan 的 codeRuns 配套）：等宽 + 底色，
/// 与阅读态代码块同质感（surfaceContainerHighest）。
class _CodeTag {
  const _CodeTag();
  @override
  bool operator ==(Object other) => other is _CodeTag;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'code';
}

const Object _codeTag = _CodeTag();

/// 标记区隐藏哨兵（S1 显示变换）：隐藏态下标记区字符占宽透明渲染——buffer
/// 坐标不变（契约：单坐标系，§4.5），仅显示收起。
class _MarkerHiddenTag {
  const _MarkerHiddenTag();
  @override
  String toString() => 'markerHidden';
}

const Object _markerHiddenTag = _MarkerHiddenTag();

/// 标题标记淡显哨兵（中困惑 #G）：非焦点行的标题 `#` 不再纯透明，改为淡显
/// 以保留长文结构辨识度（列表项有左侧凹槽，仍走透明隐藏）。
class _MarkerFaintTag {
  const _MarkerFaintTag();
  @override
  String toString() => 'markerFaint';
}

const Object _markerFaintTag = _MarkerFaintTag();

/// span 样式渲染（原生单控件派核心）：由纯文本 + 样式维度构建带样式的
/// TextSpan 树，注入 TextField 自身渲染管线——文字、光标、选择柄、换行
/// **同一次排版**，结构性消灭叠层位移（英文粗体字宽差不再累积偏移）。
///
/// 维度合成：逐字符集合 = 行内 [InlineRun]（bold/italic/underline/code/link）
/// + 行级 [SpanLevelRun]（字号字重档位）+ IME composing（重写 buildTextSpan
/// 会覆盖默认组合下划线，必须手动接回——中文拼音组合期主输入路径）。
///
/// **性能红线**：纯内存映射，禁在此做正则/解析——runs 增量随动全在上游
/// （`EditSession.applySpanInput` / 速记行级随动）完成。
TextSpan buildSpanTextSpan({
  required BuildContext context,
  required String plain,
  required List<InlineRun> runs,
  List<SpanLevelRun> levelRuns = const [],
  TextStyle? style,
  required TextEditingValue value,
  required bool withComposing,
  List<(int, int)> hiddenMarkerRanges = const [],
  List<(int, int)> faintMarkerRanges = const [],
  List<(int, int)> codeRanges = const [],
}) {
  final base = style ?? const TextStyle();
  if (plain.isEmpty) return TextSpan(text: plain, style: base);
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;

  // 区间扫描线归并（P2 性能防线）：逐字符 Set 数组退役——runs/levelRuns/
  // composing 全部转端点事件，排序后单趟扫描产出 O(r) 个样式段（r=样式
  // 区间数，通常个位数），不再随 plain 长度线性铺内存。
  final events = <_SpanEvent>[];
  void addRange(int start, int end, Object mark) {
    if (start < 0) start = 0;
    if (end > plain.length) end = plain.length;
    if (start >= end) return;
    events
      ..add(_SpanEvent(start, false, mark))
      ..add(_SpanEvent(end, true, mark));
  }

  for (final r in runs) {
    addRange(r.start, r.end, r.mark);
  }
  for (final r in levelRuns) {
    if (r.level == 0) continue;
    addRange(r.start, r.end, _LevelTag(r.level));
  }
  if (withComposing) {
    final c = value.composing;
    if (c.isValid && !c.isCollapsed) {
      addRange(c.start, c.end, _composingTag);
    }
  }
  // S1 显示变换：隐藏态标记区渲染——区间由调用方（L1 显隐判据）传入，
  // 本函数不做解析（性能红线）。
  for (final (s, e) in hiddenMarkerRanges) {
    addRange(s, e, _markerHiddenTag);
  }
  // 标题标记淡显（中困惑 #G）：非焦点标题保留结构线索，仅降透明度。
  for (final (s, e) in faintMarkerRanges) {
    addRange(s, e, _markerFaintTag);
  }
  // S4 围栏代码块区域：等宽 + 底色（区间由调用方传派生视图，本函数不解析）
  for (final (s, e) in codeRanges) {
    addRange(s, e, _codeTag);
  }
  // 同位排序：end 先于 start——同位收放使相邻同样式区间无缝拼接
  events.sort((a, b) {
    final c = a.pos.compareTo(b.pos);
    if (c != 0) return c;
    if (a.isEnd != b.isEnd) return a.isEnd ? -1 : 1;
    return 0;
  });

  final out = <InlineSpan>[];
  var pos = 0;
  final active = <Object>{};
  TextStyle segStyle(Set<Object> marks) {
    var seg = base;
    for (final m in marks) {
      if (m is InlineMark) {
        seg = switch (m) {
          InlineMark.bold => seg.copyWith(fontWeight: FontWeight.w700),
          InlineMark.italic => seg.copyWith(fontStyle: FontStyle.italic),
          InlineMark.underline =>
            seg.copyWith(decoration: TextDecoration.underline),
          InlineMark.code => seg.copyWith(
              fontFamily: 'monospace',
              backgroundColor: scheme.surfaceContainerHighest),
          InlineMark.link => seg.copyWith(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary),
          // 与阅读态（rich_text_view._span）同源口径
          InlineMark.strikethrough =>
            seg.copyWith(decoration: TextDecoration.lineThrough),
          InlineMark.highlight => seg.copyWith(
              backgroundColor: scheme.secondaryContainer.withValues(alpha: 0.5)),
        };
      } else if (m is _LevelTag) {
        // 行级标题档位：与详情页标题块同字级（mymind 对齐 token）——整档取
        // M3 语义样式（titleLarge/titleMedium）为底，字号/行高随主题走
        //（不写裸 fontSize 字面量，arch-guard R7）；段内已有的行内标记
        //（颜色/装饰/背景/斜体/等宽）叠回保住，不被主题默认色覆盖。
        final levelStyle =
            m.level == 1 ? textTheme.titleLarge : textTheme.titleMedium;
        seg = (levelStyle ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w600,
          color: seg.color,
          backgroundColor: seg.backgroundColor,
          decoration: seg.decoration,
          decorationColor: seg.decorationColor,
          fontStyle: seg.fontStyle,
          fontFamily: seg.fontFamily,
        );
      } else if (identical(m, _composingTag)) {
        seg = seg.copyWith(decoration: TextDecoration.underline);
      } else if (identical(m, _codeTag)) {
        // 围栏代码块（S4）：等宽 + 底色容器质感，与阅读态同源（rich_text_view）。
        seg = seg.copyWith(
          fontFamily: 'monospace',
          backgroundColor: scheme.surfaceContainerHighest,
        );
      } else if (identical(m, _markerFaintTag)) {
        // 标题标记淡显（中困惑 #G）：保留宽度与字号，仅降为次级灰，让非焦点
        // 标题仍有可见结构线索（不再是纯透明、只剩字号差异）。
        seg = seg.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
        );
      } else if (identical(m, _markerHiddenTag)) {
        // 标记区隐藏（§4.5）：S1 机制阶段取「占宽隐藏」回退方案——纯透明
        // 渲染、保留宽度（R7：不动字号）；零宽版是否必要留 S3 真机定夺。
        seg = seg.copyWith(
          color: const Color(0x00000000),
          decoration: TextDecoration.none,
          backgroundColor: const Color(0x00000000),
        );
      }
    }
    return seg;
  }

  void emit(int until) {
    if (until <= pos) return;
    out.add(
      TextSpan(text: plain.substring(pos, until), style: segStyle(active)),
    );
    pos = until;
  }

  for (final e in events) {
    emit(e.pos);
    if (e.isEnd) {
      active.remove(e.mark);
    } else {
      active.add(e.mark);
    }
  }
  emit(plain.length);
  return TextSpan(style: base, children: out);
}

/// 扫描线事件（区间归并用）：[pos] 端点，[isEnd]=收端，[mark]=样式维度标记。
class _SpanEvent {
  const _SpanEvent(this.pos, this.isEnd, this.mark);
  final int pos;
  final bool isEnd;
  final Object mark;
}

/// span 样式控制器（原生单控件派，详情页/速记共用）：重写 [buildTextSpan]，
/// runs 用**活引用**（provider 每次取最新），宿主在结构变更时整体重建控制
/// 器即可——无陈旧窗口。
class SpanTextEditingController extends TextEditingController {
  SpanTextEditingController({
    required String text,
    required this.runsProvider,
    this.levelRunsProvider,
    this.codeRangesProvider,
  }) : super(text: text);

  /// 行内样式 runs 供给（纯文本坐标）。
  final List<InlineRun> Function() runsProvider;

  /// 行级档位 runs 供给（速记行标题用；详情页块级标题走 base style，不用）。
  final List<SpanLevelRun> Function()? levelRunsProvider;

  /// 围栏代码块区域供给（S4 派生视图；null = 不渲染代码块样式）。
  final List<(int, int)> Function()? codeRangesProvider;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // buffer 即含线级标记的文本——显隐为纯谓词（§3.1/契约5），paint 时对
    // 光标行当帧求值，禁跨帧缓存。谓词 false 的行算出标记区隐藏区间传给
    // 显示变换；true（光标在标记区/空项）不隐藏。
    final (hidden, faint) = _hiddenMarkerRanges(text, value.selection.extentOffset);
    return buildSpanTextSpan(
      context: context,
      plain: text,
      runs: runsProvider(),
      levelRuns: levelRunsProvider?.call() ?? const <SpanLevelRun>[],
      style: style,
      value: value,
      withComposing: withComposing,
      hiddenMarkerRanges: hidden,
      faintMarkerRanges: faint,
      codeRanges: codeRangesProvider?.call() ?? const [],
    );
  }

  /// 逐行算隐藏区间（整段一次求值，O(文本)）：谓词 false 且该行有标记
  /// → 隐藏 `[行首, markerEnd)`，**透明占位**（保留宽度、不动字号，§4.5）。
  /// 所有标记同口径（标题/列表/待办/引用），谓词用 revealAt。
  ///
  /// 2026-10-08 拍板：标题标记**回归隐藏态**，不再走淡显（中困惑 #G 废弃）。
  /// 起因是真机实测「标题行看得见 `# `」被当成 bug——列表/引用/待办都透明、
  /// 唯独标题淡灰，观感上就是「没做成所见即所得」；#G 想保的「非焦点标题结构
  /// 线索」改由字号字重承担（H2 与正文差异不足已挂待办，见 context/todos.md）。
  /// [faint] 通道保留（暂恒空），若日后需要极淡线索可一句切回。
  ///
  /// 公开包装见 [hiddenMarkerRangesFor]（同实现，供单测钉住判据）。
  static (List<(int, int)>, List<(int, int)>) _hiddenMarkerRanges(
    String text,
    int caret,
  ) {
    final hidden = <(int, int)>[];
    final faint = <(int, int)>[];
    var pos = 0;
    for (final line in text.split('\n')) {
      final start = pos;
      pos += line.length + 1;
      if (line.isEmpty) continue;
      final shape = parseLine(line);
      if (shape.isPlain || shape.markerEnd <= 0) continue;
      final revealed = revealAt(text, caret.clamp(0, text.length),
              frozen: false, heldValue: false) &&
          _caretInLine(text, caret.clamp(0, text.length), start, start + line.length);
      if (revealed) continue;
      // 标题与列表同口径透明隐藏（2026-10-08；faint 通道暂不启用）
      hidden.add((start, start + shape.markerEnd));
    }
    return (hidden, faint);
  }

  /// [SpanTextEditingController._hiddenMarkerRanges] 的公开包装：同一实现，
  /// 供单测钉住显隐判据（库私有方法测试不可达）。返回 `(hidden, faint)`。
  static (List<(int, int)>, List<(int, int)>) hiddenMarkerRangesFor(
    String text,
    int caret,
  ) =>
      _hiddenMarkerRanges(text, caret);

  static bool _caretInLine(String text, int caret, int lineStart, int lineEnd) {
    // revealAt 已定位光标所在行；此处只需判断该行是否就是光标行——
    // 光标不在本行 → 本行按隐藏结算（§3.1「光标在该行内」不满足）。
    return caret >= lineStart && caret <= lineEnd;
  }
}

/// span 粘贴归一（详情页/速记共用）：仅做 CRLF/CR→`\n` 归一，**不折叠空行**。
///
/// 多段空行 `\n\n` 原样放行，交由编辑器 `_onSegChanged`→`splitLines`
/// （`_materializeNewlines`）物化为多个段——与打字回车拆段同口径，段落
/// 间距（空段）得以保留；行内 runs 经 `splitQuickNoteSpansAt` 跨段保全。
/// 旧实现曾把 `\n[ \t]*\n+` 折成单 `\n`（空行被吃掉、段落间距丢失），该
/// 折叠在文本真相模型下已无必要（拆段不丢样式），D 专项（2026-10-08）摘除。
///
/// 只认「单次编辑插入的文本自带空行」这一粘贴签名：敲回车一次只进一个
/// `\n`，逐次敲出的空行原样放行（输入格式化器对所有编辑生效，旧实现按
/// 整文本折叠会把用户连敲的第二个回车 `\n\n` 当场折叠回 `\n`——永远敲
/// 不出空行，光标看似卡在下一行动不了）。归一只作用于插入区，此前敲出
/// 的空行不被后续粘贴连带抹掉。
class SpanPasteNormalizeFormatter extends TextInputFormatter {
  const SpanPasteNormalizeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final (start, inserted) = _insertedRange(oldValue.text, newValue.text);
    // CRLF/CR 一律归一为 \n（单段 CRLF 粘贴也会经回车拆块物化，残留 \r
    // 会成段内杂字符）；打字路径不受影响（IME 只插 \n）。
    // D 专项（2026-10-08）：**不再折叠空行**——多段空行 `\n\n` 原样保留，
    // 段落间距交由编辑器 `_onSegChanged`→`splitLines`（`_materializeNewlines`）
    // 物化为多个段（与打字回车同口径）；行内 runs 经 `splitQuickNoteSpansAt`
    // 跨段保全，旧注释担忧的「丢样式」在文本真相模型下已不存在。
    final normalized = inserted
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (normalized == inserted) return newValue;
    final oldEnd = start + inserted.length;
    final foldedEnd = start + normalized.length;
    final delta = inserted.length - normalized.length;
    return TextEditingValue(
      text: newValue.text.replaceRange(start, oldEnd, normalized),
      selection: TextSelection(
        baseOffset: _mapOffset(
          newValue.selection.baseOffset,
          start,
          oldEnd,
          foldedEnd,
          delta,
        ),
        extentOffset: _mapOffset(
          newValue.selection.extentOffset,
          start,
          oldEnd,
          foldedEnd,
          delta,
        ),
      ),
      composing: _shift(newValue.composing, start, oldEnd, foldedEnd, delta),
    );
  }

  /// 新旧文本公共前缀/后缀剥除，剩下的即本次插入段（返回起点 + 内容）。
  (int, String) _insertedRange(String old, String neu) {
    var p = 0;
    final minLen = old.length < neu.length ? old.length : neu.length;
    while (p < minLen && old.codeUnitAt(p) == neu.codeUnitAt(p)) {
      p++;
    }
    var s = old.length, t = neu.length;
    while (s > p && t > p && old.codeUnitAt(s - 1) == neu.codeUnitAt(t - 1)) {
      s--;
      t--;
    }
    return (p, neu.substring(p, t));
  }

  /// 折叠后坐标重映射：插入区后的偏移平移 delta，区内的偏移吸附到折叠尾。
  int _mapOffset(int o, int start, int oldEnd, int foldedEnd, int delta) =>
      o <= start
          ? o
          : o >= oldEnd
              ? o - delta
              : foldedEnd;

  TextRange _shift(
    TextRange r,
    int start,
    int oldEnd,
    int foldedEnd,
    int delta,
  ) {
    if (!r.isValid) return r;
    return TextRange(
      start: _mapOffset(r.start, start, oldEnd, foldedEnd, delta),
      end: _mapOffset(r.end, start, oldEnd, foldedEnd, delta),
    );
  }
}
