import '../doc/rich_text.dart';
import 'quick_note_line_shape.dart'
    show headingRe, listMarkerOf;

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
  final listInfo = <SpanListRun?>[];
  // 续行标记：≥2 空格缩进且前一行属列表项 → 归入前序列表项（几何延伸）。
  final isCont = <bool>[];
  var lastWasListPart = false;
  for (final line in lines0) {
    var work = line;
    var removed = 0;
    // 标题优先：剥 `#{1,6} ` 前缀（与解析器 _heading 同源）
    final h = headingRe.firstMatch(work);
    if (h != null) {
      work = work.substring(h.end);
      removed += h.end;
      hashLens.add(h.group(1)!.length);
      listInfo.add(null); // 标题与列表互斥：标题行不再认列表
      isCont.add(false);
      lastWasListPart = false;
    } else {
      hashLens.add(0);
      // 非标题行才认无序列表/待办（`- ` / `* ` / `- [ ]` / `- [x]`）
      final mk = listMarkerOf(work);
      if (mk != null) {
        work = work.substring(mk.end);
        removed += mk.end;
        // 占位（坐标下方补），保留 kind/done
        listInfo.add(SpanListRun(0, 0, mk.kind, done: mk.done));
        isCont.add(false);
        lastWasListPart = true;
      } else {
        // 续行判定（与解析器 _ListSyntax._isContinuation 同口径）：≥2 空格
        // 缩进、非空、前一行属列表项（首行或续行）→ 几何延伸，不另起项。
        final cont =
            line.startsWith('  ') && line.trim().isNotEmpty && lastWasListPart;
        listInfo.add(null);
        isCont.add(cont);
        lastWasListPart = cont; // 续行链：续行之后仍可接续行
      }
    }
    stripped.add(work);
    prefixLens.add(removed);
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
    if (hashLens[i] > 0) {
      final s = lineStarts[i];
      final e = s + stripped[i].length;
      levelRuns.add(SpanLevelRun(s, e, hashLens[i].clamp(1, 6)));
    }
  }

  final listRuns = <SpanListRun>[];
  for (var i = 0; i < lines0.length; i++) {
    final info = listInfo[i];
    if (info != null) {
      final s = lineStarts[i];
      final e = s + stripped[i].length;
      listRuns.add(SpanListRun(s, e, info.kind, done: info.done));
    } else if (isCont[i] && listRuns.isNotEmpty) {
      // 续行：作为前序列表项的几何延伸，end 吞入续行（覆盖到该行行尾，
      // 不含换行符，与其他行级 run 同口径）。**绝不新建 run**——凹槽按
      // run 计数并在 run 首行绘制，新建会让续行重复出圆点/勾选框。
      final last = listRuns.last;
      listRuns[listRuns.length - 1] = SpanListRun(
        last.start,
        lineStarts[i] + stripped[i].length,
        last.kind,
        done: last.done,
      );
    }
  }

  return QuickNoteSpans(
    plain: plain,
    runs: runs,
    levelRuns: levelRuns,
    listRuns: listRuns,
  );
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

/// 光标所在行的区间 `(start, end)`（不含行尾 '\n'）；越界返回 null。
///
/// 三条（[convertQuickNoteLineMarker] / [extendQuickNoteContinuation] /
/// 回车起新项）共用同一「找行」口径，避免各写一遍造成行为漂移。
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

/// 行首列表标记**落定**（Typora 式「输入即转换」；2026-10-07 拍板）：光标所在行
/// 以完整列表标记起手、且尚未转换（本行无 listRun）→ 剥掉该前缀并就地建 run。
///
/// 存在意义：listRuns 此前**只能**由 [seedQuickNote]（草稿/导入）与
/// [insertSeededSpans]（粘贴）产生，逐字输入走的 [applyQuickNoteSpansInput] →
/// [adjustQuickNoteListRuns] 只搬移既有 run、从不新建——故用户手打 `- 甲` /
/// `[ ] 甲` 永远建不出列表。本函数是「打字 → 结构」的唯一落定口。
///
/// 返回**需要回退的光标偏移**（= 剥离长度）；0 = 未转换。调用方必须同步修正
/// selection 与 selBase/selExtent，否则光标会停在已剥掉的位置之后。
///
/// 坐标处理与 [insertSeededSpans] 同口径：既有三维按 old→new **全量重 snap**
/// （不手写坐标），新 run 追加后按 start 排序，与其他生产者的有序性一致。
int convertQuickNoteLineMarker(QuickNoteSpans s, {required int caret}) {
  final range = quickNoteLineRangeAt(s, caret);
  if (range == null) return 0;
  final line = _LineRange(range.$1, range.$2);
  final mk = listMarkerOf(s.plain.substring(line.start, line.end));
  // 幂等判据就是「行首还有没有完整标记」：已转换的行不可能再匹配，故无需
  // 额外按 run 判重（那会把「空占位 run 仍在行首」误判成已转换）。
  if (mk == null) return 0;

  final oldPlain = s.plain;
  final cutEnd = line.start + mk.end;
  final newPlain = oldPlain.replaceRange(line.start, cutEnd, '');
  s.runs = adjustRuns(s.runs, line.start, cutEnd, 0);
  s.levelRuns = adjustQuickNoteLevelRuns(s.levelRuns, oldPlain, newPlain);
  // 本行身份由本次落定接管：丢弃行首既有 run——空占位 run 会被随动宽化成覆盖
  // 整行，若保留将与新 run 重叠（凹槽重复画圆点）。
  final kept = [
    for (final r in adjustQuickNoteListRuns(s.listRuns, oldPlain, newPlain))
      if (r.start != line.start) r,
  ];
  final lists = [
    ...kept,
    SpanListRun(line.start, line.end - mk.end, mk.kind, done: mk.done),
  ]..sort((a, b) => a.start.compareTo(b.start));
  s.listRuns = lists;
  s.plain = newPlain;
  return mk.end;
}

