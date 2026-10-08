import '../doc/rich_text.dart'
    show
        InlineRun,
        SpanLevelRun,
        SpanListKind,
        SpanListRun,
        inlineNodesOf,
        inlineSpansOf,
        serializeInline,
        spanChangeRange;
import 'quick_note_line_shape.dart';
import 'quick_note_span_codec.dart' show QuickNoteSpans, SpanCodeRun;

/// S2 L1 结构动作·文本真相版（note-editor-source-of-truth.md §4.2 / §6）：
/// 回车续标记 / 行首退格出列 / 勾选翻转——**一律写真实文本**（标记本就在
/// 文本里），不再维护坐标 run。纯函数：`(文本, 光标) → (新文本, 新光标)`。
///
/// 与旧坐标随动路径的等价性由 S2 单测钉住；S3（2026-10-07）真机验收通过后，
/// 旧路径与双路径分支一并删除——本模块成为编辑器的唯一行级动作实现（§6）。
///
/// 有序序号口径（§2.4）：buffer 存字面数字，显示重排归 L2；回车起新项时
/// 新行字面序号 = 当前行字面序号 + 1（落盘规整在序列化出口统一做）。

/// 动作结果：新文本 + 新光标（null = 动作不适用，调用方放行既有逻辑）。
class TextActionResult {
  const TextActionResult(this.text, this.caret);

  final String text;
  final int caret;
}

/// 行区间（含行内偏移定位的公共 helper）。
(int start, int end)? _lineRangeAt(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  var start = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i == text.length || text.codeUnitAt(i) == 0x0A) {
      if (caret >= start && caret <= i) return (start, i);
      start = i + 1;
    }
  }
  return null;
}

/// 行首列表标记的字面前缀（回车续标记用；todo 新项恒未勾选）。
String _markerPrefix(SpanListKind kind) => switch (kind) {
      SpanListKind.bullet => '- ',
      SpanListKind.todo => '- [ ] ',
      SpanListKind.ordered => '',
    };

/// 回车落在 [caret]（文本真相版，对应旧 `_enterOnListLine`）：
///
/// - 空列表项（标记后无正文）：**退出列表**——删掉本行标记，插 `\n`，新行
///   回正文（与旧「摘占位 run」同语义）；
/// - 列表项且光标在正文区：插 `\n` + 新行同类型标记（todo 恒 `[ ]` 不继承
///   勾选；有序新行字面序号 = 当前行 + 1）；
/// - 光标在标记区内（正在编辑标记本身）：只插 `\n`，不续标记；
/// - 标题行：插 `\n`，新行回正文（档位止于本行，与旧随动语义一致）；
/// - 纯文本行：只插 `\n`（调用方既有拆段/软换行逻辑接管）。
///
/// 选区塌缩由调用方保证（非塌缩光标应放行原生行为）。
TextActionResult? enterWithMarker(String text, int caret) {
  final range = _lineRangeAt(text, caret);
  if (range == null) return null;
  final (start, end) = range;
  final line = text.substring(start, end);
  final shape = parseLine(line);
  final localCaret = caret - start;

  // 空列表项 → 退出列表：标记换成换行（删标记 + 落到新空行，与旧语义一致）
  if (shape.isList && shape.bodyStart >= line.length) {
    final newText = text.replaceRange(start, end, '\n');
    return TextActionResult(newText, start);
  }

  String insert = '\n';
  if (shape.isList && localCaret > shape.markerEnd) {
    final prefix = shape.listKind == SpanListKind.ordered
        ? '${int.tryParse(
                RegExp(r'^\s*(\d+)').firstMatch(line)?.group(1) ?? '1',
              )! + 1}. '
        : _markerPrefix(shape.listKind!);
    insert = '\n$prefix';
  }
  final newText = text.replaceRange(caret, caret, insert);
  return TextActionResult(newText, caret + insert.length);
}

/// 行首退格（文本真相版，对应旧「行首退格出列/退挡」）：
///
/// - 光标塌缩在**标记行行首**（[caret]==0 即文本首行行首，或前一字符为 `\n`）：
///   删掉本行标记（出列回正文），`\n` 不动；
/// - 否则返回 null（并行/删字符归既有文本变更路径）。
TextActionResult? backspaceOutdent(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  // 行首判定：caret 是文本首（首行行首）或前一个字符是 \n
  if (caret != 0 && text.codeUnitAt(caret - 1) != 0x0A) return null;
  final range = _lineRangeAt(text, caret);
  if (range == null) return null;
  final (start, end) = range;
  final shape = parseLine(text.substring(start, end));
  if (!shape.isList && !shape.isHeading) return null;
  final newText = text.replaceRange(start, start + shape.markerEnd, '');
  return TextActionResult(newText, start);
}

