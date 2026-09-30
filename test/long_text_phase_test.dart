import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/plain_to_md.dart';
import 'package:goodshare/ui/rich_text_view.dart';

/// 超长文本方案 Phase 0（全量存储不截断）+ Phase 1（虚拟化渲染）专项验证。
///
/// Phase 0：归一化阈值放开到 1<<26，数万字不应再被截断。
/// Phase 1：详情页把正文 block 并入 `SliverList`，只构建可视区 widget。
void main() {
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
