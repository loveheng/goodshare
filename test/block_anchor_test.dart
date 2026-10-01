import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ai/capability.dart';
import 'package:goodshare/ui/block_capability_host.dart';

/// 块锚点注册表（detail-two-zone.md §5.1 四版：文本块撤销常驻 ✨，改由划词
/// 菜单触发）。入口脱离块本体后，菜单靠本表反查「选区落在哪块」——几何一旦
/// 判错，能力就作用到错误的块上，故用测试钉住。
void main() {
  Widget hostTree(
    BlockAnchorStore store,
    List<Widget> blocks, {
    Widget Function(BuildContext context, SelectableRegionState state)? menu,
  }) {
    return MaterialApp(
      home: BlockAnchorRegistry(
        store: store,
        child: Column(
          children: [
            if (menu == null)
              ...blocks
            else
              Builder(
                builder: (pageContext) => SelectionArea(
                  contextMenuBuilder: (_, state) => menu(pageContext, state),
                  child: Column(children: blocks),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget textBlock(String text, String anchorLabel) =>
      wrapWithCapabilityHost(Text(text), kind: BlockKind.text, anchorLabel: anchorLabel);

  testWidgets('锚点命中：选区落在哪块就作用哪块', (tester) async {
    final store = BlockAnchorStore();
    await tester.pumpWidget(
      hostTree(store, [
        textBlock('第一段', '文本块'),
        const SizedBox(height: 40),
        textBlock('第二段', '代码块'),
      ]),
    );

    final first = tester.getRect(find.text('第一段'));
    final second = tester.getRect(find.text('第二段'));

    expect(store.hitTest(first.center)?.anchorLabel, '文本块');
    expect(store.hitTest(second.center)?.anchorLabel, '代码块');
    // 块间空隙：取纵向最近的块（距上块 12dp < 距下块 28dp）
    expect(
      store.hitTest(Offset(first.center.dx, first.bottom + 12))?.anchorLabel,
      '文本块',
    );
    // 远离所有块（超出 48dp 容差）→ 未命中，菜单不追加死项
    expect(store.hitTest(Offset(first.center.dx, second.bottom + 200)), isNull);
  });

  testWidgets('宿主卸载即注销：滑出视口不留悬挂锚点', (tester) async {
    final store = BlockAnchorStore();
    await tester.pumpWidget(hostTree(store, [textBlock('段落', '文本块')]));

    expect(store.hitTest(tester.getRect(find.text('段落')).center), isNotNull);

    await tester.pumpWidget(
      hostTree(store, const [SizedBox(height: 40)]),
    );
    expect(store.hitTest(const Offset(10, 10)), isNull);
  });

  testWidgets('划词菜单追加「AI 处理本段」项', (tester) async {
    final store = BlockAnchorStore();
    await tester.pumpWidget(
      hostTree(
        store,
        [textBlock('可选择的正文内容', '文本块')],
        menu: (pageContext, state) =>
            buildBlockCapabilityMenu(pageContext, state),
      ),
    );

    await tester.longPress(find.text('可选择的正文内容'));
    await tester.pumpAndSettle();

    expect(find.text('AI 处理本段'), findsOneWidget);
  });
}
