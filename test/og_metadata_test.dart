import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/machine_json_validator.dart';
import 'package:goodshare/ai/url_extract.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/ui/item_view_template.dart';

/// V2 OG 元数据富化（rich-text-component.md §6.1）：url 条目复用 fetchHtml
/// 产物解析 og:*，落 machine_json（og.v1），详情页渲染 OG 卡片。
void main() {
  group('extractOgMetadata（HTML 解析）', () {
    test('标准 property 写法四字段', () {
      const html = '''
        <html><head>
        <meta property="og:title" content="页面标题">
        <meta property="og:image" content="https://a.com/cover.jpg">
        <meta property="og:description" content="页面描述">
        <meta property="og:site_name" content="示例站">
        </head></html>''';
      final meta = extractOgMetadata(html);
      expect(meta!.title, '页面标题');
      expect(meta.image, 'https://a.com/cover.jpg');
      expect(meta.description, '页面描述');
      expect(meta.siteName, '示例站');
    });

    test('name 写法与属性倒序', () {
      const html = '''
        <meta content="倒序标题" property="og:title">
        <meta NAME="og:site_name" content="倒序站">''';
      final meta = extractOgMetadata(html);
      expect(meta!.title, '倒序标题');
      expect(meta.siteName, '倒序站');
    });

    test('实体解码与首标签优先（重复 og:title）', () {
      const html = '''
        <meta property="og:title" content="A &amp; B">
        <meta property="og:title" content="后出现的">''';
      expect(extractOgMetadata(html)!.title, 'A & B');
    });

    test('og:url 等无关键字忽略；全缺返回 null', () {
      expect(extractOgMetadata('<meta property="og:url" content="https://a.com">'), isNull);
      expect(extractOgMetadata('<html><body>正文</body></html>'), isNull);
    });
  });

  group('ogMachineJson ↔ ogFromMachineJson（machine_json og.v1）', () {
    test('全字段组装且通过 schema 强校验', () {
      final json = ogMachineJson(
          '<meta property="og:title" content="T"><meta property="og:image" content="I">'
          '<meta property="og:description" content="D"><meta property="og:site_name" content="S">')!;
      expect(json['schema'], 'og.v1');
      expect(validateMachineJson(jsonEncode(json)), isNull, reason: 'og.v1 须登记进 validator');
    });

    test('部分字段缺失仍产出（og.v1 空 required 集）', () {
      final json = ogMachineJson('<meta property="og:description" content="只有描述">')!;
      expect(json.containsKey('title'), isFalse);
      expect(json['description'], '只有描述');
    });

    test('无 OG 标签返回 null（不写 machine_json）', () {
      expect(ogMachineJson('<html><body>plain</body></html>'), isNull);
    });

    test('渲染侧读取往返；坏 JSON / 非本 schema 返回 null', () {
      final json = ogMachineJson('<meta property="og:title" content="T">')!;
      final meta = ogFromMachineJson(jsonEncode(json));
      expect(meta!.title, 'T');
      expect(ogFromMachineJson('not json'), isNull);
      expect(ogFromMachineJson(jsonEncode({'schema': 'invoice.v1', 'amount': 1})), isNull);
      expect(ogFromMachineJson(null), isNull);
    });
  });

  group('详情页 OG 卡片渲染', () {
    final item = InboxItem(
      id: 'u1',
      itemType: InboxItem.typeUrl,
      rawContent: 'https://a.com/article',
      humanMd: '# 正文标题\n\n正文段落',
      machineJson: jsonEncode({
        'schema': 'og.v1',
        'title': 'OG 标题',
        'description': 'OG 描述文本',
        'site': '某站点',
      }),
      createdAt: 1,
    );

    testWidgets('OG 卡片显示站点/标题/描述，正文照常渲染', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 600, child: ItemViewTemplate(item: item)),
        ),
      ));
      await tester.pump();
      expect(find.text('某站点'), findsOneWidget);
      expect(find.text('OG 标题'), findsOneWidget);
      expect(find.text('OG 描述文本'), findsOneWidget);
      expect(find.text('正文标题'), findsOneWidget);
    });

    testWidgets('无 OG 元数据的 url 条目不出现卡片', (tester) async {
      final plain = InboxItem(
        id: 'u2',
        itemType: InboxItem.typeUrl,
        rawContent: 'https://a.com/x',
        humanMd: '正文',
        createdAt: 1,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 600, child: ItemViewTemplate(item: plain)),
        ),
      ));
      await tester.pump();
      expect(find.text('OG 标题'), findsNothing);
      expect(find.text('正文'), findsOneWidget);
    });
  });

  group('firstUrl（尾部括号剥离）', () {
    test('markdown 链接后随正文：结尾 ) 不吃进 URL', () {
      expect(firstUrl('图 ![a](https://x.com/i.png)'), 'https://x.com/i.png');
      expect(firstUrl('看这个 [链接](https://a.com/b?q=1) 很棒'), 'https://a.com/b?q=1');
    });
    test('配对括号的合法 URL 保留', () {
      expect(firstUrl('见 https://en.wikipedia.org/wiki/Comma_(punctuation) 条目'),
          'https://en.wikipedia.org/wiki/Comma_(punctuation)');
    });
    test('裸 URL 不受影响', () {
      expect(firstUrl('去 https://a.com/x.png 看看'), 'https://a.com/x.png');
    });
  });
}

