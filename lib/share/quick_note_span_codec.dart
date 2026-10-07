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
/// 序列化（保存/草稿）出口已移至文本真相侧 `serializeTextTruthSpans`（见
/// quick_note_text_actions.dart）：plain 含线级标记，只剩行内 runs 需重建
/// human_md——下游 TextCollector / CollectCommand / MCP 零感知。
class QuickNoteSpans {
  QuickNoteSpans({
    this.plain = '',
    List<InlineRun>? runs,
    List<SpanLevelRun>? levelRuns,
    List<SpanListRun>? listRuns,
    List<SpanCodeRun>? codeRuns,
    this.selBase = 0,
    this.selExtent = 0,
  })  : runs = runs ?? <InlineRun>[],
        levelRuns = levelRuns ?? <SpanLevelRun>[],
        listRuns = listRuns ?? <SpanListRun>[],
        codeRuns = codeRuns ?? <SpanCodeRun>[];

  String plain;
  List<InlineRun> runs;
  List<SpanLevelRun> levelRuns;
  List<SpanListRun> listRuns;

  /// 围栏代码块区域（S4 派生视图，deriveLineRuns 维护）：`​```​` 开栏到合栏
  /// （含两道围栏行）的整段区间——渲染等宽+底色，文本真相下不参与任何随动。
  List<SpanCodeRun> codeRuns;

  /// 选择区（base/extent，与 TextSelection 同义，纯 int 免 Flutter 依赖）。
  int selBase;
  int selExtent;
}

/// 围栏代码块区域 run（S4）：[start, end) 覆盖开栏行首到合栏行尾（含围栏行
/// 本体；未合栏则到文本末）。派生视图，坐标随文本派生，永不手写。
class SpanCodeRun {
  const SpanCodeRun(this.start, this.end);

  final int start;
  final int end;
}

/// 光标所在行当前档位（0 正文 / 1 一级 / 2 二级）——胶囊「格式 · 二级标题」依据。
int quickNoteLevelAt(QuickNoteSpans s, int caret) {
  for (final r in s.levelRuns) {
    if (r.level > 0 && caret >= r.start && caret <= r.end) return r.level;
  }
  return 0;
}

/// 光标所在行的区间 `(start, end)`（不含行尾 '\n'）；越界返回 null。
///
/// 行级动作（回车起新项 / 行首退格出列 / 勾选翻转）共用同一「找行」口径，
/// 避免各写一遍造成行为漂移。
(int, int)? quickNoteLineRangeAt(QuickNoteSpans s, int caret) {
  if (caret < 0 || caret > s.plain.length) return null;
  for (final l in _lineRanges(s.plain)) {
    if (caret >= l.start && caret <= l.end) return (l.start, l.end);
  }
  return null;
}