/// 勾选翻转（文本真相版，对应旧 `_toggleTodo`）：翻转 [lineStart] 行内
/// `[ ]` ↔ `[x]` 字面。非待办行返回 null。
TextActionResult? toggleTodo(String text, int lineStart) {
  if (lineStart < 0 || lineStart >= text.length) return null;
  final end = text.indexOf('\n', lineStart);
  final lineEnd = end < 0 ? text.length : end;
  final line = text.substring(lineStart, lineEnd);
  final shape = parseLine(line);
  if (!shape.isList || shape.listKind != SpanListKind.todo) return null;
  // 字面里找勾选框（裸写与 `- ` 前缀都在标记区内）
  final cbStart = line.indexOf('[', 0);
  int cbEnd;
  String replacement;
  if (line.startsWith('[x]', cbStart) || line.startsWith('[X]', cbStart)) {
    cbEnd = cbStart + 3;
    replacement = '[ ]';
  } else if (line.startsWith('[ ]', cbStart)) {
    cbEnd = cbStart + 3;
    replacement = '[x]';
  } else {
    return null; // 标记已被剥掉（转换后状态）——文本真相下不应发生
  }
  final newText = text.replaceRange(
    lineStart + cbStart,
    lineStart + cbEnd,
    replacement,
  );
  return TextActionResult(newText, lineStart + cbStart + 2);
}

/// 文本真相序列化出口（§4.3 B3）：「保存 md = 文本本身」——恒等 + 有序组
/// 落盘规整。标记本就在文本里，无需坐标重建。
String serializeTextTruth(String text) => normalizeOrderedNumbers(text);

/// 档位直设（文本真相版，取代已删除的旧坐标换挡）：[caret] 所在行
/// level>0 → 行首写「`#`×level + 空格」前缀（与 headingRe `^(#{1,6})\s+`
/// **同源**——写成 `#1 ` 派生产不出档位，保存即丢）；level==0 → 删行首
/// 标记回正文。返回 null = 行无变化（已是目标档位/越界）。
TextActionResult? setLineLevel(String text, int caret, int level) {
  if (caret < 0 || caret > text.length || level < 0 || level > 6) return null;
  final range = _lineRangeAt(text, caret);
  if (range == null) return null;
  final (start, end) = range;
  final line = text.substring(start, end);
  final shape = parseLine(line);
  if (level == 0) {
    if (shape.markerEnd == 0) return null;
    final newText = text.replaceRange(start, start + shape.markerEnd, '');
    return TextActionResult(
        newText, (caret - shape.markerEnd).clamp(0, newText.length));
  }
  final prefix = '${'#' * level} ';
  if (shape.isHeading && shape.level == level) return null;
  // 换挡：替换旧标记（含标题档位与列表标记）；正文起手：插前缀
  final oldLen = shape.isHeading || shape.isList ? shape.markerEnd : 0;
  final newText = text.replaceRange(start, start + oldLen, prefix);
  return TextActionResult(newText, caret - oldLen + prefix.length);
}

// ---------------------------------------------------------------------------
// S3 文本真相三件套（note-editor-source-of-truth.md §2/§6 唯一不可逆点）
// ---------------------------------------------------------------------------

