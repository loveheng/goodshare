import '../ai/url_extract.dart' show decodeEntities;
import 'normalizer.dart';

/// HTML → Markdown 子集（**保结构**）。
///
/// 背景：既有 `url_extract.extractReadableText` 把标签全剥成纯文本，标题层级、
/// 列表、引用、代码块**全部丢失**——富文本渲染器无米下锅。本转换器保留结构。
///
/// 降级纪律（铁律：宁可样式平，不可吞内容）：
/// - 表格 → 纯文本，计数进 `meta.degradedBlocks`
/// - 图片 → `[图片：alt]` 文本占位（富文本载体不支持内联图片）
/// - 有序列表 → 统一为 `- `（有序性不保留，属已知降级）
/// - 其余不认识的标签 → 剥为纯文本
class HtmlNormalizer extends DocumentNormalizer {
  @override
  List<String> get extensions => const ['html', 'htm', 'xhtml'];

  @override
  Future<NormalizedDoc> normalize(
    String content, {
    int maxChars = kNormalizeMaxChars,
  }) async =>
      htmlToMarkdown(content, maxChars: maxChars);
}

/// HTML → Markdown 纯函数（可单测，不依赖 Flutter）。
NormalizedDoc htmlToMarkdown(
  String html, {
  int maxChars = kNormalizeMaxChars,
}) {
  var s = html;
  var degraded = 0;

  // 1. 去噪：脚本 / 样式 / 注释
  s = s.replaceAll(
      RegExp(r'<(script|style|head|noscript|svg|iframe)[^>]*>.*?</\1>',
          dotAll: true, caseSensitive: false),
      ' ');
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ');

  // 2. 表格：降级为纯文本并计数（不静默吞掉）
  degraded += RegExp(r'<table', caseSensitive: false).allMatches(s).length;
  s = s.replaceAll(
      RegExp(r'</?(table|thead|tbody|tfoot|tr|td|th)[^>]*>', caseSensitive: false), ' ');

  // 3. 块级结构（必须先于剩余标签剥离处理）
  s = s.replaceAllMapped(
      RegExp(r'<h([1-6])[^>]*>(.*?)</h\1>', dotAll: true, caseSensitive: false),
      (m) => '\n\n${'#' * int.parse(m.group(1)!)} ${_text(m.group(2)!)}\n\n');

  s = s.replaceAllMapped(
      RegExp(r'<blockquote[^>]*>(.*?)</blockquote>', dotAll: true, caseSensitive: false), (m) {
    final body = _text(m.group(1)!).trim();
    if (body.isEmpty) return '';
    return '\n\n${body.split('\n').map((l) => '> ${l.trim()}').join('\n')}\n\n';
  });

  s = s.replaceAllMapped(
      RegExp(r'<pre[^>]*>(.*?)</pre>', dotAll: true, caseSensitive: false), (m) {
    final body = _text(m.group(1)!).trim();
    if (body.isEmpty) return '';
    return '\n\n```\n$body\n```\n\n';
  });

  s = s.replaceAllMapped(
      RegExp(r'<li[^>]*>(.*?)</li>', dotAll: true, caseSensitive: false),
      (m) => '\n- ${_text(m.group(1)!)}');

  // 4. 行内样式
  s = s.replaceAllMapped(
      RegExp(r'<(strong|b)[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false),
      (m) => '**${_text(m.group(2)!)}**');
  s = s.replaceAllMapped(
      RegExp(r'<(em|i)[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false),
      (m) => '*${_text(m.group(2)!)}*');
  s = s.replaceAllMapped(
      RegExp(r'<code[^>]*>(.*?)</code>', dotAll: true, caseSensitive: false),
      (m) => '`${_text(m.group(1)!)}`');
  s = s.replaceAllMapped(
      RegExp(r'<a\s[^>]*href="([^"]*)"[^>]*>(.*?)</a>', dotAll: true, caseSensitive: false),
      (m) => '[${_text(m.group(2)!)}](${m.group(1)})');

  // 5. 图片：降级为文本占位（载体不支持内联图片）
  s = s.replaceAllMapped(
      RegExp(r'<img[^>]*?alt="([^"]*)"[^>]*>', caseSensitive: false),
      (m) => '[图片：${m.group(1)!.trim()}]');
  s = s.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '');

  // 6. 换行与段落边界
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(
      RegExp(r'</(p|div|tr|h[1-6]|ul|ol|blockquote|pre|section|article)>',
          caseSensitive: false),
      '\n\n');

  // 7. 剩余标签一律剥为纯文本；实体在最后统一解码
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = decodeEntities(s);

  // 8. 空白压缩
  s = s.replaceAll(RegExp(r'[ \t\r\f]+'), ' ');
  s = s.replaceAll(RegExp(r'\n[ \t]*\n(?:\s*\n)+'), '\n\n');
  s = s.trim();

  // 9. 长度门控
  var truncated = false;
  if (s.length > maxChars) {
    s = s.substring(0, maxChars);
    truncated = true;
  }

  return NormalizedDoc(
    markdown: s,
    meta: NormalizeMeta(
      chars: s.length,
      degradedBlocks: degraded,
      truncated: truncated,
    ),
  );
}

/// 剥掉片段内所有标签（**不解码实体**——实体留到最后统一解码，
/// 避免 `&lt;` 变成 `<` 后被后续正则误判为标签）。
String _text(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '').trim();
