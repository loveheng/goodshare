import 'normalizer.dart';

/// 纯文本 / Markdown → Markdown 子集。
///
/// 两种输入：
/// - 已是 Markdown（含块级标记）→ **直通**（仅做长度门控）
/// - 纯文本（txt / OCR 产出 / ASR 转写）→ 按空行分段为段落块
///
/// 纯文本无层级结构可言，不强造标题——铁律是「宁可样式平，不可吞内容」。
class PlainTextNormalizer extends DocumentNormalizer {
  @override
  List<String> get extensions => const ['txt', 'text', 'log', 'csv'];

  @override
  Future<NormalizedDoc> normalize(
    String content, {
    int maxChars = kNormalizeMaxChars,
  }) async =>
      plainToMarkdown(content, maxChars: maxChars);
}

/// 直通：输入本身就是 Markdown 子集载体。
class MarkdownNormalizer extends DocumentNormalizer {
  @override
  List<String> get extensions => const ['md', 'markdown'];

  @override
  Future<NormalizedDoc> normalize(
    String content, {
    int maxChars = kNormalizeMaxChars,
  }) async =>
      markdownPassthrough(content, maxChars: maxChars);
}

/// 块级标记探测：命中任一即认为已是 Markdown，不再分段。
final RegExp _mdBlockMark = RegExp(
  r'^\s*(#{1,6}\s|[-*+]\s|\d+\.\s|>\s|```)',
  multiLine: true,
);

/// Markdown 直通（只做长度门控与空白规整）。
NormalizedDoc markdownPassthrough(
  String text, {
  int maxChars = kNormalizeMaxChars,
}) {
  var s = text.replaceAll(RegExp(r'\r\n?'), '\n').trim();
  var truncated = false;
  if (s.length > maxChars) {
    s = s.substring(0, maxChars);
    truncated = true;
  }
  return NormalizedDoc(
    markdown: s,
    meta: NormalizeMeta(chars: s.length, truncated: truncated),
  );
}

/// 纯文本 → 段落块（空行分段，不强造标题）。
NormalizedDoc plainToMarkdown(
  String text, {
  int maxChars = kNormalizeMaxChars,
}) {
  if (_mdBlockMark.hasMatch(text)) {
    return markdownPassthrough(text, maxChars: maxChars);
  }
  final paras = text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty);
  final joined = paras.join('\n\n');
  return markdownPassthrough(joined, maxChars: maxChars);
}
