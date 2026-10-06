import '../doc/rich_text.dart';
import '../models/item.dart';

/// 文本/链接归一（摄入共用，ShareIntake 与 TextCollector 均走此函数）：
/// - 纯 URL → url
/// - 「标题\nURL」→ url，首行作标题
/// - 其余 → note
({String type, String? title, String text}) parseCollectedText(String raw) {
  final urlRe = RegExp(r'https?://\S+', caseSensitive: false);
  final match = urlRe.firstMatch(raw);
  if (match == null) {
    return (type: InboxItem.typeNote, title: _firstLine(raw), text: raw);
  }
  final url = match.group(0)!;
  final around = raw.replaceFirst(url, '').trim();
  final isPureUrl = around.isEmpty && raw.trim() == url;
  return (
    type: InboxItem.typeUrl,
    // 「标题\nURL」首行可能是 md 行（如 `# 标题`）→ 剥壳落纯文本标题
    title: isPureUrl
        ? null
        : (around.isEmpty ? null : titleToPlain(around.split('\n').first.trim())),
    text: raw,
  );
}

/// 原文首行 → 纯文本标题（剥行内标记与行首 `#`；剥完为空按无标题处理）。
String? _firstLine(String s) {
  final line = titleToPlain(s.trim().split('\n').first.trim());
  if (line.isEmpty) return null;
  return line.length > 80 ? '${line.substring(0, 80)}…' : line;
}
