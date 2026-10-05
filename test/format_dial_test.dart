import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/format_dial.dart';

void main() {
  group('dialHitRing 几何命中（纯函数，角锚扇形）', () {
    // 右缘锚=面板右下角（扇心），扇形占朝手心（左上）90°；左缘锚镜像
    const rightAnchor = Offset(148, 152);
    const leftAnchor = Offset(0, 152);
    const count = 3;

    Offset atDeg(Offset anchor, double deg, {double r = 50}) => Offset(
      anchor.dx + r * math.cos(deg * math.pi / 180),
      anchor.dy + r * math.sin(deg * math.pi / 180),
    );

    test('右缘锚：三扇区中径点各命中正确 index（index 0 贴水平方向）', () {
      int? hit(double deg) => dialHitRing(
        atDeg(rightAnchor, deg),
        rightAnchor,
        side: DialSide.upLeft,
        count: count,
      );
      // 三扇区各 30°：idx0 -180°~-150°、idx1 -150°~-120°、idx2 -120°~-90°
      expect(hit(-165), 0);
      expect(hit(-135), 1);
      expect(hit(-105), 2);
      // 边界归后区（-150° 归 idx1）——浮点边界不精确，取边界旁 1° 双探针
      expect(hit(-151), 0);
      expect(hit(-149), 1);
    });

    test('左缘锚：镜像对称（index 0 同样贴水平方向）', () {
      int? hit(double deg) => dialHitRing(
        atDeg(leftAnchor, deg),
        leftAnchor,
        side: DialSide.upRight,
        count: count,
      );
      // idx0 0°~-30°、idx1 -30°~-60°、idx2 -60°~-90°
      expect(hit(-15), 0);
      expect(hit(-45), 1);
      expect(hit(-75), 2);
    });

    test('四象限泛化（2026-10-04 四缘吸附）：down 象限镜像保序', () {
      // downLeft（顶缘锚扇形向左下）：canonical 镜像 y → 探针取正角
      int? hitDownLeft(double deg) => dialHitRing(
        atDeg(const Offset(148, 0), deg),
        const Offset(148, 0),
        side: DialSide.downLeft,
        count: count,
      );
      expect(hitDownLeft(165), 0);
      expect(hitDownLeft(135), 1);
      expect(hitDownLeft(105), 2);
      // downRight（顶缘锚扇形向右下）：canonical 双镜像 → 探针取正角
      int? hitDownRight(double deg) => dialHitRing(
        atDeg(const Offset(0, 0), deg),
        const Offset(0, 0),
        side: DialSide.downRight,
        count: count,
      );
      expect(hitDownRight(15), 0);
      expect(hitDownRight(45), 1);
      expect(hitDownRight(75), 2);
    });

    test('面板尺寸/锚点助手：四象限锚点与 hub 内收一致（宿主定位共用）', () {
      const geo = DialGeometry();
      final size = FormatDial.panelSize(geo);
      expect(size, const Size(kDialLeafOuterRadius + kDialHubRadius,
          kDialLeafOuterRadius + 4 + kDialHubRadius));
      // 锚点=hub 圆心：扇叶侧贴边、对边内收 hub 半径（镜像翻转）
      Offset anchor(DialSide side) => FormatDial.anchorInPanel(size, side, geo);
      expect(anchor(DialSide.upLeft), Offset(kDialLeafOuterRadius, size.height - kDialHubRadius));
      expect(anchor(DialSide.upRight), Offset(kDialHubRadius, size.height - kDialHubRadius));
      expect(anchor(DialSide.downLeft), Offset(kDialLeafOuterRadius, kDialHubRadius));
      expect(anchor(DialSide.downRight), Offset(kDialHubRadius, kDialHubRadius));
    });

    test('中心死区+缝隙（<32）不命中，32 外即命中（含边界语义）', () {
      // 精确 r=32 在双精度 atan2/sqrt 往返下抖动，死区语义用旁值双探针
      expect(
        dialHitRing(
          atDeg(rightAnchor, -135, r: kDialInnerRadius - 0.5),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
        ),
        isNull,
      );
      expect(
        dialHitRing(
          atDeg(rightAnchor, -135, r: kDialInnerRadius + 0.5),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
        ),
        1,
      );
    });

    test('外环带（68~118）按叶子数命中', () {
      // 标题叶子 2 扇区各 45°：idx0 -180°~-135°、idx1 -135°~-90°
      expect(
        dialHitRing(
          atDeg(rightAnchor, -157.5, r: 93),
          rightAnchor,
          side: DialSide.upLeft,
          count: 2,
          inner: kDialOuterRadius,
          outer: kDialLeafOuterRadius,
        ),
        0,
      );
      expect(
        dialHitRing(
          atDeg(rightAnchor, -112.5, r: 93),
          rightAnchor,
          side: DialSide.upLeft,
          count: 2,
          inner: kDialOuterRadius,
          outer: kDialLeafOuterRadius,
        ),
        1,
      );
      // 叶子环带与内环分界：68 内侧归内环带（不命中叶子参数环，旁值探针）
      expect(
        dialHitRing(
          atDeg(rightAnchor, -157.5, r: 67.5),
          rightAnchor,
          side: DialSide.upLeft,
          count: 2,
          inner: kDialOuterRadius,
          outer: kDialLeafOuterRadius,
        ),
        isNull,
      );
    });

    test('手心象限外不命中（下半圆/锚外侧）', () {
      // 右缘锚：竖直以右（-80°）与下半圆（+45°）不命中
      expect(
        dialHitRing(
          atDeg(rightAnchor, -80),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
        ),
        isNull,
      );
      expect(
        dialHitRing(
          atDeg(rightAnchor, 45),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
        ),
        isNull,
      );
      // 左缘锚：竖直以左不命中
      expect(
        dialHitRing(
          atDeg(leftAnchor, -100),
          leftAnchor,
          side: DialSide.upRight,
          count: count,
        ),
        isNull,
      );
    });

    test('磁吸迟滞：扇区交界 ±6° 内保持已高亮扇区', () {
      // 右缘锚 idx0/idx1 交界 -150°：已高亮 0 滑到 -146°（界内 4°）→ 保持 0
      expect(
        dialHitRingHysteresis(
          atDeg(rightAnchor, -146),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
          previous: 0,
        ),
        0,
      );
      // 滑到 -140°（界外 10°）→ 切 1
      expect(
        dialHitRingHysteresis(
          atDeg(rightAnchor, -140),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
          previous: 0,
        ),
        1,
      );
      // 同扇区滑动不受迟滞影响
      expect(
        dialHitRingHysteresis(
          atDeg(rightAnchor, -135),
          rightAnchor,
          side: DialSide.upLeft,
          count: count,
          previous: 1,
        ),
        1,
      );
      // 左缘锚镜像：idx0/idx1 交界 -30°，已高亮 1 滑回 -26°（界内 4°）→ 保持 1
      expect(
        dialHitRingHysteresis(
          atDeg(leftAnchor, -26),
          leftAnchor,
          side: DialSide.upRight,
          count: count,
          previous: 1,
        ),
        1,
      );
    });

    test('配置化·角度权重：3:1 权重下扇区边界按占比划分', () {
      int? hit(double deg) => dialHitRingWeighted(
        atDeg(rightAnchor, deg),
        rightAnchor,
        side: DialSide.upLeft,
        weights: const [3, 1],
      );
      // idx0 占 90°·3/4 = -180°~-112.5°；idx1 -112.5°~-90°
      expect(hit(-150), 0);
      expect(hit(-120), 0);
      expect(hit(-110), 1);
      expect(hit(-95), 1);
      // 边界旁双探针（-112.5° 归后区 idx1）
      expect(hit(-114), 0);
      expect(hit(-111), 1);
    });

    test('配置化·总扇角：120° 扇出时竖直以右弧域也命中（90° 下不命中）', () {
      int? hitWide(double deg) => dialHitRingWeighted(
        atDeg(rightAnchor, deg),
        rightAnchor,
        side: DialSide.upLeft,
        weights: const [1, 1],
        sweep: 120 * math.pi / 180,
      );
      // idx0 -180°~-120°、idx1 -120°~-60°
      expect(hitWide(-130), 0);
      expect(hitWide(-75), 1, reason: '越过竖直边的弧域可命中');
      // 同点在默认 90° 扇角下不命中（扇角外）
      expect(
        dialHitRing(
          atDeg(rightAnchor, -75),
          rightAnchor,
          side: DialSide.upLeft,
          count: 2,
        ),
        isNull,
      );
    });
  });

  group('FormatDial widget 冒烟（右缘锚=面板右下角扇心）', () {
    Widget host({
      Set<int>? disabledCategories,
      void Function(int)? onCategorySelect,
      void Function(int, int)? onLeafSelect,
      void Function(DialDismissReason)? onDismiss,
      DialSide side = DialSide.upLeft,
      DialSpec spec = const DialSpec(),
    }) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: side == DialSide.upLeft
              ? Alignment.bottomRight
              : Alignment.bottomLeft,
          child: FormatDial(
            side: side,
            spec: spec,
            disabledCategories: disabledCategories,
            onCategorySelect: onCategorySelect ?? (_) {},
            onLeafSelect: onLeafSelect ?? (_, _) {},
            onDismiss: onDismiss ?? (_) {},
          ),
        ),
      ),
    );

    /// 扇心：面板角锚（右缘锚=右下角、左缘锚=左下角）。面板矩形已为 hub
    /// 完整圆外扩 hub 半径（锚点内收），扇心=角点向面板内收 (hubR,hubR)。
    Offset anchorOf(WidgetTester tester, DialSide side) {
      final rect = tester.getRect(find.byType(FormatDial));
      return side == DialSide.upLeft
          ? rect.bottomRight - const Offset(kDialHubRadius, kDialHubRadius)
          : rect.bottomLeft + const Offset(kDialHubRadius, -kDialHubRadius); // 锚点内收 hub 半径
    }

    Offset atDeg(Offset anchor, double deg, {double r = 50}) => Offset(
      anchor.dx + r * math.cos(deg * math.pi / 180),
      anchor.dy + r * math.sin(deg * math.pi / 180),
    );

    Future<void> pressAt(WidgetTester tester, Offset pos) async {
      final g = await tester.startGesture(pos);
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    testWidgets('正文扇区松手 → 挂起停留，走完 onCategorySelect(1) 并闭合', (tester) async {
      var cat = -1;
      var dismissed = false;
      await tester.pumpWidget(
        host(
          onCategorySelect: (i) => cat = i,
          onDismiss: (_) => dismissed = true,
        ),
      );
      await tester.pumpAndSettle();
      // 正文 Aa = idx1（中角 -135°、中径 50）
      await pressAt(tester, atDeg(anchorOf(tester, DialSide.upLeft), -135));
      expect(cat, -1, reason: '直选也走反悔窗口（2026-10-05 拍板：防误触切档）');
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(cat, 1);
      expect(dismissed, isTrue, reason: '停留走完提交并闭合');
    });

    testWidgets('正文直选反悔：Aa 挂起后 hub 死区松手收合 → 不生效', (tester) async {
      var cat = -1;
      await tester.pumpWidget(host(onCategorySelect: (i) => cat = i));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -135)); // Aa 挂起
      // 反悔：按 hub 死区松手 → 整盘收合（放弃），挂起作废
      await pressAt(tester, anchor + const Offset(-3, -3));
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(cat, -1, reason: '收合即放弃，直选未落地');
    });

    testWidgets('行内 B 松手 → 反悔停留倒计时走完才生效 onLeafSelect(2,0)', (
      tester,
    ) async {
      (int, int)? picked;
      var dismissed = false;
      await tester.pumpWidget(
        host(
          onLeafSelect: (c, l) => picked = (c, l),
          onDismiss: (_) => dismissed = true,
        ),
      );
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      // 第一段：滑入「BIU」扇区（idx2 中角 -105°）松手 → 扇出三级保持展开
      await pressAt(tester, atDeg(anchor, -105));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget, reason: '行内子盘已扇出');
      // 第二段：外环 B（idx0 中角 -165°、中径 93）松手 → 挂起不立即生效
      await pressAt(tester, atDeg(anchor, -165, r: 93));
      expect(picked, isNull, reason: '反悔窗口内不提交');
      expect(find.text('BIU'), findsOneWidget, reason: '盘面字恒定地标（去路径字 2026-10-04 拍板：叶子高亮+倒计时弧已足够）');
      // 反悔窗口（kDialLeafDwell）走完 → 自动提交 + selected 闭合
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(picked, (2, 0));
      expect(dismissed, isTrue);
    });

    testWidgets('反悔窗口内改选：B 挂起后再按 I → 只提交改选后的 I', (tester) async {
      final picks = <(int, int)>{};
      await tester.pumpWidget(host(onLeafSelect: (c, l) => picks.add((c, l))));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起
      await pressAt(tester, atDeg(anchor, -135, r: 93)); // 反悔改选 I
      expect(picks, isEmpty, reason: '改选重挂起，B 已作废');
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(picks, {(2, 1)}, reason: '窗口走完只提交改选后的 I');
    });

    testWidgets('反悔窗口内滑回深处回根 → 放弃不提交', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(host(onLeafSelect: (c, l) => picked = (c, l)));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起
      // 反悔第二式：按压 hub 死区松手 → 回根态，挂起作废
      await pressAt(tester, anchor + const Offset(-3, -3));
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(picked, isNull, reason: '回根即放弃，倒计时不补提交');
    });

    testWidgets('选到三级：内外两环同显 + 二级盘面字恒定（去路径字拍板）', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      // 滑入「H」扇区松手 → 三级扇出，内环分类与外环叶子同时可见
      await pressAt(tester, atDeg(anchor, -165));
      await tester.pumpAndSettle();
      // 盘面字恒定地标：活动分类不再升级为「H›」路径前缀（2026-10-04 拍板）
      expect(find.text('H'), findsOneWidget, reason: '二级扇区保持分类标识');
      expect(find.text('Aa'), findsWidgets, reason: '分类扇区 + hub 盘面字');
      expect(find.text('BIU'), findsOneWidget);
      expect(find.text('H1'), findsOneWidget, reason: '外环叶子环同显');
      expect(find.text('H2'), findsOneWidget);
    });

    testWidgets('左缘锚镜像：标题扇区在贴水平侧，扇出后叶子停留生效', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(
        host(
          side: DialSide.upRight,
          onLeafSelect: (c, l) => picked = (c, l),
        ),
      );
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upRight);
      // 左缘锚 idx0（0°~-30°）中角 -15° = 标题（镜像贴水平）
      await pressAt(tester, atDeg(anchor, -15));
      await tester.pumpAndSettle();
      expect(find.text('H1'), findsOneWidget, reason: '三级扇出');
      // H1 叶子（idx0 中角 -157.5°→镜像 -22.5°、中径 93）松手挂起，停留走完生效
      await pressAt(tester, atDeg(anchor, -22.5, r: 93));
      expect(picked, isNull, reason: '反悔窗口内不提交');
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(picked, (0, 0));
    });

    testWidgets('死区按下松手 → 空选收合 onDismiss', (tester) async {
      var dismissed = false;
      await tester.pumpWidget(host(onDismiss: (_) => dismissed = true));
      await tester.pumpAndSettle();
      await pressAt(
        tester,
        anchorOf(tester, DialSide.upLeft) + const Offset(-3, -3),
      );
      expect(dismissed, isTrue);
    });

    testWidgets('标题行（disabledCategories={2}）行内扇区置灰不扇出', (tester) async {
      await tester.pumpWidget(host(disabledCategories: const {2}));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 行内扇区
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing, reason: '置灰扇区不响应');
    });

    testWidgets('配置化：自定义菜单/几何/权重全部生效', (tester) async {
      var catPicked = -1;
      (int, int)? picked;
      await tester.pumpWidget(
        host(
          spec: const DialSpec(
            geometry: DialGeometry(leafOuterRadius: 150),
            menu: DialMenu(
              categories: [
                DialCategory('X', angleWeight: 2),
                DialCategory('Y', leaves: [DialLeaf('L1')]),
              ],
            ),
          ),
          onCategorySelect: (i) => catPicked = i,
          onLeafSelect: (c, l) => picked = (c, l),
        ),
      );
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      // 自定义几何生效：面板外径随 leafOuterRadius=150 放大
      expect(
        tester.getSize(find.byType(FormatDial)).width,
        150 + kDialHubRadius,
      );
      // 自定义权重生效：X 占 2/3·90°=-180°~-120°，中角 -150° 命中 X
      // （直选类走反悔停留，倒计时走完落地）
      await pressAt(tester, atDeg(anchor, -150));
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(catPicked, 0, reason: 'X 权重 2：-150° 落在 X 扇区');
      // 自定义菜单生效：Y 三级叶子 L1（唯一叶占满象限，中角 -135°、中径 109）
      await pressAt(tester, atDeg(anchor, -115)); // -115° 落在 Y（界内）入三级
      await tester.pumpAndSettle();
      expect(find.text('L1'), findsOneWidget, reason: '自定义叶子已扇出');
      await pressAt(tester, atDeg(anchor, -135, r: 109));
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(picked, (1, 0));
    });

    testWidgets('配置化：sectorBuilder 自定义扇区内容（定位仍归组件）', (tester) async {
      await tester.pumpWidget(
        host(
          spec: const DialSpec(
            menu: DialMenu(
              sectorBuilder: _tagBuilder,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('H*'), findsOneWidget, reason: 'builder 内容替换默认文字');
      expect(find.text('H'), findsNothing, reason: '默认文字不再渲染');
    });

    testWidgets('配置化：feel.leafDwellEnabled=false → 叶子松手立即提交', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(
        host(
          spec: const DialSpec(
            feel: DialFeel(leafDwellEnabled: false),
          ),
          onLeafSelect: (c, l) => picked = (c, l),
        ),
      );
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 松手
      expect(picked, (2, 0), reason: '停留停用：松手即选，无需等倒计时');
    });

    testWidgets('动画：叶子环错峰入场（stagger 延迟内透明，settle 后全显）', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级（触发换类动画）
      // 不 settle：stagger 80ms 延迟期内叶子文字完全透明（延迟 80/180 进度）
      await tester.pump(const Duration(milliseconds: 30));
      double opacityOfB() => tester.widget<Opacity>(
        find.ancestor(of: find.text('B'), matching: find.byType(Opacity)).first,
      ).opacity;
      expect(opacityOfB(), 0, reason: 'stagger 延迟期叶子未入场');
      await tester.pumpAndSettle();
      expect(opacityOfB(), 1, reason: '错峰入场完成后全显');
    });

    testWidgets('动画：提交脉冲——selected 退场期选中叶保留加亮，播完回根', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(_ClosingHost(onLeafSelect: (c, l) => picked = (c, l)));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50)); // 提交
      await tester.pump(const Duration(milliseconds: 60)); // 退场中段
      expect(picked, (2, 0));
      expect(find.text('B'), findsOneWidget, reason: 'pulse：退场期选中叶仍在场加亮');
      expect(
        find.ancestor(of: find.text('B'), matching: find.byType(Transform)),
        findsWidgets,
        reason: '选中叶微放大（Transform.scale > 1）',
      );
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing, reason: '退场播完回根态摘除');
    });

    testWidgets('修正：打字打断反悔窗口 = 强确认，挂起选择落地不丢失', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(_ClosingHost(onLeafSelect: (c, l) => picked = (c, l)));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起
      expect(picked, isNull, reason: '窗口内未提交');
      // 模拟打字：宿主 keyPressed 关闭打断挂起（真机「选完立刻打字」流）
      await tester.tap(find.text('打断'));
      await tester.pump(); // didUpdateWidget 注册 post-frame 提交
      await tester.pump(); // post-frame 落地
      expect(picked, (2, 0), reason: '打断=强确认：挂起选择落地不丢');
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing, reason: '退场播完正常摘除');
    });

    testWidgets('动画：commitPulse=false → 提交即回根整体淡出', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(
        _ClosingHost(
          feel: const DialFeel(commitPulse: false),
          onLeafSelect: (c, l) => picked = (c, l),
        ),
      );
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 60));
      expect(picked, (2, 0));
      expect(find.text('B'), findsNothing, reason: '无脉冲：提交即回根，叶子随整体淡出');
    });

    test('DialFeel 默认：easeInCubic 退场 / 80ms 错峰 / 脉冲开启', () {
      const feel = DialFeel();
      expect(feel.exitCurve, Curves.easeInCubic);
      expect(feel.stagger, kDialLeafStagger);
      expect(feel.commitPulse, isTrue);
    });

    testWidgets('双击加速：反悔窗口内再按同叶 → 跳过等待立即提交', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(host(onLeafSelect: (c, l) => picked = (c, l)));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起（倒计时中）
      expect(picked, isNull);
      // 第二次按同叶：不重置倒计时，松手即提交（未 pump dwell 时长）
      await pressAt(tester, atDeg(anchor, -165, r: 93));
      expect(picked, (2, 0), reason: '双击同叶跳过等待立即落地');
    });

    testWidgets('双击加速解除：按住后拖离同叶 → 回常规反悔流（不提交）', (tester) async {
      (int, int)? picked;
      await tester.pumpWidget(host(onLeafSelect: (c, l) => picked = (c, l)));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -105)); // 入 BIU 三级
      await tester.pumpAndSettle();
      await pressAt(tester, atDeg(anchor, -165, r: 93)); // B 挂起
      // 按下 B 后拖到 I 再松手：双击加速解除，改选 I 重新挂起
      final g = await tester.startGesture(atDeg(anchor, -165, r: 93));
      await tester.pump();
      await g.moveBy(atDeg(anchor, -135, r: 93) - atDeg(anchor, -165, r: 93));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(picked, isNull, reason: '拖离解除加速，I 重新挂起未提交');
      // 恰等长有浮点边界抖动，略超时长确保完成
      await tester.pump(kDialLeafDwell + const Duration(milliseconds: 50));
      expect(picked, (2, 1), reason: '改选后的 I 倒计时走完落地');
    });

    testWidgets('双击加速：二级直选同项同理（Aa 双击立即切档）', (tester) async {
      var cat = -1;
      await tester.pumpWidget(host(onCategorySelect: (i) => cat = i));
      await tester.pumpAndSettle();
      final anchor = anchorOf(tester, DialSide.upLeft);
      await pressAt(tester, atDeg(anchor, -135)); // Aa 挂起
      expect(cat, -1);
      await pressAt(tester, atDeg(anchor, -135)); // 双击同项
      expect(cat, 1, reason: '直选双击立即切档');
    });
  });
}

