import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/rotary_dial.dart';

void main() {
  group('rotaryProgressFromAngle 纯函数（135° 起、270° 弧、缺口朝下）', () {
    final start = 3 * math.pi / 4; // 135°
    final sweep = 3 * math.pi / 2; // 270°

    double p(double deg) => rotaryProgressFromAngle(
      deg * math.pi / 180,
      startAngle: start,
      sweepAngle: sweep,
    );

    test('弧内线性映射（135°→0、顶部 270°→0.5、45°→1）', () {
      expect(p(135), 0);
      expect(p(180), closeTo(0.1667, 1e-3));
      expect(p(270), closeTo(0.5, 1e-9));
      expect(p(360), closeTo(0.8333, 1e-3));
      expect(p(45), 1, reason: '45° = 405°-360°，弧末端');
      expect(p(44), closeTo(0.9963, 1e-3));
    });

    test('缺口区回就近端（end 侧半缺口=1，start 侧半缺口=0）', () {
      // 缺口 = 45°~135°（朝下），中线 90°
      expect(p(80), 1, reason: '80° 距末端近（g=35° < 45°）');
      expect(p(100), 0, reason: '100° 距始端近（g=55° > 45°）');
    });

    test('任意配置：sweep=2π 全圆无缺口', () {
      double p2(double deg) => rotaryProgressFromAngle(
        deg * math.pi / 180,
        startAngle: 0,
        sweepAngle: 2 * math.pi,
      );
      expect(p2(0), 0);
      expect(p2(90), closeTo(0.25, 1e-9));
      expect(p2(359), closeTo(0.9972, 1e-3));
    });
  });

  group('RotaryDial widget', () {
    Widget host({
      required Widget child,
    }) => MaterialApp(home: Scaffold(body: Center(child: child)));

    /// 环带中径上某角度的点（y-down atan2 系）。
    Offset atDeg(Offset center, double deg, {double? r}) {
      final band = (kRotaryRadius - kRotaryRingWidth / 2);
      return Offset(
        center.dx + (r ?? band) * math.cos(deg * math.pi / 180),
        center.dy + (r ?? band) * math.sin(deg * math.pi / 180),
      );
    }

    Future<void> dragTo(WidgetTester tester, Offset from, Offset to) async {
      final g = await tester.startGesture(from);
      await tester.pump();
      await g.moveBy(to - from);
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    testWidgets('有级：中心显示名称与当前档位，档位标签在环上', (tester) async {
      await tester.pumpWidget(
        host(
          child: RotaryDial(
            title: '模式',
            items: const [RotaryItem('A'), RotaryItem('B'), RotaryItem('C')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('模式'), findsOneWidget, reason: '中心名称');
      // 初始档 0：中心值 = 段 0 标签（与环上标签同文本，共 2 处）
      expect(find.text('A'), findsNWidgets(2));
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets('有级：拖到中上部档位 → onIndexChanged 实时回调', (tester) async {
      final idxs = <int>[];
      await tester.pumpWidget(
        host(
          child: RotaryDial(
            title: '模式',
            items: const [
              RotaryItem('A'),
              RotaryItem('B'),
              RotaryItem('C'),
              RotaryItem('D'),
            ],
            onIndexChanged: idxs.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(RotaryDial));
      // 从 135°（进度 0）拖到 236.25°（进度 0.375 = 段 1 中心）
      await dragTo(tester, atDeg(center, 136), atDeg(center, 236.25));
      await tester.pumpAndSettle(); // 松手吸附动画播完
      expect(idxs, [1], reason: '划入段 1 实时回调一次');
    });

    testWidgets('有级：松手吸附段中心（snapOnRelease）', (tester) async {
      var idx = -1;
      await tester.pumpWidget(
        host(
          child: RotaryDial(
            title: '模式',
            items: const [RotaryItem('A'), RotaryItem('B')],
            onIndexChanged: (i) => idx = i,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(RotaryDial));
      // 拖到段 1 中部偏内一点（进度 ~0.62，仍在段 1 [0.5,1.0)）
      await dragTo(tester, atDeg(center, 136), atDeg(center, 298));
      await tester.pumpAndSettle();
      expect(idx, 1);
      // 吸附后指示点角度 = 段 1 中心进度 0.75 → 无可见断言面，这里验证
      // settle 无异常即吸附动画完整播完（快照回归交给真机）
      expect(tester.takeException(), isNull);
    });

    testWidgets('无级：拖动连续回调 onValueChanged（默认 0..1 域）', (tester) async {
      double? last;
      await tester.pumpWidget(
        host(
          child: RotaryDial(
            title: '音量',
            mode: RotaryMode.continuous,
            onValueChanged: (v) => last = v,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(RotaryDial));
      await dragTo(tester, atDeg(center, 136), atDeg(center, 270)); // 拖到顶部
      expect(last, closeTo(0.5, 1e-6), reason: '270° = 弧中点 = 0.5');
    });

    testWidgets('无级：自定义值域与格式化、刻度线', (tester) async {
      double? last;
      await tester.pumpWidget(
        host(
          child: RotaryDial(
            title: '温度',
            mode: RotaryMode.continuous,
            min: 16,
            max: 30,
            onValueChanged: (v) => last = v,
            spec: const RotaryDialSpec(
              menu: RotaryMenu(tickCount: 8, formatValue: _fmt),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(RotaryDial));
      await dragTo(tester, atDeg(center, 136), atDeg(center, 270));
      expect(last, closeTo(23, 1e-6), reason: '0.5 → 16 + 0.5·14 = 23');
      expect(find.text('23.0'), findsOneWidget, reason: 'formatValue 生效');
    });

    testWidgets('hub 内按压不响应（防中心误触跳值）', (tester) async {
      var fired = false;
      await tester.pumpWidget(
        host(
          child: RotaryDial(
            title: '模式',
            items: const [RotaryItem('A'), RotaryItem('B')],
            onIndexChanged: (_) => fired = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(RotaryDial));
      final g = await tester.startGesture(center + const Offset(10, 10));
      await tester.pump();
      await g.moveBy(const Offset(0, -60)); // 中心内拖动不触发
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(fired, isFalse, reason: 'hub 命中区外不换档');
    });

    testWidgets('外部回写：index/value 变更在非拖动期同步', (tester) async {
      var current = 0;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => host(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RotaryDial(
                  title: '模式',
                  items: const [
                    RotaryItem('A'),
                    RotaryItem('B'),
                    RotaryItem('C'),
                  ],
                  index: current,
                ),
                ElevatedButton(
                  onPressed: () => setState(() => current = 2),
                  child: const Text('跳到 2'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('跳到 2'));
      await tester.pumpAndSettle();
      // 中心值跟随外部 index（'C' 出现 2 处：环上标签 + 中心值）
      expect(find.text('C'), findsNWidgets(2));
    });
  });
}

/// 无级值格式化测试桩。
String _fmt(double v) => v.toStringAsFixed(1);
