import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// URL 抓取与正文提取（2026-09-27 决策：链接离线成内容，设置开关控制）。
/// 零依赖实现：拉取 HTML → 去脚本/样式 → 剥标签 → 实体解码 → 压缩空白。
/// 已知限制：非 UTF-8（GBK）站点按 UTF-8 解码会乱码（后续可引入编码探测）；
/// 复杂网页的可读性抽取（readability 级）为后续打磨项。

String? firstUrl(String raw) {
  final matched = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(raw)?.group(0);
  if (matched == null) return null;
  // 剥掉不配对的尾部 `)`：贪婪 \S+ 会把 markdown `[a](http://x.png)` 的结尾
  // 括号吃进 URL（真机验收实证：OG 预取 404）；含配对括号的合法 URL（如维基
  // 词条）不受影响。
  String url = matched; // 显式非空类型，不依赖流分析提升
  while (url.endsWith(')')) {
    final opens = '('.allMatches(url).length;
    final closes = ')'.allMatches(url).length;
    if (closes > opens) {
      url = url.substring(0, url.length - 1);
    } else {
      break;
    }
  }
  return url;
}

/// 拉取网页**原始 HTML**（供保结构归一化用）。
///
/// 背景：既有 [fetchReadable] 直接把标签剥成纯文本，标题层级 / 列表 / 引用 /
/// 代码块**全部丢失**，富文本渲染器无米下锅。保结构转换需要拿到原始 HTML。
Future<String?> fetchHtml(String url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final html = await utf8.decodeStream(response);
    return html.isEmpty ? null : html;
  } catch (e) {
    debugPrint('[UrlExtract] fetch html failed: $e');
    return null;
  } finally {
    client.close();
  }
}

/// 拉取网页并提取可读文本；失败返回 null（调用方回退占位行为）。
///
/// 注：本函数**丢结构**（剥成纯文本），仅用于不需要富文本结构的场景；
/// 保结构路径请用 [fetchHtml] + `htmlToMarkdown`。
Future<String?> fetchReadable(String url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final html = await utf8.decodeStream(response);
    return extractReadableText(html);
  } catch (e) {
    debugPrint('[UrlExtract] fetch failed: $e');
    return null;
  } finally {
    client.close();
  }
}

/// 从 HTML 提取 标题 + 可读文本。
String? extractReadableText(String html) {
  var title = '';
  final titleMatch =
      RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false).firstMatch(html);
  if (titleMatch != null) {
    title = decodeEntities(titleMatch.group(1) ?? '').trim();
  }
  var body = html
      .replaceAll(
          RegExp(r'<(script|style|head|noscript|svg|iframe)[^>]*>.*?</\1>',
              dotAll: true, caseSensitive: false),
          ' ')
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(
          RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  body = decodeEntities(body);
  body = body
      .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n')
      .trim();
  if (body.length > 20000) body = body.substring(0, 20000);
  if (body.isEmpty) return null;
  return title.isEmpty ? body : '# $title\n\n$body';
}

String decodeEntities(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");

// ---------- OG 元数据（rich-text-component.md §6.1 V2） ----------

/// Open Graph 页面元数据（og:title / og:image / og:description / og:site_name）。
class OgMeta {
  const OgMeta({this.title, this.image, this.description, this.siteName});

  final String? title;
  final String? image;
  final String? description;
  final String? siteName;

  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (image == null || image!.isEmpty) &&
      (description == null || description!.isEmpty) &&
      (siteName == null || siteName!.isEmpty);
}

/// 从 HTML 提取 OG 元数据；四种字段全缺返回 null。
///
/// 零依赖正则实现（与正文提取同口径）：`<meta>` 标签逐个扫描，
/// `property` 与 `name` 两种写法都认（部分站点用 name），属性顺序不限；
/// `og:url` 等无关键字忽略。
OgMeta? extractOgMetadata(String html) {
  final values = <String, String>{};
  final tagRe = RegExp(r'<meta\s+[^>]*>', caseSensitive: false);
  final propRe = RegExp(
    "(?:property|name)\\s*=\\s*[\"']og:([\\w:]+)[\"']",
    caseSensitive: false,
  );
  final contentRe =
      RegExp("content\\s*=\\s*[\"'](.*?)[\"']", dotAll: true, caseSensitive: false);
  for (final m in tagRe.allMatches(html)) {
    final tag = m.group(0)!;
    final prop = propRe.firstMatch(tag);
    if (prop == null) continue;
    final content = contentRe.firstMatch(tag)?.group(1);
    if (content == null || content.isEmpty) continue;
    final key = prop.group(1)!.toLowerCase();
    values.putIfAbsent(key, () => decodeEntities(content).trim());
  }
  String? pick(String key) {
    final v = values[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  final meta = OgMeta(
    title: pick('title'),
    image: pick('image'),
    description: pick('description'),
    siteName: pick('site_name'),
  );
  return meta.isEmpty ? null : meta;
}

/// OG 元数据 → machine_json（`og.v1` schema，rich-text-component.md §6.1 V2）。
/// 只保留非空字段；页面无任何 OG 标签返回 null（不写 machine_json）。
/// 空 required 集（validator 登记）：OG 字段常部分缺失，schema 只做形态校验。
Map<String, Object?>? ogMachineJson(String html) {
  final meta = extractOgMetadata(html);
  if (meta == null) return null;
  return {
    'schema': 'og.v1',
    if (meta.title != null) 'title': meta.title,
    if (meta.image != null) 'image': meta.image,
    if (meta.description != null) 'description': meta.description,
    if (meta.siteName != null) 'site': meta.siteName,
  };
}

/// machine_json → OG 元数据（渲染侧读取；schema 不符或缺失返回 null）。
OgMeta? ogFromMachineJson(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['schema'] != 'og.v1') return null;
  String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
  final meta = OgMeta(
    title: str(decoded['title']),
    image: str(decoded['image']),
    description: str(decoded['description']),
    siteName: str(decoded['site']),
  );
  return meta.isEmpty ? null : meta;
}