/// 播种·文本真相版：md 原文 → QuickNoteSpans。
///
/// §8 范围口径：**线级标记进文本**（`- `/`# `/`- [x] ` 留在 plain），**行内
/// 标记不进**（`**`/`<u>` 等仍走 runs 坐标模型，先选后打不变）。因此：
/// - `plain` = 原文剥行内标记（保留线级前缀）——TextField 文本、光标、
///   runs、派生视图共用这一个坐标系（§4.5 单坐标系）；
/// - `runs` = 逐行剥线级前缀后 inlineSpansOf 的行内 run，平移到 plain 系
///   （正文起点 = 线级 markerEnd）；
/// - `levelRuns`/`listRuns` = [deriveLineRuns] 派生视图（凹槽/转盘消费）。
QuickNoteSpans seedTextTruth(String source) {
  final lines = source.split('\n');
  final plainLines = <String>[];
  final runs = <InlineRun>[];
  var plainPos = 0;
  for (final line in lines) {
    final shape = parseLine(line);
    final marker = line.substring(0, shape.markerEnd);
    final spans = inlineSpansOf(line.substring(shape.markerEnd));
    plainLines.add('$marker${spans.plain}');
    final bodyStart = plainPos + shape.markerEnd;
    for (final r in spans.runs) {
      runs.add(InlineRun(bodyStart + r.start, bodyStart + r.end, r.mark,
          url: r.url));
    }
    plainPos += shape.markerEnd + spans.plain.length + 1;
  }
  final out = QuickNoteSpans(plain: plainLines.join('\n'), runs: runs);
  deriveLineRuns(out);
  return out;
}

/// 行级派生（就地重算）：逐行 parseLine → levelRuns/listRuns 视图。
///
/// 文本真相下的**唯一行级事实源**——任何文本变更后调用一次即完成「随动」
/// （不再有 adjustQuickNoteLevelRuns/listRuns 的坐标搬运）。标题与列表
/// 互斥、标题优先等口径全部内建于 parseLine（S0 原语）。
///
/// ⚠️ 凹槽「续行吞入」语义：多行列表项的续行（≥2 空格缩进）几何延伸到
/// 宿主 run 的 end（与旧播种/序列化同口径），凹槽不在续行重复画点。
void deriveLineRuns(QuickNoteSpans s) {
  final lines = s.plain.split('\n');
  final levels = <SpanLevelRun>[];
  final lists = <SpanListRun>[];
  final codes = <SpanCodeRun>[];
  var pos = 0;
  var fenceStart = -1; // 开栏行首偏移；-1 = 不在围栏内
  for (final line in lines) {
    final start = pos;
    final end = pos + line.length;
    pos = end + 1;
    final shape = parseLine(line);
    // 围栏状态机优先（与解析器 _FenceSyntax 同语义：栏内一切行都是代码，
    // 不再认标题/列表/引用；合栏行收区域）
    if (fenceStart >= 0) {
      if (shape.isFence) {
        codes.add(SpanCodeRun(fenceStart, end)); // 合栏行含入区域
        fenceStart = -1;
      }
      continue;
    }
    if (shape.isFence) {
      fenceStart = start; // 开栏行含入区域
      continue;
    }
    if (shape.isHeading) {
      levels.add(SpanLevelRun(start, end, shape.level));
    } else if (shape.isList) {
      lists.add(SpanListRun(start, end, shape.listKind!, done: shape.done));
    } else if (line.startsWith('  ') && line.trim().isNotEmpty && lists.isNotEmpty) {
      // 续行：几何延伸宿主 run 的 end（绝不新建 run——凹槽按 run 首行画）
      final last = lists.last;
      lists[lists.length - 1] =
          SpanListRun(last.start, end, last.kind, done: last.done);
    }
  }
  // 未合栏：区域延伸到文本末（与解析器「未闭合按到文末」同口径）
  if (fenceStart >= 0) {
    codes.add(SpanCodeRun(fenceStart, s.plain.length));
  }
  s.levelRuns = levels;
  s.listRuns = lists;
  s.codeRuns = codes;
}

/// 序列化·文本真相版：QuickNoteSpans → md。线级标记本就在 plain 里，
/// 只剩行内 runs 的序列化（与已删除的旧出口同源的行内部分）+
/// 有序组落盘规整。§8：inline 仍在坐标模型，故不能整段恒等。
String serializeTextTruthSpans(QuickNoteSpans s) {
  // 行内 runs 在 plain（含线级标记文本）上的序列化：**线级前缀原样保留**
  // （不是正文，绝不能进行内转义——`- [ ] ` 的 `[` 会被转成 `\[`），只有
  // 标记区之后的正文走行内节点树重建；runs 截取平移到正文系。
  final lines = s.plain.split('\n');
  final out = <String>[];
  var pos = 0;
  for (final line in lines) {
    final lineStart = pos;
    final lineEnd = pos + line.length;
    final shape = parseLine(line);
    final bodyStart = lineStart + shape.markerEnd;
    final sub = [
      for (final r in s.runs)
        if (r.end > bodyStart && r.start < lineEnd)
          InlineRun(
            r.start > bodyStart ? r.start - bodyStart : 0,
            r.end < lineEnd ? r.end - bodyStart : line.length - shape.markerEnd,
            r.mark,
            url: r.url,
          ),
    ];
    final body = line.substring(shape.markerEnd);
    final serialized =
        serializeInline(inlineNodesOf(body, sub));
    out.add('${line.substring(0, shape.markerEnd)}$serialized');
    pos = lineEnd + 1;
  }
  return normalizeOrderedNumbers(out.join('\n'));
}


