import '../doc/rich_text.dart';

/// 速记所见即所得文本段模型（纯 Dart，可单测；2026-10-03 用户拍板「速记也
/// 所见即所得，不再出现 md 标记」）。
///
/// 三个维度：
/// - [plain]：编辑区唯一文本（无 md 标记可见）；
/// - [runs]：字符级行内样式 run（加粗/斜体/下划线，先选后打）；
/// - [levelRuns]：行级标题 run（标题是**行属性**——速记一段多行，与详情页的
///   块级标题属性不同源，故整行表达；恒与实际整行对齐，宿主侧按行重 snap）。
///
/// 序列化（保存/草稿）经 [serializeQuickNoteSpans] 生成 human_md（行首标题前缀
/// + 行内标记）——下游 TextCollector / CollectCommand / MCP 零感知。
class QuickNoteSpans {
  QuickNoteSpans({
    this.plain = '',
    List<InlineRun>? runs,
    List<SpanLevelRun>? levelRuns,
    this.selBase = 0,
    this.selExtent = 0,
  })  : runs = runs ?? <InlineRun>[],
        levelRuns = levelRuns ?? <SpanLevelRun>[];

  String plain;
  List<InlineRun> runs;
  List<SpanLevelRun> levelRuns;

  /// 选择区（base/extent，与 TextSelection 同义，纯 int 免 Flutter 依赖）。
  int selBase;
  int selExtent;
}

/// 播种：md 原文（旧草稿 / 粘贴源）→ plain + runs + 行级 runs（所见即所得态）。
///
/// 顺序：先剥行内标记（[inlineSpansOf]），再剥行首 `#{1,6} ` 前缀并整体平移
/// runs 坐标（行级前缀在行内解析之后才处理，坐标需按行累计剥离量修正）。
/// 未闭合/非法语法由 inlineSpansOf 降级为字面——所见即所得永不显示 md 残壳。
QuickNoteSpans seedQuickNote(String source) {
  final spans = inlineSpansOf(source);
  final plain0 = spans.plain;
  final lines0 = plain0.split('\n');
  final stripped = <String>[];
  final prefixLens = <int>[];
  final hashLens = <int>[];
  for (final line in lines0) {
    final m = _headingRe.firstMatch(line);
    if (m != null) {
      stripped.add(line.substring(m.end));
      prefixLens.add(m.end);
    } else {
      stripped.add(line);
      prefixLens.add(0);
    }
    // 档位 = 原 `#` 个数（1-6，与解析器 _heading 同源）
    hashLens.add(m?.group(1)?.length ?? 0);
  }
  final plain = stripped.join('\n');

  // 行偏移表（plain0 坐标 → plain 坐标：同前行内剥离量不变，行首前缀左移）
  final lineStarts0 = <int>[];
  final lineStarts = <int>[];
  var pos0 = 0;
  var pos = 0;
  for (var i = 0; i < lines0.length; i++) {
    lineStarts0.add(pos0);
    lineStarts.add(pos);
    pos0 += lines0[i].length + 1;
    pos += stripped[i].length + 1;
  }

  int shift(int x) {
    // x 落在第 i 行（含行尾 '\n'）→ 减去 i 行及其之前所有行的前缀长度
    // （lineStarts0[i]-lineStarts[i] 只含 i 之前行的前缀，需再扣本行前缀）
    for (var i = lineStarts0.length - 1; i >= 0; i--) {
      if (x >= lineStarts0[i]) {
        return x - (lineStarts0[i] - lineStarts[i]) - prefixLens[i];
      }
    }
    return x;
  }

  final runs = <InlineRun>[];
  for (final r in spans.runs) {
    final s = shift(r.start);
    final e = shift(r.end);
    if (e > s) runs.add(InlineRun(s, e, r.mark, url: r.url));
  }

  final levelRuns = <SpanLevelRun>[];
  for (var i = 0; i < lines0.length; i++) {
    if (prefixLens[i] > 0) {
      final s = lineStarts[i];
      final e = s + stripped[i].length;
      levelRuns.add(SpanLevelRun(s, e, hashLens[i].clamp(1, 6)));
    }
  }

  return QuickNoteSpans(plain: plain, runs: runs, levelRuns: levelRuns);
}

/// 光标所在行当前档位（0 正文 / 1 一级 / 2 二级）——胶囊「格式 · 二级标题」依据。
int quickNoteLevelAt(QuickNoteSpans s, int caret) {
  for (final r in s.levelRuns) {
    if (r.level > 0 && caret >= r.start && caret <= r.end) return r.level;
  }
  return 0;
}

