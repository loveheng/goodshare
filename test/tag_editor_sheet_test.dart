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
  testWidgets('保存时未提交的输入直接收为标签（打字→保存必须产出标签）', (tester) async {
    final store = InMemoryDraftStore();
    List<String>? result;
    await _open(tester, store, (r) => result = r);

    await tester.enterText(find.byType(TextField), 'mytag');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, ['mytag']); // 直接收为标签
    expect(await store.load(_id), isEmpty); // 已落标签，草稿清空
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

  testWidgets('保存时未提交输入收为标签，重新打开无残留草稿', (tester) async {
    final store = InMemoryDraftStore();
    List<String>? r1;
    await _open(tester, store, (r) => r1 = r);
    await tester.enterText(find.byType(TextField), 'drafted');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(r1, contains('drafted')); // 保存即收为标签

    // 第二次打开：输入框为空（草稿已清）
    await _open(tester, store, (_) {});
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.controller?.text, isEmpty);
  });

  testWidgets('取消仍留草稿，重新打开预填', (tester) async {
    final store = InMemoryDraftStore();
    List<String>? r1;
    await _open(tester, store, (r) => r1 = r);
    await tester.enterText(find.byType(TextField), 'drafted');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(r1, isNull); // 取消不回传

    // 第二次打开：草稿应预填进输入框
    await _open(tester, store, (_) {});
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.controller?.text, 'drafted');
  });
}
