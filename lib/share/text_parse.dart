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
    title: isPureUrl ? null : (around.isEmpty ? null : around.split('\n').first.trim()),
    text: raw,
  );
}

String? _firstLine(String s) {
  final line = s.trim().split('\n').first.trim();
  return line.isEmpty ? null : (line.length > 80 ? '${line.substring(0, 80)}…' : line);
}