/// 光标行档位直设（0=回正文、1/2=标题档；横条有显式「正文」档，不做 toggle）。
/// 空行也可挂档（行首回车后输入即成标题行），序列化时空行不输出前缀。
void setQuickNoteLevel(QuickNoteSpans s, int level, {required int caret}) {
  if (caret < 0 || caret > s.plain.length) return;
  int? lineStart;
  int? lineEnd;
  final lines = _lineRanges(s.plain);
  for (final l in lines) {
    if (caret >= l.start && caret <= l.end) {
      lineStart = l.start;
      lineEnd = l.end;
      break;
    }
  }
  if (lineStart == null || lineEnd == null) return;
  s.levelRuns = [
    for (final r in s.levelRuns)
      if (!(r.start == lineStart && r.end == lineEnd)) r,
  ];
  if (level > 0) s.levelRuns.add(SpanLevelRun(lineStart, lineEnd, level));
}

/// 文字变更随动（纯函数语义，就地改 [s]）：行内 runs 与详情页同规则
/// （[adjustRuns] 字符级 + 激活 mark 落插入段）；行级 runs 走**按行重 snap**
/// ——标题是行属性而非字符属性，字符级随动会把「标题行中间回车」的新行也染成标题。
void applyQuickNoteSpansInput(
  QuickNoteSpans s,
  String newText, {
  required Set<InlineMark> active,
}) {
  final (start, oldEnd) = spanChangeRange(s.plain, newText);
  final insertLen = newText.length - s.plain.length + (oldEnd - start);
  s.runs = adjustRuns(s.runs, start, oldEnd, insertLen);
  if (insertLen > 0) {
    for (final m in active) {
      s.runs.add(InlineRun(start, start + insertLen, m));
    }
  }
  s.levelRuns = adjustQuickNoteLevelRuns(s.levelRuns, s.plain, newText);
  s.plain = newText;
}

/// 行级 runs 随动：文本变更 → 每档行按锚点重新吸附到变更后整行。
///
/// 窗（spanChangeRange 的删旧插新窗 [start, oldEnd)，winEnd = start +
/// insertLen）与整行按四种位置关系处置：
/// - 窗在整行**前**（winEnd < 行首，或恰同行首且非负 delta）→ 整行位移 delta；
/// - 窗在整行**后**（start > 行尾）→ 不动；
/// - 窗**吞掉整行**（行首行尾都在窗内）→ 行身份消亡，档位删；
/// - 窗与行**交叠** → 档位随行首字符重 snap：行首未动取原行首为锚点（回车
///   拆行时前半留档、新行回正文）；行首被窗消费（行首删除/替换/行首插入推后）
///   取窗尾 winEnd 为锚点（行首回车 → 档位随原行下移）。
List<SpanLevelRun> adjustQuickNoteLevelRuns(
  List<SpanLevelRun> runs,
  String oldText,
  String newText,
) {
  if (runs.isEmpty) return const [];
  final (start, oldEnd) = spanChangeRange(oldText, newText);
  final insertLen = newText.length - oldText.length + (oldEnd - start);
  final winEnd = start + insertLen;
  final delta = insertLen - (oldEnd - start);
  final oldLines = _lineRanges(oldText);
  final newLines = _lineRanges(newText);

  final out = <SpanLevelRun>[];
  for (final r in runs) {
    int li = -1;
    for (var i = 0; i < oldLines.length; i++) {
      if (r.start >= oldLines[i].start && r.start <= oldLines[i].end) {
        li = i;
        break;
      }
    }
    if (li < 0) continue;
    final L = oldLines[li];

    if (winEnd < L.start || (winEnd == L.start && delta >= 0)) {
      // 窗在本行前（未吞本行前导 '\n'）：整行位移
      final d = (L.start >= oldEnd) ? delta : 0;
      out.add(SpanLevelRun(L.start + d, L.end + d, r.level));
      continue;
    }
    if (start > L.end) {
      // 窗在本行后：不动
      out.add(r);
      continue;
    }
    if (start <= L.start && L.end <= oldEnd) {
      // 窗吞掉整行（整行替换/删除）：行身份消亡，档位删
      continue;
    }
    // 窗与行交叠：行首字符未动 → 锚点原行首；行首被窗消费 → 锚点窗尾
    final anchor = L.start >= start ? winEnd : L.start;
    int li2 = -1;
    for (var i = 0; i < newLines.length; i++) {
      if (anchor >= newLines[i].start && anchor <= newLines[i].end) {
        li2 = i;
        break;
      }
    }
    if (li2 < 0) continue;
    out.add(SpanLevelRun(newLines[li2].start, newLines[li2].end, r.level));
  }
  return out;
}

