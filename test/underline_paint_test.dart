import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/ui/content_body.dart';

/// 下划线「装饰到叶」契约测试（宿主可验证的唯一形式）。
///
/// 背景（2026-10-04 真机实证）：flutter_tester 宿主**不光栅化 decoration**
/// （10 倍粗下划线像素 diff 仍为 0，见 underline_probe2 实验），任何像素级
/// 验证在宿主都是盲区；真机（CPH2767/Android 16）上 decoration 挂父 span
/// 不落笔、挂叶 span 才画线。故本测试锁**树结构契约**：
/// ContentBody 渲染 `<u>…</u>` 时，携带文字的叶 TextSpan 必须直接持有
/// TextDecoration.underline（与编辑态 span_text_controller 同构）。
void main() {
  testWidgets('<u> 渲染：装饰必须下发到叶 TextSpan', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const Scaffold(
        body: ContentBody(markdown: '渲染实验<u>ABC123</u>结束'),
      ),
    ));
    await tester.pumpAndSettle();

    final leaves = <TextSpan>[];
    for (final e in find.byType(RichText).evaluate()) {
      void walk(InlineSpan s) {
        if (s is! TextSpan) return;
        if (s.text != null) leaves.add(s); // 携带文字的叶
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }

      walk((e.widget as RichText).text as TextSpan);
    }

    final abc = leaves.where((s) => s.text == 'ABC123').toList();
    expect(abc, isNotEmpty, reason: '必须存在携带 ABC123 的叶 span');
    for (final s in abc) {
      expect(
        s.style?.decoration,
        TextDecoration.underline,
        reason: 'decoration 挂父 span 在真机不落笔（2026-10-04 实证）——'
            '携带文字的叶 span 必须直接持有装饰（与编辑态同构）',
      );
    }
    // 纯文叶不得被染下划线（theme 基样式自带 decoration:none，故只禁 underline）
    for (final s in leaves.where((s) => s.text != 'ABC123')) {
      expect(s.style?.decoration, isNot(TextDecoration.underline),
          reason: '装饰只许落在下划线段，不许外溢到普通文字');
    }
  });

  testWidgets('删除线同契约：~~…~~ 装饰下发到叶', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const Scaffold(
        body: ContentBody(markdown: '前段~~被删段落~~后段'),
      ),
    ));
    await tester.pumpAndSettle();

    final leaves = <TextSpan>[];
    for (final e in find.byType(RichText).evaluate()) {
      void walk(InlineSpan s) {
        if (s is! TextSpan) return;
        if (s.text != null) leaves.add(s);
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }

      walk((e.widget as RichText).text as TextSpan);
    }
    final hit = leaves.where((s) => s.text == '被删段落').toList();
    expect(hit, isNotEmpty);
    expect(hit.single.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('解析契约：<u> 落 InlineUnderline 且 serialize 幂等', (tester) async {
    const src = '渲染实验<u>ABC123</u>结束';
    final block = const MarkdownSubsetParser().parse(src).first;
    final inline = (block as ParagraphBlock).inline;
    expect(inline.whereType<InlineUnderline>(), isNotEmpty);
    expect(serializeInline(inline), src);
  });
}
