import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/ui/block_editor_dialog.dart';

void main() {
  const parser = MarkdownSubsetParser();

  group('blockEditText ↔ rebuildBlock（块 ↔ 编辑文本映射）', () {
    /// 重建后与原块序列化等价（结构逐节点一致）。
    void expectRebuildStable(String md) {
      final original = parser.parse(md);
      for (final b in original) {
        final rebuilt = rebuildBlock(b, blockEditText(b), todoDone: switch (b) {
          ListBlock(items: [ListItem(done: true)]) => true,
          ListBlock(items: [ListItem(done: false)]) => false,
          _ => null,
        });
        expect(rebuilt, isNotNull, reason: '块不应被判空删除：$md');
        expect(serializeBlock(rebuilt!), serializeBlock(b),
            reason: '重建后序列化变化：$md\n原: ${serializeBlock(b)}\n新: ${serializeBlock(rebuilt)}');
      }
    }

    test('普通段落（无样式）', () => expectRebuildStable('第一段普通文本'));
    test('含行内样式的段落（粗/斜/码/链接）', () => expectRebuildStable('**粗** 与 *斜* 与 `码` 与 [官网](https://a.com)'));
    test('含字面语法标记的段落（转义保持字面）', () => expectRebuildStable(r'乘法 5\*3\*2=30 与 下划线 snake\_case'));
    test('标题（级别保留）', () => expectRebuildStable('## 二级标题 **粗**'));
    test('引用块（内部重解析）', () => expectRebuildStable('> 引用内容 **粗**'));
    test('代码块（语言与缩进保留）', () => expectRebuildStable('```dart\nvoid main() {}\n  indent\n```'));
    test('单项待办（勾选态保留）', () => expectRebuildStable('- [ ] 买牛奶'));
    test('单项普通列表', () => expectRebuildStable('- 普通项'));
    test('多项列表（标记往返）', () => expectRebuildStable('- 甲\n- [ ] 乙\n- [x] 丙'));
    test('有序列表', () => expectRebuildStable('1. 甲\n2. 乙'));
    test('分隔线', () => expectRebuildStable('前段\n\n---\n\n后段'));
    test('媒体块（alt/label 编辑往返，rich-text-media.md §4）', () {
      expectRebuildStable('![说明图](https://a.com/x.jpg)');
      expectRebuildStable('[备注语音](https://a.com/y.mp3)');
      expectRebuildStable('[演示视频](https://a.com/z.mp4)');
    });

    test('编辑文本改动反映到重建块', () {
      final p = parser.parse('原始段落').first;
      final rebuilt = rebuildBlock(p, '改过的段落') as ParagraphBlock;
      expect(inlineToPlain(rebuilt.inline), '改过的段落');
    });

    test('编辑为空白 → 返回 null（删除块）', () {
      final p = parser.parse('原始段落').first;
      expect(rebuildBlock(p, '   '), isNull);
    });

    test('媒体块编辑 alt/label：清空文本不删块（url 是内容本体）', () {
      final audio = parser.parse('[备注语音](https://a.com/y.mp3)').first;
      final renamed = rebuildBlock(audio, '会议录音') as AudioBlock;
      expect(renamed.label, '会议录音');
      expect(renamed.url, 'https://a.com/y.mp3');
      final cleared = rebuildBlock(audio, '') as AudioBlock;
      expect(cleared.url, 'https://a.com/y.mp3'); // 块不因 label 清空而删除
      final img = parser.parse('![说明图](https://a.com/x.jpg)').first;
      final alt = rebuildBlock(img, '新说明') as ImageBlock;
      expect(alt.alt, '新说明');
      expect(alt.url, 'https://a.com/x.jpg');
    });

    test('单项待办勾选态可切换', () {
      final todo = parser.parse('- [ ] 买牛奶').first;
      final done = rebuildBlock(todo, '买牛奶', todoDone: true) as ListBlock;
      expect(done.items.single.done, isTrue);
      // 序列化落 md 为 [x]
      expect(serializeBlock(done), '- [x] 买牛奶');
    });

    test('多项列表：用户删掉标记的行仍是列表项', () {
      final list = parser.parse('- 甲\n- 乙').first as ListBlock;
      final rebuilt = rebuildBlock(list, '甲改\n乙改') as ListBlock;
      expect(rebuilt.items, hasLength(2));
      expect(inlineToPlain(rebuilt.items[0].inline), '甲改');
      expect(inlineToPlain(rebuilt.items[1].inline), '乙改');
    });

    test('多项列表：出现待办标记归为无序且状态保留', () {
      final list = parser.parse('1. 甲\n2. 乙').first as ListBlock;
      final rebuilt = rebuildBlock(list, '- [ ] 待办') as ListBlock;
      expect(rebuilt.ordered, isFalse);
      expect(rebuilt.items.single.done, isFalse);
    });

    test('引用块编辑空 → null；含标记文本重解析', () {
      final q = parser.parse('> 引用').first;
      expect(rebuildBlock(q, ''), isNull);
      final rebuilt = rebuildBlock(q, '**粗** 引用') as QuoteBlock;
      final inner = rebuilt.children.single as ParagraphBlock;
      expect(inner.inline.first, isA<InlineStrong>());
    });
  });

  group('块编辑器 widget 行为', () {
    testWidgets('Tap-to-Edit：点段落激活编辑，保存回写 md', (tester) async {
      final changed = <String>[];
      Future<bool>? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => saved = showBlockEditorDialog(
                context,
                markdown: '第一段',
                onChanged: changed.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 阅读态：段落以文本呈现，点按激活为编辑态
      expect(find.text('第一段'), findsOneWidget);
      await tester.tap(find.text('第一段'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(3)); // 标题 + TL;DR + 激活块
      await tester.enterText(find.byType(TextField).last, '改过的段落');
      await tester.pump();

      // 保存（AppBar ✓）
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(await saved!, isTrue);
      expect(changed.last, contains('改过的段落'));
      expect(changed.last, isNot(contains('第一段')));
    });

    testWidgets('待办块：编辑态 Checkbox 可勾选，保存为 [x]', (tester) async {
      final changed = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showBlockEditorDialog(
                context,
                markdown: '- [ ] 买牛奶',
                onChanged: changed.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('买牛奶')); // 激活编辑态
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsOneWidget); // 待办块编辑态保留 Checkbox
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成')); // 失焦回写
      await tester.pumpAndSettle();
      expect(changed.last, contains('- [x] 买牛奶'));
    });

    testWidgets('上移/下移排序与删除块', (tester) async {
      final changed = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showBlockEditorDialog(
                context,
                markdown: '甲段\n\n乙段',
                onChanged: changed.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 激活「乙段」并上移
      await tester.tap(find.text('乙段'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pumpAndSettle();
      expect(changed.last, startsWith('乙段'));

      // 删除「乙段」（上移后回到阅读态，须重新激活才有操作行）
      await tester.tap(find.text('乙段'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(changed.last, '甲段');
    });

    testWidgets('添加块：新段落块获得焦点并可编辑', (tester) async {
      final changed = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showBlockEditorDialog(
                context,
                markdown: '已有段',
                onChanged: changed.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加块'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '新段落');
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(changed.last, contains('已有段'));
      expect(changed.last, contains('新段落'));
    });

    testWidgets('关闭（×）返回 false', (tester) async {
      Future<bool>? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => saved = showBlockEditorDialog(context, markdown: '段'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(await saved!, isFalse);
    });
  });

  group('粘贴多段拆块（单次变更插入 \\n\\n 才拆）', () {
    Future<void> openEditor(WidgetTester tester, String markdown, List<String> changed) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showBlockEditorDialog(context, markdown: markdown, onChanged: changed.add),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('粘贴多段文本拆成多块，激活尾块（光标在粘贴文本后）', (tester) async {
      final changed = <String>[];
      await openEditor(tester, '首段', changed);
      await tester.tap(find.text('首段'));
      await tester.pumpAndSettle();
      // 一次变更 = 一次粘贴：插入片段含 \n\n
      await tester.enterText(find.byType(TextField).last, '首段A\n\n中段\n\n尾段B');
      await tester.pumpAndSettle();

      // 首段并入当前块（阅读态），中段成新块，尾块保持激活（编辑态）
      expect(find.text('首段A'), findsOneWidget);
      expect(find.text('中段'), findsOneWidget);
      expect(find.text('尾段B'), findsOneWidget); // EditableText（激活尾块）
      expect(find.byType(TextField), findsNWidgets(3)); // 标题 + TL;DR + 尾块

      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(changed.last, '首段A\n\n中段\n\n尾段B');
    });

    testWidgets('粘贴在光标处且光标后有原文：原文归尾块，光标停在原文之前', (tester) async {
      final changed = <String>[];
      await openEditor(tester, '尾后文', changed);
      await tester.tap(find.text('尾后文'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'A\n\n尾后文');
      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget); // 当前块（阅读态）
      expect(find.text('尾后文'), findsOneWidget); // 尾块（编辑态）
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(changed.last, 'A\n\n尾后文');
    });

    testWidgets('手敲两次回车（逐事件单个 \\n）不拆块', (tester) async {
      final changed = <String>[];
      await openEditor(tester, '首段', changed);
      await tester.tap(find.text('首段'));
      await tester.pumpAndSettle();
      // 模拟逐键输入：每次事件只插入一个字符
      await tester.enterText(find.byType(TextField).last, 'a');
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'a\n');
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'a\n\n');
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'a\n\nb');
      await tester.pumpAndSettle();

      // 未拆块：仍只有一个激活块，文本完整保留，无阅读态新块
      expect(find.text('a\n\nb'), findsOneWidget);
      expect(find.text('b'), findsNothing);
    });

    testWidgets('粘贴内容全是空白段：块被清空，退出编辑态', (tester) async {
      final changed = <String>[];
      await openEditor(tester, '首段', changed);
      await tester.tap(find.text('首段'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '\n\n');
      await tester.pumpAndSettle();

      // 当前块清空删除、无尾块 → 退出编辑态，仅剩标题 + TL;DR 两个输入框
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      expect(changed.last, isEmpty);
    });
  });
}
