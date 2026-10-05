import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ai/capability.dart';
import 'package:goodshare/ai/capability_chain.dart';
import 'package:goodshare/ui/block_capability_page.dart';

/// 三级能力页预览限高 + 激活（2026-10-04 真机取证修复）：
/// 预览原块全尺寸渲染时竖图/截图把链式工作台与独立能力顶出首屏，
/// 能力页首屏只剩一张图——「查看区 + 操作区」必须一屏同现。
void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    // 手机级视口（默认 800×600 测试面对竖图场景过宽，按真机口径验证）
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: BlockCapabilityPage(
          kind: BlockKind.image,
          chain: CapabilityChain(capabilitiesFor(BlockKind.image))..init(),
          anchorLabel: '图片条目',
          // 竖版截图比例（宽:高 ≈ 0.45），未限高时渲染高度远超视口。
          preview: const AspectRatio(
            aspectRatio: 0.45,
            child: ColoredBox(color: Colors.blue),
          ),
          onPreviewActivate: () {},
          onRunStep: (_) async => null,
          onReset: () async {},
          onEditOutput: (_) async => null,
          onApply: (_, _) async {},
          onRunStandalone: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('首屏同现：预览限高，链式卡与独立能力不被顶出视口', (tester) async {
    await pumpPage(tester);

    final viewH = tester.view.physicalSize.height /
        tester.view.devicePixelRatio;
    final previewH = tester
        .getRect(find.byType(AspectRatio).first)
        .height;
    // 预览被钳到限高内（padding 上沿 12 + 限高 280）
    expect(previewH, lessThanOrEqualTo(kPreviewMaxHeight));

    // 操作区不滚动即可见：链首步骤 + 独立能力区标题都在首屏视口内
    final ocr = tester.getRect(find.text('识别文字'));
    expect(ocr.top, lessThan(viewH), reason: '链式工作台首屏可见');
    final standalone = tester.getRect(find.text('独立能力'));
    expect(standalone.top, lessThan(viewH), reason: '独立能力区首屏可见');
  });

  testWidgets('预览点按激活（全屏查看出口接通）', (tester) async {
    var activated = false;
    await tester.pumpWidget(
      MaterialApp(
        home: BlockCapabilityPage(
          kind: BlockKind.image,
          chain: CapabilityChain(capabilitiesFor(BlockKind.image))..init(),
          preview: const ColoredBox(
            color: Colors.red,
            key: Key('pv'),
            child: SizedBox(height: 100, width: 100),
          ),
          onPreviewActivate: () => activated = true,
          onRunStep: (_) async => null,
          onReset: () async {},
          onEditOutput: (_) async => null,
          onApply: (_, _) async {},
          onRunStandalone: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pv')));
    expect(activated, isTrue);
  });
}