/// 一次文本变更的处置类别（编辑器 `_onSegChanged` 的路径分流判据）。
enum TextEditKind {
  /// 行内变更（打字 / 删除）→ 行内 runs 字符级随动 + 行级身份重派生。
  inline,

  /// 列表行回车：只插入**单个** `\n` 且落在列表首行 → 交 [enterWithMarker]
  /// 就地起新项（不拆段——拆段会把列表切成互不相干的独立段，多行项与续行
  /// 都无从谈起）。
  listEnter,

  /// 换行物化：插入的文本含 `\n`（软键盘回车 / 多行粘贴）→ 逐 `\n` 拆段。
  splitLines,
}

/// [planTextEdit] 的结果：处置类别 + 变更窗起点 + 本次插入的文本。
class TextEditPlan {
  const TextEditPlan(this.kind, this.start, this.inserted);

  final TextEditKind kind;

  /// 变更窗起点（[spanChangeRange] 口径）：列表行判定与拆段定位都以此为锚。
  final int start;

  /// 本次插入的文本（纯删除时为空串）。
  final String inserted;
}

/// 文本变更 → 处置判据（纯函数，**可表驱动单测**）。
///
/// 编辑器 `_onSegChanged` 的路径分流集中于此：软键盘无 shift 语义、粘贴无
/// 按键事件，行级动作只能从**文本变更侧**判据，物理无修饰回车同路收敛——
/// 判据一旦分散，四条入口（物理 / 软键盘 / IME / 粘贴）就会各行其是。
///
/// - [composing] = IME 组合期（拼音未上屏）：改文本会打断组合，一律放行
///   原生行为（落到 [TextEditKind.splitLines] 由拆段兜底）。
/// - [isListLineAt] = 变更窗起点所在行是否为**列表首行**；宿主用
///   `quickNoteLineRangeAt` + `quickNoteListRunAt` 判定后以闭包传入，使本
///   函数保持零 Flutter 依赖。
TextEditPlan planTextEdit({
  required String oldPlain,
  required String newText,
  required bool composing,
  required bool Function(int start) isListLineAt,
}) {
  final (start, oldEnd) = spanChangeRange(oldPlain, newText);
  final insertLen = newText.length - oldPlain.length + (oldEnd - start);
  final inserted = insertLen > 0
      ? newText.substring(start, start + insertLen)
      : '';
  if (!inserted.contains('\n')) {
    return TextEditPlan(TextEditKind.inline, start, inserted);
  }
  if (inserted == '\n' && !composing && isListLineAt(start)) {
    return TextEditPlan(TextEditKind.listEnter, start, inserted);
  }
  return TextEditPlan(TextEditKind.splitLines, start, inserted);
}

/// 文本真相序列化出口的有序组规整（§2.4 落盘清洗）：连续有序组按出现顺序
/// 重编字面序号（1 起递增，非有序行断组）——与旧 `quickNoteOrderedOrdinals`
/// 的组判定口径一致（同一连续组内逐行递增）。
///
/// 仅供保存路径调用；编辑期 buffer 不规整（用户字面保留）。
String normalizeOrderedNumbers(String text) {
  final lines = text.split('\n');
  var expect = 0;
  for (var i = 0; i < lines.length; i++) {
    final shape = parseLine(lines[i]);
    if (shape.isList && shape.listKind == SpanListKind.ordered) {
      expect++;
      lines[i] = lines[i].replaceFirst(
        RegExp(r'^(\s*)\d+[.)]'),
        '$expect.',
      );
    } else if (!lines[i].startsWith('  ') || lines[i].trim().isEmpty) {
      expect = 0; // 断组（缩进续行不断组——与解析器 _isContinuation 同口径）
    }
  }
  return lines.join('\n');
}

