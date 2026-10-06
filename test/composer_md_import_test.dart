import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';

/// 便签「导入 Markdown」弹框（2026-10-06 拍板）：
/// 用户在受控输入框里粘/写 md 片段 → seedQuickNote 解析 → 插入当前段光标处，
/// 编辑区**不带 `- `/`# ` 等 md 标记**，列表/待办由左侧凹槽渲染为 • / 勾选框。
void main() {
  Widget wrap() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: NoteComposerEditor(
              initialRows: const [
                ['t', '已有正文'],
              ],
            ),
          ),
        ),
      );

  /// 读编辑区首个文本段（对话框已关闭后，首个 EditableText 即当前文本段）。
  String editorText(WidgetTester t) =>
      t.widgetList<EditableText>(find.byType(EditableText)).first.controller.text;

  testWidgets('受控输入框导 md：列表/待办剥标记，凹槽出 • 与勾选框', (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();
    expect(editorText(t), '已有正文');

    await t.tap(find.byTooltip('导入 Markdown 片段'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await t.enterText(dialogField, '- 甲\n- [ ] 乙\n# 标题\n**粗**字');
    await t.pumpAndSettle();
    await t.tap(find.text('导入'));
    await t.pumpAndSettle();

    // 编辑区无 md 标记：列表前缀、# 前缀、** 全部剥掉，并入即无标记态
    final text = editorText(t);
    expect(text, contains('甲'));
    expect(text, contains('乙'));
    expect(text, contains('标题'));
    expect(text, contains('粗字'));
    expect(text, isNot(contains('- 甲')));
    expect(text, isNot(contains('# ')));
    expect(text, isNot(contains('**')));

    // 凹槽渲染：一个圆点（甲）+ 一个未勾选待办框（乙）
    expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsNothing);
  });

  testWidgets('点勾选框切完成态：凹槽图标随之翻转（不改正文）', (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('导入 Markdown 片段'));
    await t.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await t.enterText(dialogField, '- [ ] 待办项');
    await t.pumpAndSettle();
    await t.tap(find.text('导入'));
    await t.pumpAndSettle();

    final before = editorText(t);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);

    await t.tap(find.byIcon(Icons.check_box_outline_blank));
    await t.pumpAndSettle();

    // 正文不变，勾选态变通
    expect(editorText(t), before);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);
  });

  testWidgets('取消不落任何内容', (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();
    final before = editorText(t);

    await t.tap(find.byTooltip('导入 Markdown 片段'));
    await t.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await t.enterText(dialogField, '- 不该出现');
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();

    expect(editorText(t), before);
    expect(find.byIcon(Icons.fiber_manual_record), findsNothing);
  });
}
