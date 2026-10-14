import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rich_text/markdown_subset.dart';

import 'package:goodshare/ui/math_widget.dart';
import 'package:goodshare/ui/rich_text_view.dart';

/// 数学渲染闭环冒烟：解析层（package:rich_text）已产 InlineMath/MathBlock，
/// 本件验证 goodshare 渲染层把它们落成可见公式、且非法源码降级不崩。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: child),
      );

  group('解析产物', () {
    test('行内 \$…\$ 解析为 InlineMath', () {
      final blocks = const MarkdownSubsetParser().parse(r'质能方程 $E=mc^2$ 成立');
      final para = blocks.whereType<ParagraphBlock>().single;
      expect(para.inline.whereType<InlineMath>().single.source, 'E=mc^2');
    });

    test('块级 \$\$…\$\$ 解析为 MathBlock', () {
      final blocks = const MarkdownSubsetParser().parse(r'$$\frac a b$$');
      expect(blocks.whereType<MathBlock>().single.source, r'\frac a b');
    });
  });

  group('阅读态渲染闭环', () {
    testWidgets('RichTextView 渲染行内数学不抛异常且含 Math 控件', (tester) async {
      await tester.pumpWidget(
        host(RichTextView(markdown: r'质能方程 $E=mc^2$ 成立')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsWidgets);
    });

    testWidgets('RichTextView 渲染块级数学不抛异常且含 Math 控件', (tester) async {
      await tester.pumpWidget(
        host(RichTextView(markdown: r'$$\sum_{i=1}^n i = \frac{n(n+1)}2$$')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Math), findsWidgets);
    });

    testWidgets('非法 LaTeX 降级为源码文本、不抛异常', (tester) async {
      await tester.pumpWidget(
        host(RichTextView(markdown: r'坏公式 $\frac$')),
      );
      await tester.pumpAndSettle();
      // 降级路径：显示源码文本（不丢内容、零崩溃），不再渲染公式字形。
      expect(find.text(r'\frac'), findsWidgets);
    });

    testWidgets('math_widget 直接渲染（块级）含横向滚动容器与 Math', (tester) async {
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => mathBlockView(
              r'\int_0^1 x^2\,dx',
              const TextStyle(),
              scheme: Theme.of(context).colorScheme,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(find.byType(Math), findsWidgets);
    });
  });
}