/// B+ 门禁2（纯函数版）：删除型结构判定——当且仅当一次文本删除「可能制造有序
/// 序号空洞」时返回 true：删区跨越了换行符（整行被删）或包含了行首有序 marker
/// （`\d+.` / `\d).`）。纯中段文字删除（不跨行、不删 marker）物理上不可能造空洞，
/// 直接放行（O(1) 长度比较 + 删区特征，绝不每键扫全篇）。替换型序号改写（长度
/// 相等）不视为删除，故用户主动改序号不会被重排误伤。
///
/// 调用方须先过 IME 绝热守卫（compose 态不传本函数）。[oldPlain]/[newPlain]
/// 为变更前后文本，[spanChangeRange] 夹出删区（旧坐标）。
bool detectStructuralDeletion(String oldPlain, String newPlain) {
  if (newPlain.length >= oldPlain.length) return false; // 非删除（插入/替换/等长）
  final (s0, e0) = spanChangeRange(oldPlain, newPlain);
  if (e0 <= s0) return false;
  final deleted = oldPlain.substring(s0, e0);
  final lostNewline = deleted.contains('\n');
  final hasMarker = RegExp(r'(?:^|\n)[ \t]*\d+[.)][ \t]').hasMatch(deleted);
  return lostNewline || hasMarker;
}

/// 编辑期·有序组局部重编号（治「编辑期空洞序号」#3）。沿同缩进连续有序组就地
/// 重编字面序号 1..k 写回 [text]。返回 `(新文本, 重映射光标)`——前缀宽度变化
/// （如 9→10 跨位）已计入光标偏移，杜绝「显示序号 / 光标 offset / buffer 字符数」
/// 三者错位引发的雪崩。
///
/// ⚠️ 收口规则（2026-10-08 修订）：编辑期物化路径有二——①键盘动作层（回车续项
/// `_commitEnter` / 退格出列 `backspaceOutdentAt`，插入型/出列型组变化）；②
/// `applyTextEdit` 的删除型分支（门禁1 IME 绝热 + 门禁2 `detectStructuralDeletion`
/// 通过后调用，覆盖打字删 / 选区删 / IME 删等所有经 onChanged 的路径）。buffer 仍存
/// 字面（保存 md 恒等），符合 text-truth 不变量。全文本扫描所有连续组，O(k)。
(String, int) renumberOrderedGroup(String text, int caret) {
  if (caret < 0 || caret > text.length) return (text, caret);
  final lines = text.split('\n');
  final caretLine = _lineIndexAtOffset(text, caret);
  // 锚定 caret 行或最近相邻有序行（替换已删的 _nearestOrderedLine，零依赖）。
  int? anchor;
  if (caretLine >= 0 && caretLine < lines.length && _isOrderedLine(lines[caretLine])) {
    anchor = caretLine;
  } else if (caretLine + 1 < lines.length && _isOrderedLine(lines[caretLine + 1])) {
    anchor = caretLine + 1;
  } else if (caretLine - 1 >= 0 && _isOrderedLine(lines[caretLine - 1])) {
    anchor = caretLine - 1;
  }
  if (anchor == null) return (text, caret);
  // 沿同缩进连续有序组双向扩到组边界（断组 / 孤立项不误伤，仅重排受影响组）。
  var gStart = anchor;
  while (gStart > 0 && _sameOrderedGroup(lines[gStart - 1], lines[gStart])) {
    gStart--;
  }
  var gEnd = anchor;
  while (gEnd < lines.length - 1 &&
      _sameOrderedGroup(lines[gEnd], lines[gEnd + 1])) {
    gEnd++;
  }
  final newLines = List<String>.from(lines);
  var n = 0;
  for (var i = gStart; i <= gEnd; i++) {
    n++;
    // replaceFirstMapped 保留缩进（捕获组 1），避免嵌套有序项丢前导空格
    newLines[i] = lines[i].replaceFirstMapped(
      RegExp(r'^(\s*)(\d+)[.)]'),
      (m) => '${m[1]}$n.',
    );
  }
  final newText = newLines.join('\n');
  if (newText == text) return (text, caret);
  return (
    newText,
    _remapCaretForRenumber(
      text, lines, newLines, gStart, gEnd, caretLine, caret,
    ),
  );
}

