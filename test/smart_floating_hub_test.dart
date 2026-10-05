import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/smart_floating_hub.dart';

void main() {
  /// 挂载 300×400 边界内的悬浮球（位置经 notifier 回灌 Positioned）。
  Future<({ValueNotifier<Offset> pos, List<int> taps, List<int> drags})> pumpHub(
    WidgetTester tester, {
    Offset initial = Offset.zero,
  }) async {
    final pos = ValueNotifier(initial);
    final taps = <int>[];
    final drags = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // 组件自带 AnimatedPositioned 定位：必须直接挂 Stack，
              // 外层再包 Positioned 会造成 ParentData 竞争
              SmartFloatingHub(
                positionNotifier: pos,
                bounds: const Rect.fromLTWH(0, 0, 300, 400),
                onTap: () => taps.add(taps.length),
                onDragEnd: () => drags.add(drags.length),
                child: Container(width: 48, height: 48, color: const Color(0xFF888888)),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (pos: pos, taps: taps, drags: drags);
  }

  testWidgets('四缘吸附：拖到底部区松手 → 吸底缘，另一轴保持松手位', (tester) async {
    final (:pos, taps: _, drags: drags) = await pumpHub(tester);
    final gesture = await tester.startGesture(const Offset(24, 24));
    // 首段小位移被手势竞技场吞掉（slop 接手），交付位移从第二段起算
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 320));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // 球左上角 (120, 320)、球心 (144, 344)：距底 56 最近 → y 吸 400-48
    expect(pos.value, const Offset(120, 352));
    expect(drags, hasLength(1), reason: '松手回调恰好一次');
  });

  testWidgets('四缘吸附：拖到左侧区松手 → 吸左缘，纵轴保持', (tester) async {
    final (:pos, taps: _, drags: _) = await pumpHub(tester);
    final gesture = await tester.startGesture(const Offset(24, 24));
    await gesture.moveBy(const Offset(30, 30)); // arena 破 slop，被吞
    await tester.pump();
    await gesture.moveBy(const Offset(10, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // 球左上角 (10, 150)、球心 (34, 174)：距左 34 最近 → x 吸 0，y 保持
    expect(pos.value, const Offset(0, 150));
  });

  testWidgets('点按（未超 slop）不触发拖拽回调也不吸附', (tester) async {
    final (:pos, taps: taps, drags: drags) = await pumpHub(tester);
    await tester.tapAt(const Offset(24, 24));
    await tester.pumpAndSettle();
    expect(taps, hasLength(1), reason: 'onTap 正常抛出');
    expect(drags, isEmpty);
    expect(pos.value, Offset.zero, reason: '位置未被吸附移动');
  });
}
