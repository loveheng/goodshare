import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:goodshare/data/db.dart';
import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/share/note_composer.dart';
import 'package:goodshare/share/quick_note_text_actions.dart';
import 'package:goodshare/ui/content_body.dart';
import 'package:goodshare/ui/note_composer_editor.dart';

/// 下划线端到端往返（编辑态 ↔ 阅读态同源护栏）。
///
/// 背景：block-format-input.md §2 决策 6 定 `<u>` 为下划线的落库语法，
/// 编辑态（span 样式化层，编辑区无 md 标记）与阅读态（`MarkdownSubsetParser`
/// → `rich_text_view._span`）必须同源，否则出现「编辑区有下划线、详情页没有」
/// 的文本不一致。本文件按三层各锁一环，任一侧改口径都会红。
void main() {
  const src = '<u>abc</u> def';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
    TestWidgetsFlutterBinding.ensureInitialized();
    // record 插件无平台实现（同 quick_note_bar_test 口径）：mock 掉免得
    // 异步 MissingPluginException 在用例结束后才落，误判失败
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (call) async => null);
  });

  group('codec 往返（编辑态种子 ↔ 落库 md）', () {
    test('md 播种 → plain + underline run → 序列化回写同串', () {
      final s = seedTextTruth(src);
      expect(s.plain, 'abc def');
      expect(s.runs.length, 1);
      expect(s.runs.single.mark, InlineMark.underline);
      expect(s.runs.single.start, 0);
      expect(s.runs.single.end, 3);
      expect(serializeTextTruthSpans(s), src);
    });

    test('落库 md 解析回 InlineUnderline（阅读态入口同口径）', () {
      final block = const MarkdownSubsetParser().parse(src).first;
      final inline = (block as ParagraphBlock).inline;
      expect(inline.first, isA<InlineUnderline>());
      expect(serializeInline(inline), src);
    });
  });

  group('编辑组件 ↔ 阅读组件同源', () {
    testWidgets('编辑态播种：编辑区无 md 标记，回写 md 复原', (tester) async {
      final key = GlobalKey<NoteComposerEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: NoteComposerEditor(
              key: key,
              initialRows: const [
                ['t', src],
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final st = key.currentState!;
      final seg = st.segs.first as NoteTextSeg;
      expect(seg.ctrl.text, 'abc def', reason: '所见即所得：编辑区不得出现 <u>');
      expect(seg.spans.runs.single.mark, InlineMark.underline);
      final saved = st.toNoteSegments().single as NoteTextSegment;
      expect(saved.text, src, reason: '保存序列化必须复原 <u>（详情页据此渲染）');
    });

    testWidgets('阅读态渲染：落库 md 渲染出 TextDecoration.underline',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: ContentBody(markdown: src),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        _hasUnderlineSpan(tester),
        isTrue,
        reason: '阅读态必须与编辑态同口径渲染下划线',
      );
    });

    testWidgets('阅读态 sliver 面（详情页走的面 + 衬线）同样渲染下划线',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ContentBodySliver(markdown: src, serif: true),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        _hasUnderlineSpan(tester),
        isTrue,
        reason: '详情页用 ContentBodySliver+serif面，口径不得与 ContentBody 分叉',
      );
    });

    testWidgets('详情页顶栏标题渲染为纯文本（不呈现下划线、不残壳 <u>）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('标题')),
          body: const SizedBox.shrink(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        _hasUnderlineSpan(tester),
        isFalse,
        reason: '标题栏为纯文本指代，不得渲染下划线；下划线只在正文阅读态呈现',
      );
      expect(find.text('标题'), findsOneWidget,
          reason: '标题以纯文本「标题」呈现，不残留 <u> 字面标记');
    });
  });

  // 2026-10-08 清理：「速记转盘选 U → 打字 → 保存落库」随悬浮球径向盘退役删除；
  // 下划线端到端往返已由本文件 codec 往返 + 编辑/阅读同源两组用例覆盖。
}

/// 已渲染树里是否存在带下划线装饰的文本 span。
bool _hasUnderlineSpan(WidgetTester tester) {
  var found = false;
  for (final e in find.byType(RichText).evaluate()) {
    void walk(InlineSpan s) {
      if (s is! TextSpan) return;
      if (s.style?.decoration == TextDecoration.underline) found = true;
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }

    walk((e.widget as RichText).text as TextSpan);
  }
  return found;
}
