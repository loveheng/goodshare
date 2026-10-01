import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/pages/workspace_create_page.dart';

void main() {
  late ValueGetter<String?> resultGetter;

  Future<void> open(WidgetTester tester) async {
    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  popped = await Navigator.push<String>(
                    ctx,
                    MaterialPageRoute(
                        builder: (_) => const WorkspaceCreatePage()),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    // 闭包回传通道：后续用例经 resultGetter 读取
    resultGetter = () => popped;
  }


  testWidgets('空名称：创建钮不可用（承诺门）', (tester) async {
    await open(tester);
    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '创建'),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('输入名称点创建：pop 回去空格后的名称', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '  灵感集  ');
    await tester.pumpAndSettle();
    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '创建'),
    );
    expect(btn.onPressed, isNotNull);
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(resultGetter(), '灵感集');
  });
}