/// 在 [offset] 拆段（媒体插入用）：runs/levels 按区间分配到两侧。
/// 行级 run 被拆时：档位留**上侧**（与回车语义一致）；offset 恰在行首 → 档位
/// 随原行（下侧）走。
(QuickNoteSpans, QuickNoteSpans) splitQuickNoteSpansAt(
  QuickNoteSpans s,
  int offset,
) {
  offset = offset.clamp(0, s.plain.length);
  final leftLevels = <SpanLevelRun>[];
  final rightLevels = <SpanLevelRun>[];
  for (final r in s.levelRuns) {
    if (offset >= r.start && offset < r.end) {
      // 拆行内：offset>行首 → 上侧留档；offset==行首 → 随原行下移
      if (offset > r.start) leftLevels.add(SpanLevelRun(r.start, offset, r.level));
    } else if (offset >= r.end) {
      leftLevels.add(r);
    } else {
      rightLevels.add(SpanLevelRun(r.start - offset, r.end - offset, r.level));
    }
  }
  final left = QuickNoteSpans(
    plain: s.plain.substring(0, offset),
    runs: [
      for (final r in s.runs)
        if (r.start < offset)
          InlineRun(r.start, r.end < offset ? r.end : offset, r.mark, url: r.url),
    ],
    levelRuns: leftLevels,
    selBase: 0,
    selExtent: 0,
  );
  final right = QuickNoteSpans(
    plain: s.plain.substring(offset),
    runs: [
      for (final r in s.runs)
        if (r.end > offset)
          InlineRun(
            r.start > offset ? r.start - offset : 0,
            r.end - offset,
            r.mark,
            url: r.url,
          ),
    ],
    levelRuns: rightLevels,
    selBase: 0,
    selExtent: 0,
  );
  return (left, right);
}

/// 相邻文本段拼接（删媒体合并用）：[b] 追加进 [a]，runs/levels 平移 b 侧坐标。
void mergeQuickNoteSpansInto(QuickNoteSpans a, QuickNoteSpans b) {
  final d = a.plain.length;
  a.plain += b.plain;
  a.runs.addAll([
    for (final r in b.runs) InlineRun(r.start + d, r.end + d, r.mark, url: r.url),
  ]);
  a.levelRuns.addAll([
    for (final r in b.levelRuns) SpanLevelRun(r.start + d, r.end + d, r.level),
  ]);
}

/// 保存/草稿序列化：plain + runs + 行级 runs → human_md（行首标题前缀 +
/// 行内标记，与详情页块序列化同一 grammar 出口）。行内 runs 按行截取后重建
/// 节点树——跨行的 run 坐标在本行坐标系内平移。
String serializeQuickNoteSpans(QuickNoteSpans s) {
  final lines = s.plain.split('\n');
  final out = <String>[];
  var pos = 0;
  for (final line in lines) {
    final lineStart = pos;
    final lineEnd = pos + line.length;
    int level = 0;
    for (final r in s.levelRuns) {
      if (r.level > 0 && r.start <= lineStart && lineStart <= r.end) {
        level = r.level;
        break;
      }
    }
    final sub = [
      for (final r in s.runs)
        if (r.end > lineStart && r.start < lineEnd)
          InlineRun(
            r.start > lineStart ? r.start - lineStart : 0,
            r.end < lineEnd ? r.end - lineStart : line.length,
            r.mark,
            url: r.url,
          ),
    ];
    final body = serializeInline(inlineNodesOf(line, sub));
    // 无档位行必须走 body（含行内标记序列化）——输出原始 line 会丢 **/*/<u>
    out.add(level > 0 && line.isNotEmpty ? '${'#' * level} $body' : body);
    pos = lineEnd + 1;
  }
  return out.join('\n');
}

/// 与解析器 `_heading`（`^(#{1,6})\s+(.*)$`）同源：捕获组 1 = `#` 串（档位）。
final RegExp _headingRe = RegExp(r'^(#{1,6})\s+');

class _LineRange {
  const _LineRange(this.start, this.end);

  final int start;
  final int end;
}

/// 行表：每行 [start, end)（不含行尾 '\n'），与 split('\n') 逐行对应。
List<_LineRange> _lineRanges(String t) {
  final out = <_LineRange>[];
  var s = 0;
  for (var i = 0; i < t.length; i++) {
    if (t[i] == '\n') {
      out.add(_LineRange(s, i));
      s = i + 1;
    }
  }
  out.add(_LineRange(s, t.length));
  return out;
}
