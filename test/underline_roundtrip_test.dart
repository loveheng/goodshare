import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/models/draft_store.dart';
import 'package:goodshare/share/note_composer.dart';
import 'package:goodshare/share/quick_note_span_codec.dart';
import 'package:goodshare/share/text_collector.dart';
import 'package:goodshare/ui/content_body.dart';
import 'package:goodshare/ui/format_dial.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:goodshare/ui/quick_note_bar.dart';

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
      final s = seedQuickNote(src);
      expect(s.plain, 'abc def');
      expect(s.runs.length, 1);
      expect(s.runs.single.mark, InlineMark.underline);
      expect(s.runs.single.start, 0);
      expect(s.runs.single.end, 3);
      expect(serializeQuickNoteSpans(s), src);
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

  group('速记转盘选 U → 打字 → 保存落库', () {
    testWidgets('落库 md 带 <u>，与编辑态所见一致', (tester) async {
      final repo = await _pumpShell(tester);
      await tester.tap(find.text('记点什么…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      // 打字退隐期 hub 是 IgnorePointer（P3-2 拍板）：先推进到恢复延时之后
      // 再点，否则点击被吞（不报错、面板不展开）
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tt'));
      await tester.pumpAndSettle();
      // 二级「行内」扇区（idx2 中角 -105°、中径 50）按住扇出三级
      final origin = tester.getRect(find.byType(FormatDial)).bottomRight -
          const Offset(kDialHubRadius, kDialHubRadius);
      final g = await tester.startGesture(origin + const Offset(-12.9, -48.3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await g.up();
      await tester.pumpAndSettle();
      // 三级 U 叶（idx2 中角 -108°、中径 100）
      await _dialDrag(tester, at: const Offset(-31, -95));
      await tester.pumpAndSettle();
      expect(find.text('U'), findsOneWidget, reason: '圆钮角标外显激活 U');
      await tester.enterText(find.byType(TextField), '重点');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      for (var i = 0; i < 30; i++) {
        if (find.text('已记下').evaluate().isNotEmpty) break;
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final items = await repo.list();
        expect(items.length, 1);
        expect(items.single.rawContent, '<u>重点</u>',
            reason: '落库必须是 <u> 标记 md（详情页据此渲染下划线）');
      });
    });
  });
}

/// 速记外壳（复刻 home_shell 的有界高度挂载，同 quick_note_bar_test 口径）。
Future<Repository> _pumpShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final repo = Repository();
  final handler = ItemActionHandler(repo);
  final collector = TextCollector(handler);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          ListView(children: const [Text('占位列表')]),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: QuickNoteBar(
              collector: collector,
              handler: handler,
              draftPersistencer: InMemoryDraftStore(),
            ),
          ),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return repo;
}

/// 转盘拖选手势（同 quick_note_bar_test.dialDrag）。
Future<void> _dialDrag(
  WidgetTester tester, {
  required Offset at,
}) async {
  final origin = tester.getRect(find.byType(FormatDial)).bottomRight -
      const Offset(kDialHubRadius, kDialHubRadius);
  final g = await tester.startGesture(origin + at);
  await tester.pump();
  await g.up();
  await tester.pump();
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
