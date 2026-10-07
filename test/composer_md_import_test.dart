import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';

/// 便签「导入 Markdown」弹框（2026-10-06 拍板）：
/// 用户在受控输入框里粘/写 md 片段 → seedTextTruth 解析 → 插入当前段光标处。
///
/// 文本真相口径（S3）：**线级标记（`- `/`# `/`- [ ] `）留在文本里**由显隐层
/// 收起，行内标记（`**`）剥除走 runs；列表/待办由左侧凹槽渲染为 • / 勾选框。
void main() {
  /// 空段起手：导入片段独占新行——文本真相下行身份由文本派生，片段若粘在
  /// 「已有正文」行末（`已有正文- 甲`）首行就不再是列表行（旧模型靠存储的
  /// run 掩盖了这一语义，派生视图不会）。
  Widget wrap() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: NoteComposerEditor(
              initialRows: const [
                ['t', ''],
              ],
            ),
          ),
        ),
      );

  /// 读编辑区首个文本段（对话框已关闭后，首个 EditableText 即当前文本段）。
  String editorText(WidgetTester t) =>
      t.widgetList<EditableText>(find.byType(EditableText)).first.controller.text;

  testWidgets('受控输入框导 md：线级标记留文本，行内标记剥除，凹槽出 • 与勾选框',
      (t) async {
    await t.pumpWidget(wrap());
    await t.pumpAndSettle();
    expect(editorText(t), isEmpty);

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

    // 文本真相：线级标记留文本（显隐层收起），行内标记剥除走 runs
    final text = editorText(t);
    expect(text, contains('甲'));
    expect(text, contains('乙'));
    expect(text, contains('标题'));
    expect(text, contains('粗字'));
    expect(text, contains('- 甲'));
    expect(text, contains('# 标题'));
    expect(text, isNot(contains('**')));

    // 凹槽渲染：一个圆点（甲）+ 一个未勾选待办框（乙）
    expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsNothing);
  });

  testWidgets('点勾选框切完成态：正文 [ ]→[x]，凹槽图标随翻转', (t) async {
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

    // 文本真相：勾选态本就在文本里，翻转 = 改写 [ ]↔[x] 字面
    expect(editorText(t), before.replaceFirst('[ ]', '[x]'));
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