/// 该行**首**是否有列表 run（行身份 = run 首行；续行被吞入既有 run，start 不
/// 落在本行故返回 null）。
SpanListRun? quickNoteListRunAt(QuickNoteSpans s, int lineStart) {
  for (final r in s.listRuns) {
    if (r.start == lineStart) return r;
  }
  return null;
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
    if (L.start == L.end) {
      // 空行挂档：允许先给空行挂档、之后输入即成标题行（旧 setQuickNoteLevel
      // 语义；文本真相下档位由行首 `# ` 前缀派生）
      // ——但 identity 是**行位置**而非区间，若套用下方「窗吞掉整行→身份
      // 消亡」，在空行敲下第一个字的瞬间档位就丢了（既有缺陷：与其注释声明
      // 的意图不符）。故按锚点落到新行、宽度贴合整行。
      final anchor = oldEnd < L.start
          ? L.start + delta
          : (oldEnd == L.start ? L.start : winEnd);
      int li2 = -1;
      for (var i = 0; i < newLines.length; i++) {
        if (anchor >= newLines[i].start && anchor <= newLines[i].end) {
          li2 = i;
          break;
        }
      }
      if (li2 < 0) continue;
      out.add(SpanLevelRun(newLines[li2].start, newLines[li2].end, r.level));
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

/// 列表 runs 随动（与 [adjustQuickNoteLevelRuns] 同款按行重 snap；2026-10-06）：
/// 列表是行属性，处置关系完全一致，仅保留 kind/done。
List<SpanListRun> adjustQuickNoteListRuns(
  List<SpanListRun> runs,
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

  final out = <SpanListRun>[];
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
      final d = (L.start >= oldEnd) ? delta : 0;
      out.add(SpanListRun(L.start + d, L.end + d, r.kind, done: r.done));
      continue;
    }
    if (start > L.end) {
      out.add(r);
      continue;
    }
    if (L.start == L.end) {
      // 空行占位项（刚落定的 `- ` / 回车起的新项 / 播种的空列表行）：identity
      // 是**行位置**而非区间。若套用下方「窗吞掉整行→身份消亡」，在空项里敲下
      // 第一个字的瞬间 run 就被删——刚出现的圆点/勾选框立刻蒸发。故按锚点落到
      // 新行，宽度贴合该整行。
      final anchor = oldEnd < L.start
          ? L.start + delta
          : (oldEnd == L.start ? L.start : winEnd);
      int li2 = -1;
      for (var i = 0; i < newLines.length; i++) {
        if (anchor >= newLines[i].start && anchor <= newLines[i].end) {
          li2 = i;
          break;
        }
      }
      if (li2 < 0) continue;
      out.add(SpanListRun(newLines[li2].start, newLines[li2].end, r.kind,
          done: r.done));
      continue;
    }
    if (start <= L.start && L.end <= oldEnd) {
      continue;
    }
    final anchor = L.start >= start ? winEnd : L.start;
    int li2 = -1;
    for (var i = 0; i < newLines.length; i++) {
      if (anchor >= newLines[i].start && anchor <= newLines[i].end) {
        li2 = i;
        break;
      }
    }
    if (li2 < 0) continue;
    out.add(SpanListRun(newLines[li2].start, newLines[li2].end, r.kind,
        done: r.done));
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
  final leftLists = <SpanListRun>[];
  final rightLists = <SpanListRun>[];
  for (final r in s.listRuns) {
    if (offset >= r.start && offset < r.end) {
      if (offset > r.start) {
        leftLists.add(SpanListRun(r.start, offset, r.kind, done: r.done));
      }
    } else if (offset >= r.end) {
      leftLists.add(r);
    } else {
      rightLists.add(
        SpanListRun(r.start - offset, r.end - offset, r.kind, done: r.done),
      );
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
    listRuns: leftLists,
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
    listRuns: rightLists,
    selBase: 0,
    selExtent: 0,
  );
  return (left, right);
}

/// 相邻文本段拼接（删媒体合并用）：[b] 追加进 [a]，runs/levels/lists 平移 b 侧坐标。
void mergeQuickNoteSpansInto(QuickNoteSpans a, QuickNoteSpans b) {
  final d = a.plain.length;
  a.plain += b.plain;
  a.runs.addAll([
    for (final r in b.runs) InlineRun(r.start + d, r.end + d, r.mark, url: r.url),
  ]);
  a.levelRuns.addAll([
    for (final r in b.levelRuns) SpanLevelRun(r.start + d, r.end + d, r.level),
  ]);
  a.listRuns.addAll([
    for (final r in b.listRuns)
      SpanListRun(r.start + d, r.end + d, r.kind, done: r.done),
  ]);
}

/// 把已解析的片段 [frag] 插入 [target]（替换 [at, replaceEnd) 区间），全维度合并
/// runs/levels/lists 坐标——「导入 md」弹框专用：剪贴板文本 → `seedTextTruth`
/// → 插入当前段光标处（或替换选区）。
void insertSeededSpans(
  QuickNoteSpans target,
  QuickNoteSpans frag,
  int at, {
  int replaceEnd = -1,
}) {
  replaceEnd = (replaceEnd < 0 ? at : replaceEnd).clamp(at, target.plain.length);
  final insertLen = frag.plain.length;
  final newPlain = target.plain.replaceRange(at, replaceEnd, frag.plain);

  // 既有行内 runs 按窗 [at, replaceEnd) 随动（删窗内 / 移其后 / 交叠裁剪）
  final shiftedExisting = adjustRuns(target.runs, at, replaceEnd, insertLen);
  // 片段行内 runs 平移 at 后并入（落在插入区，不与既有重叠）
  final fragRuns = [
    for (final r in frag.runs)
      InlineRun(r.start + at, r.end + at, r.mark, url: r.url),
  ];
  target.runs = [...shiftedExisting, ...fragRuns];

  // 行级/列表 runs 直接按 old→new 文本全量重 snap；调用方随后须 deriveLineRuns
  // （adjust* 只搬既有 run、从不新建，片段带来的新行身份只能靠派生）
  final existingLevels =
      adjustQuickNoteLevelRuns(target.levelRuns, target.plain, newPlain);
  final existingLists =
      adjustQuickNoteListRuns(target.listRuns, target.plain, newPlain);
  target.levelRuns = [
    ...existingLevels,
    for (final r in frag.levelRuns)
      SpanLevelRun(r.start + at, r.end + at, r.level),
  ];
  target.listRuns = [
    ...existingLists,
    for (final r in frag.listRuns)
      SpanListRun(r.start + at, r.end + at, r.kind, done: r.done),
  ];
  target.plain = newPlain;
}

/// 有序列表项的**序号表**（run 首行偏移 → 序号）：同一连续组从 1 递增，遇到
/// 非有序 run 即断组归零——与详情页「每个 ListBlock 独立从 1 重排」同口径。
///
/// ⚠️ 必须按 **run**（而非文本行）推算：多行列表项的续行**不产生 run**，若按
/// 行扫描会在续行处误判断组，把后续项重新从 1 编起（`1. 甲 / 续行 / 2. 乙`
/// 会退化成 `1. / 1.`）。
Map<int, int> quickNoteOrderedOrdinals(List<SpanListRun> runs) {
  final sorted = [...runs]..sort((a, b) => a.start.compareTo(b.start));
  final out = <int, int>{};
  var n = 0;
  for (final r in sorted) {
    if (r.kind != SpanListKind.ordered) {
      n = 0; // 断组：下一个有序项重新开始
      continue;
    }
    out[r.start] = ++n;
  }
  return out;
}

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
