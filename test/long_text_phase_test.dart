import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/plain_to_md.dart';
import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/ui/content_body.dart';
import 'package:goodshare/ui/rich_text_view.dart';

/// 超长文本方案 Phase 0（全量存储不截断）+ Phase 1（虚拟化渲染）专项验证。
///
/// Phase 0：归一化阈值放开到 1<<26，数万字不应再被截断。
/// Phase 1：详情页把正文 block 并入 `SliverList`，只构建可视区 widget。
/// Phase 3：解析超阈值转后台 isolate（见 [phase3Groups]）。
void main() {
  phase3Groups();
  group('超长文本 Phase 0：归一化不截断', () {
    test('5 万字 Markdown 直通不被截断', () {
      final sb = StringBuffer();
      for (var i = 0; i < 500; i++) {
        sb.writeln('# 章节 $i');
        sb.writeln('这是第 $i 段正文，包含若干内容用于撑长文本。' * 20);
      }
      final long = sb.toString();
      expect(long.length, greaterThan(20000));

      final doc = markdownPassthrough(long);
      expect(doc.meta.truncated, isFalse, reason: '阈值放开后不应截断');
      // 直通做空白规整（含首尾 trim），长度应接近原文且不丢内容。
      expect(doc.markdown.length, greaterThan(20000));
      expect(doc.markdown, contains('# 章节 0'));
      expect(doc.markdown, contains('# 章节 499'));
    });

    test('5 万字纯文本分段后不截断', () {
      final sb = StringBuffer();
      for (var i = 0; i < 500; i++) {
        sb.writeln('第 $i 段纯文本内容。' * 20);
        sb.writeln(); // 空行分段
      }
      final long = sb.toString();

      final doc = plainToMarkdown(long);
      expect(doc.meta.truncated, isFalse);
      expect(doc.markdown.length, greaterThan(20000));
    });

    test('显式小 maxChars 仍按预期截断（门控保留，仅阈值放开）', () {
      final long = 'x' * 50000;
      final doc = markdownPassthrough(long, maxChars: 20000);
      expect(doc.meta.truncated, isTrue);
      expect(doc.markdown.length, equals(20000));
    });
  });

  group('超长文本 Phase 1：渲染虚拟化', () {
    test('richBlocksOf 对长文产出大量块', () {
      final blocks = richBlocksOf(_hugeMarkdown());
      expect(blocks.length, greaterThan(500));
    });

    testWidgets('SliverList 只构建可视区 block（虚拟化生效）', (tester) async {
      final blocks = richBlocksOf(_hugeMarkdown());
      var built = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (c, i) {
                  built++;
                  return buildRichBlock(c, blocks[i]);
                },
                childCount: blocks.length,
              ),
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      // 虚拟化：可视区远小于总块数（几千块只实例化几十个）。
      expect(built, lessThan(blocks.length));
      expect(built, lessThan(200));
    });
  });
}

/// 约 6 万字符、含标题/段落/列表/引用/代码块的多形态长文。
String _hugeMarkdown() {
  final sb = StringBuffer();
  for (var i = 0; i < 400; i++) {
    sb.writeln('# 章节 $i');
    sb.writeln('');
    sb.writeln('这是第 $i 段的主体内容，用于撑长文本并验证虚拟化渲染不会一次性构建全部 widget。' * 10);
    sb.writeln('');
    if (i % 5 == 0) {
      sb.writeln('- 列表项 A$i');
      sb.writeln('- 列表项 B$i');
      sb.writeln('');
    }
    if (i % 7 == 0) {
      sb.writeln('> 引用内容 $i，说明某些观点。');
      sb.writeln('');
    }
    if (i % 11 == 0) {
      sb.writeln('```');
      sb.writeln('code line $i');
      sb.writeln('```');
      sb.writeln('');
    }
  }
  return sb.toString();
}