/// 模拟真实宿主的分级闭合（onDismiss → closing → onExitDone），
/// 供退场类动画（提交脉冲等）用例驱动完整生命周期；「打断」按钮模拟
/// 打字触发的 keyPressed 分级闭合。
class _ClosingHost extends StatefulWidget {
  const _ClosingHost({this.onLeafSelect, this.feel});

  final void Function(int, int)? onLeafSelect;
  final DialFeel? feel;

  @override
  State<_ClosingHost> createState() => _ClosingHostState();
}

class _ClosingHostState extends State<_ClosingHost> {
  DialDismissReason? _closing;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Align(
              alignment: Alignment.bottomRight,
              child: FormatDial(
                spec: DialSpec(feel: widget.feel ?? const DialFeel()),
                onCategorySelect: (_) {},
                onLeafSelect: (c, l) => widget.onLeafSelect?.call(c, l),
                onDismiss: (r) => setState(() => _closing = r),
                closing: _closing,
                onExitDone: () => setState(() => _closing = null),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: TextButton(
                onPressed: () =>
                    setState(() => _closing = DialDismissReason.keyPressed),
                child: const Text('打断'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// sectorBuilder 测试桩：所有扇区渲染「标签*」。
Widget? _tagBuilder(DialSectorContext ctx) => Text('${ctx.label}*');
