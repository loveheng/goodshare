import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/models/draft_store.dart';
import 'package:goodshare/ui/tag_editor_sheet.dart';

const _id = 'tag_editor';

Future<void> _open(
  WidgetTester tester,
  DraftPersistencer store,
  void Function(List<String>?) capture,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              capture(await showTagEditor(
                context,
                initial: const [],
                persistencer: store,
              ));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未回车的输入留作草稿，不直接成标签', (tester) async {
    final store = InMemoryDraftStore();
    List<String>? result;
    await _open(tester, store, (r) => result = r);

    await tester.enterText(find.byType(TextField), 'mytag');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, isNot(contains('mytag'))); // 未提交，不实装
    expect(await store.load(_id), 'mytag'); // 留作草稿
  });

  testWidgets('回车提交后成标签，且草稿清空', (tester) async {
    final store = InMemoryDraftStore();
    List<String>? result;
    await _open(tester, store, (r) => result = r);

    await tester.enterText(find.byType(TextField), 'mytag');
    await tester.testTextInput.receiveAction(TextInputAction.done); // 回车成 chip
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, ['mytag']); // 已提交
    expect(await store.load(_id), isEmpty); // 草稿清空
  });

  testWidgets('取消也保留草稿', (tester) async {
    final store = InMemoryDraftStore();
    await _open(tester, store, (_) {});

    await tester.enterText(find.byType(TextField), 'drafted');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await store.load(_id), 'drafted');
  });

  testWidgets('重新打开草稿仍在输入框', (tester) async {
    final store = InMemoryDraftStore();
    List<String>? r1;
    await _open(tester, store, (r) => r1 = r);
    await tester.enterText(find.byType(TextField), 'drafted');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(r1, isNot(contains('drafted')));

    // 第二次打开：草稿应预填进输入框
    await _open(tester, store, (_) {});
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.controller?.text, 'drafted');
  });
}
