import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../doc/rich_text.dart';

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
  }) : super(text: text);

  /// 行内样式 runs 供给（纯文本坐标）。
  final List<InlineRun> Function() runsProvider;

  /// 行级档位 runs 供给（速记行标题用；详情页块级标题走 base style，不用）。
  final List<SpanLevelRun> Function()? levelRunsProvider;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return buildSpanTextSpan(
      context: context,
      plain: text,
      runs: runsProvider(),
      levelRuns: levelRunsProvider?.call() ?? const <SpanLevelRun>[],
      style: style,
      value: value,
      withComposing: withComposing,
    );
  }
}

/// span 粘贴归一（详情页/速记共用）：**粘贴**含空行多段不拆块（拆块走 md
/// 重建会丢样式），空行折叠为单换行——段落结构稳定、样式保全。
///
/// 只认「单次编辑插入的文本自带空行」这一粘贴签名：敲回车一次只进一个
/// `\n`，逐次敲出的空行原样放行（输入格式化器对所有编辑生效，旧实现按
/// 整文本折叠会把用户连敲的第二个回车 `\n\n` 当场折叠回 `\n`——永远敲
/// 不出空行，光标看似卡在下一行动不了）。折叠只作用于插入区，此前敲出
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
    // 会成段内杂字符）；再折叠空行（\r\n\r\n 的空行签名在 \n 口径下才可见）。
    // 打字路径不受影响（IME 只插 \n）。
    final normalized = inserted
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final folded = normalized.replaceAll(RegExp(r'\n[ \t]*\n+'), '\n');
    if (folded == inserted) return newValue;
    final oldEnd = start + inserted.length;
    final foldedEnd = start + folded.length;
    final delta = inserted.length - folded.length;
    return TextEditingValue(
      text: newValue.text.replaceRange(start, oldEnd, folded),
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
