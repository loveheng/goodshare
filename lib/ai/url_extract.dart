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

/// 拉取网页并提取可读文本；失败返回 null（调用方回退占位行为）。
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
    title = _decodeEntities(titleMatch.group(1) ?? '').trim();
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
  body = _decodeEntities(body);
  body = body
      .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n')
      .trim();
  if (body.length > 20000) body = body.substring(0, 20000);
  if (body.isEmpty) return null;
  return title.isEmpty ? body : '# $title\n\n$body';
}

String _decodeEntities(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");