/// [caret] 在 [text] 中的行号（\n 计数）。
int _lineIndexAtOffset(String text, int caret) {
  var line = 0;
  for (var i = 0; i < caret && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

bool _isOrderedLine(String line) {
  final s = parseLine(line);
  return s.isList && s.listKind == SpanListKind.ordered;
}

/// 两行是否同属一个连续有序组：皆有序 + 同缩进（嵌套组由此隔离）。
bool _sameOrderedGroup(String prev, String cur) {
  if (!_isOrderedLine(prev) || !_isOrderedLine(cur)) return false;
  return _indentOf(prev) == _indentOf(cur);
}

int _indentOf(String line) {
  final m = RegExp(r'^(\s*)').firstMatch(line);
  return m?.group(1)?.length ?? 0;
}

/// 重编号后把旧光标映射到新文本（前缀宽度变化计入）。
int _remapCaretForRenumber(
  String oldText,
  List<String> oldLines,
  List<String> newLines,
  int gStart,
  int gEnd,
  int caretLine,
  int caret,
) {
  final lineStarts = <int>[0];
  for (var i = 0; i < oldText.length; i++) {
    if (oldText.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
  }
  // caret 之前的重编号行累计宽度差
  var deltaBefore = 0;
  for (var i = gStart; i < caretLine && i <= gEnd; i++) {
    deltaBefore += _prefixDelta(oldLines[i], newLines[i]);
  }
  if (caretLine >= gStart && caretLine <= gEnd) {
    final ls = lineStarts[caretLine];
    final oldP = _orderedPrefixLen(oldLines[caretLine]);
    final newP = _orderedPrefixLen(newLines[caretLine]);
    if (caret <= ls + oldP) return ls + newP; // 光标在/紧邻前缀：钳到新前缀尾
    return caret + (newP - oldP);
  }
  return caret + deltaBefore;
}

int _prefixDelta(String oldLine, String newLine) {
  if (!_isOrderedLine(oldLine) || !_isOrderedLine(newLine)) return 0;
  return _orderedPrefixLen(newLine) - _orderedPrefixLen(oldLine);
}

int _orderedPrefixLen(String line) => parseLine(line).markerEnd;

/// 浮层选块·目标类型（问题#1 引导层）：把光标行直设为下列之一。有序是列表
/// 的自动派生变体，不由面板直设（有序走回车续号），故面板暴露这六个显式类型。
///
/// 待办 2026-10-08 拍板**回归浮层**（推翻 2026-10-03「去掉待办列表」）：收集
/// 场景「待看/待买/待办」是高频诉求，此前只能手打 `- [ ] ` 或 md 导入产出，
/// 无显式入口；勾选态切换仍走 [toggleTodo]（二者分工：建行走本枚举、翻勾选
/// 走 toggleTodo）。
enum LineKindTarget { plain, h1, h2, bullet, quote, todo }

/// 段类型直设（文本真相，与 [setLineLevel] 同源）：把 [caret] 所在行整行直设为
/// [target] 语义（普通/一级/二级/无序/引用/待办）。标题与列表/引用互斥，统一走
/// 「替换行首标记区」——[parseLine] 派生 `markerEnd` 原子定位旧标记宽度，零坐标
/// 搬运（与阶段二「标记本就在文本里」不变量一致）。返回 null = 已是目标
/// （无变化，调用方不记撤销步）。
TextActionResult? setLineKindAction(String text, int caret, LineKindTarget target) {
  if (caret < 0 || caret > text.length) return null;
  final range = _lineRangeAt(text, caret);
  if (range == null) return null;
  final (start, end) = range;
  final line = text.substring(start, end);
  final shape = parseLine(line);
  final desired = switch (target) {
    LineKindTarget.plain => '',
    LineKindTarget.h1 => '# ',
    LineKindTarget.h2 => '## ',
    LineKindTarget.bullet => '- ',
    LineKindTarget.quote => '> ',
    LineKindTarget.todo => '- [ ] ',
  };
  // 已是目标（含裸勾选框 `[ ] `/todo/有序等非显式类型——需显式转才清）：仅当旧
  // 标记区字面等于目标前缀才视为无变化，避免重复改写搅动 undo。
  if (line.substring(0, shape.markerEnd) == desired) return null;
  final newText = text.replaceRange(start, start + shape.markerEnd, desired);
  final newCaret = (caret - shape.markerEnd + desired.length).clamp(0, newText.length);
  return TextActionResult(newText, newCaret);
}
