import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// URL 抓取与正文提取（2026-09-27 决策：链接离线成内容，设置开关控制）。
/// 零依赖实现：拉取 HTML → 去脚本/样式 → 剥标签 → 实体解码 → 压缩空白。
/// 已知限制：非 UTF-8（GBK）站点按 UTF-8 解码会乱码（后续可引入编码探测）；
/// 复杂网页的可读性抽取（readability 级）为后续打磨项。

String? firstUrl(String raw) {
  final match = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(raw);
  return match?.group(0);
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
