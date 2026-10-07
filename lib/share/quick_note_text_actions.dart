import '../doc/rich_text.dart' show SpanListKind;
import 'quick_note_line_shape.dart';

/// S2 L1 结构动作·文本真相版（note-editor-source-of-truth.md §4.2 / §6）：
/// 回车续标记 / 行首退格出列 / 勾选翻转——**一律写真实文本**（标记本就在
/// 文本里），不再维护坐标 run。纯函数：`(文本, 光标) → (新文本, 新光标)`。
///
/// 与旧路径（`convertQuickNoteLineMarker`/`adjustQuickNoteListRuns` 等）的
/// 等价性由 S2 单测钉住；编辑器接入在 [kNoteMarkerReveal] 旗标下 S3 激活
/// ——S2 阶段旧路径仍在线，本模块只被测试消费（§6「S0–S2 只加不改」）。
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

  // 空列表项 → 退出列表：删标记 + 换行
  if (shape.isList && shape.bodyStart >= line.length) {
    final newText = text.replaceRange(start, end, '');
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