/// 续行归并（2026-10-07）：光标行以 ≥2 空格缩进、内容非空、自身尚无 run、
/// 且**上一行已被某个 run 覆盖** → 吞入该 run 的 end（几何延伸）。
///
/// 存在意义：多行列表项此前只能由 [seedQuickNote]（粘贴/导入）产生——逐字输入
/// 走的 [adjustQuickNoteListRuns] 只搬移既有 run、从不吞并新行，故用户用
/// Shift+Enter 软换行后缩进续写，续行永远不属于前一项。本函数补齐「打字 →
/// 续行」最后一环。
///
/// ⚠️ **绝不新建 run**：凹槽按 run 计数并在 run 首行绘制，新建会让续行重复
/// 出圆点/勾选框——此处只改既有 run 的 end。
void extendQuickNoteContinuation(QuickNoteSpans s, {required int caret}) {
  if (caret < 0 || caret > s.plain.length) return;
  final lines = _lineRanges(s.plain);
  var li = -1;
  for (var i = 0; i < lines.length; i++) {
    if (caret >= lines[i].start && caret <= lines[i].end) {
      li = i;
      break;
    }
  }
  if (li <= 0) return; // 首行无「前序列表项」可依
  final line = lines[li];
  if (!s.plain.startsWith('  ', line.start)) return; // 与播种/解析器同口径：≥2 空格
  if (s.plain.substring(line.start, line.end).trim().isEmpty) return;
  for (final r in s.listRuns) {
    if (r.start == line.start) return; // 自身已是独立列表项
  }
  final prev = lines[li - 1];
  var ti = -1;
  for (var i = 0; i < s.listRuns.length; i++) {
    final r = s.listRuns[i];
    // 上一行被该 run 覆盖（首行或已被吞并的续行）→ 它就是宿主
    if (r.start <= prev.start && prev.end <= r.end) {
      ti = i;
      break;
    }
  }
  if (ti < 0) return; // 上一行不属列表 → 这是普通缩进文本，不该并
  final host = s.listRuns[ti];
  s.listRuns[ti] = SpanListRun(host.start, line.end, host.kind, done: host.done);
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
  s.listRuns = adjustQuickNoteListRuns(s.listRuns, s.plain, newText);
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
    if (L.start == L.end) {
      // 空行挂档：[setQuickNoteLevel] 允许先给空行挂档、之后输入即成标题行
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
/// runs/levels/lists 坐标——「导入 md」弹框专用：剪贴板文本 → [seedQuickNote]
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

  // 行级/列表 runs 直接按 old→new 文本全量重 snap（与 applyQuickNoteSpansInput 同口径）
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

/// 保存/草稿序列化：plain + runs + 行级 runs → human_md（行首标题前缀 +
/// 行内标记，与详情页块序列化同一 grammar 出口）。行内 runs 按行截取后重建
/// 节点树——跨行的 run 坐标在本行坐标系内平移。
String serializeQuickNoteSpans(QuickNoteSpans s) {
  final lines = s.plain.split('\n');
  final out = <String>[];
  final ords = quickNoteOrderedOrdinals(s.listRuns);
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
    // 列表/待办行优先认列表前缀（与标题互斥）；其次认标题；否则裸 body。
    SpanListRun? lr;
    for (final r in s.listRuns) {
      // 仅 run 的**首行**带列表标记：续行虽被 run 的 end 吞入作几何延伸，
      // 但仍是同一列表项的一部分，绝不能再加 `- `/`- [ ] ` 前缀——否则回写
      // 会把续行变成新列表项（多行被拍平，缩进丢失）。
      // 判据保留 `lineStart < r.end`：空列表行（end==start）照旧不加标记。
      if (lineStart == r.start && lineStart < r.end) {
        lr = r;
        break;
      }
    }
    if (lr != null) {
      final marker = switch (lr.kind) {
        SpanListKind.todo => lr.done ? '- [x] ' : '- [ ] ',
        // 序号始终取**当前**连续组内序数（不存数字），故中间插入/删除项后
        // 自动重排——与详情页「每个 ListBlock 从 1 输出」同源。
        SpanListKind.ordered => '${ords[lr.start] ?? 1}. ',
        SpanListKind.bullet => '- ',
      };
      out.add('$marker$body');
    } else if (level > 0 && line.isNotEmpty) {
      // 无档位行必须走 body（含行内标记序列化）——输出原始 line 会丢 **/*/<u>
      out.add('${'#' * level} $body');
    } else {
      out.add(body);
    }
    pos = lineEnd + 1;
  }
  return out.join('\n');
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