/// 超长文本 Phase 3：解析 Isolate 化。
///
/// 超过 [kRichParseIsolateThreshold]（8k 字符）的解析转后台 isolate（`compute`），
/// 打开长文不再阻塞 UI 帧；块树为纯 Dart 对象图，跨 isolate 结果与同步一致。
void phase3Groups() {
  group('超长文本 Phase 3：Isolate 异步解析', () {
    test('短文同步路径与 sync parse 逐块一致', () async {
      const md = '# 标题\n\n段落 **加粗** 与 `code`。\n\n- 甲\n- [ ] 乙';
      final sync = richBlocksOf(md);
      final async = await richBlocksOfAsync(md);
      expect(async.length, equals(sync.length));
      for (var i = 0; i < sync.length; i++) {
        expect(async[i].toString(), equals(sync[i].toString()));
      }
    });

    test('长文（超阈值）走 isolate，结果与 sync parse 一致', () async {
      final md = _hugeMarkdown();
      expect(md.length, greaterThan(kRichParseIsolateThreshold));
      final sync = richBlocksOf(md);
      final async = await richBlocksOfAsync(md);
      expect(async.length, equals(sync.length));
      expect(async.length, greaterThan(500));
      for (var i = 0; i < sync.length; i++) {
        expect(async[i].toString(), equals(sync[i].toString()));
      }
    });

    test('自定义解析器不转 isolate（保持同步语义）', () async {
      final md = 'x' * (kRichParseIsolateThreshold + 1);
      final parser = _UpperCasePassthroughParser();
      final blocks = await richBlocksOfAsync(md, parser);
      expect(blocks.length, equals(1));
      final plain = inlineToPlain((blocks[0] as ParagraphBlock).inline);
      expect(plain, contains('X'));
    });

    testWidgets('RichTextView 长文异步回填后渲染', (tester) async {
      // compute 是真 isolate 事件，须在 runAsync 里跑真实事件循环
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: RichTextView(markdown: _hugeMarkdown())),
        ));
        // 长文 isolate 在途：首帧渲染空占位，不阻塞首帧
        expect(find.textContaining('章节'), findsNothing);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      });
      expect(find.textContaining('章节 0'), findsOneWidget);
    });

    testWidgets('ContentBodySliver 长文异步回填后仍是 SliverList 虚拟化', (tester) async {
      const emptyMarker = Key('empty-fallback');
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CustomScrollView(slivers: [
              ContentBodySliver(
                key: const Key('body'),
                markdown: _hugeMarkdown(),
                emptyView: const SizedBox(key: emptyMarker),
              ),
            ]),
          ),
        ));
        expect(find.byKey(emptyMarker), findsNothing); // 非空 body 不走空态
        // 回填等待用轮询而非固定延迟：套件并发高负载下 isolate 解析 +
        // 200ms 不够（2026-10-05 修时序脆弱，单跑必过/全量偶挂）
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump();
          if (find.textContaining('章节 0').evaluate().isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await tester.pump();
      });
      expect(find.textContaining('章节 0'), findsOneWidget);
      // 虚拟化不回退：可视区外章节 399 不构建，且仍是真 Sliver
      expect(find.textContaining('章节 399'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is SliverList), findsOneWidget);
    });

    testWidgets('ContentBodySliver 空 body 走 emptyView 兜底', (tester) async {
      const emptyMarker = Key('empty-fallback');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [
            ContentBodySliver(
              markdown: '   \n  ',
              emptyView: const Text('空', key: emptyMarker),
            ),
          ]),
        ),
      ));
      await tester.pump();
      expect(find.byKey(emptyMarker), findsOneWidget);
    });
  });
}

/// 最小自定义解析器（验证注入时绕开 isolate 的分支）。
class _UpperCasePassthroughParser implements RichTextParser {
  @override
  List<RichBlock> parse(String markdown) =>
      [ParagraphBlock([InlineText(markdown.toUpperCase())])];

  @override
  List<InlineNode> parseInline(String text) => [InlineText(text.toUpperCase())];
}
