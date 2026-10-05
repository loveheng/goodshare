import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 速记格式转盘（可收起三级径向盘，双环联动，可配置化）——
/// docs/design/quick-note-format-dial.md。
///
/// 分层约束：本组件只管扇形呈现与手势命中，**零业务语义**——菜单项、
/// 环尺寸、每项角度、扇角、动效手感均经 [DialSpec] 注入（缺省回落组件
/// 内默认值），选中语义（档位/mark 落地）由宿主经 `onCategorySelect` /
/// `onLeafSelect` 映射（段模型层零改动）。命中判定为纯几何函数
///（[dialHitRingWeighted] 等），独立可单测。
///
/// 几何契约（真机反馈 2026-10-03 定标，回写设计稿 §2.2；配置化 2026-10-04；
/// 四象限泛化 2026-10-04 随悬浮球四缘吸附）：
/// - **向手心扇出**：锚点象限 [DialSide] 四值——扇形朝屏内对角展开
///  （右缘下段锚=向左上、顶缘锚=向左下等，宿主按停靠位算象限传入），
///   总扇角默认 90° 可配；
/// - **双环**：内环 [innerRadius, outerRadius] = 二级分类；三级态时外环
///  （outerRadius, leafOuterRadius] = 叶子项——选到三级时两环同显，
///   内环常驻可滑回换类；
/// - 松手挂起反悔（2026-10-04 拍板；10-05 扩至二级直选）：松手不立即
///   生效——挂起 leafDwell 倒计时（hub 外缘弧填充 + 持续高亮），走完提交
///   并按 selected 收合；窗口内再按压 = 反悔改选/放弃，滑回深处回根同效
///  （可经 feel.leafDwellEnabled 关闭回到「松手即选」）；
///   **打字/失焦打断 = 强确认**（先落地挂起选择再退场，绝不作废——
///   「选完立刻打字」高频流的静默丢提交是真机实证事故）；
///   内环分类松手切类/保持展开；死区松手：根态收合、三级态回根；
/// - 联动：内环分类按压期间向外环续滑即入三级（无需抬手）；快速 tap
///   分类（hover 未及）松手也扇出三级，第二次手势选叶子；
/// - 触觉：划入新高亮扇区 selectionClick（可经 feel.haptics 关闭）。

// ---------- 几何默认值（真机 2026-10-03 定标；DialGeometry 未指定项回落） ----------

/// 内环外半径（= 二级分类环带外缘，L2）。
/// 2026-10-05 定标（真机反馈「环没盘大、不协调」）：环带宽度必须盖过
/// hub 直径——L2 带 50dp vs hub d40，环为盘面主体。
const double kDialOuterRadius = 76;

/// 扇环内半径 = 二级环内缘（L2，缝隙外缘）。
const double kDialInnerRadius = 26;

/// 内整圆 hub 半径（L1=格式按钮本体）。
/// 2026-10-03 拍板：最内圈是**完整圆**=格式按钮本体，显示当前所选
///（默认正文）；按 hub=根态收合/三级态回根（原死区语义）。
/// 2026-10-05 定标：24→20（d=40）——展开态 hub 处于连续手势盘内可略低于
/// 48dp 触控线（收起态圆钮仍 48dp）；与 L2 内缘(26) 间 6dp 缝隙作视觉
/// 截断+防误触留白；缝隙松手并入 hub 取消/回根语义（<26 全算）。
const double kDialHubRadius = 20;

/// 外环（三级叶子）外半径（L3）：环带 52dp 着陆区，与 L2 带等宽协调。
const double kDialLeafOuterRadius = 128;

/// 三级回退半径：三级态滑回锚点深处（hub 内）回根态。
const double kDialBackRadius = 14;

/// 手心象限总扇角（弧度，默认 90° 四分之一圆；可放大如 120°）。
const double kDialSweepAngle = math.pi / 2;

/// 角度磁吸迟滞：扇区交界 ±此角度内保持已高亮扇区（防边缘高频闪烁）。
const double kDialSectHysteresis = 6; // 度

/// 入场动画时长（半径/透明度 tween）。
const Duration kDialEnterDuration = Duration(milliseconds: 180);

/// 闭合原因分级（V11 质感层 2026-10-04 拍板）：
/// - [timeout] 写作区失焦 1.5s 超时：400ms 柔和收缩（easeIn，有呼吸感）；
/// - [keyPressed] 打字/键盘事件：80ms 极速淡出（指尖触键菜单即灭，
///   不挡光标处候选框）；
/// - [selected] 选中生效：高亮反馈后收合（确认感）。
enum DialDismissReason { timeout, keyPressed, selected }

/// 超时/选中闭合时长（柔和收缩）。2026-10-04 二次拍板：200→400ms——
/// 真机反馈「按钮消失太快、节奏赶」，退场放慢给足确认感。
const Duration kDialExitSoft = Duration(milliseconds: 400);

/// 打字即时收时长（极速淡出）。
const Duration kDialExitInstant = Duration(milliseconds: 80);

/// 三级选中反悔窗口（2026-10-04 拍板）：叶子松手不立即生效，面板停留
/// 此时长倒计时（hub 外缘弧填充+pending 高亮），窗口内滑到别的叶子可
/// 改选、滑回深处回根可放弃，倒计时走完才提交并按 selected 闭合。
/// 2026-10-04 二次拍板：1s→1.5s——真机反馈「节奏赶」，倒计时放慢；
/// 急选走双击加速不受影响。
const Duration kDialLeafDwell = Duration(milliseconds: 1500);

/// 三级叶子环错峰入场延迟（2026-10-04 拍板）：叶子环相对内环延迟此时长
/// 再生长淡入（水波纹由内向外），0 = 与内环同步。
const Duration kDialLeafStagger = Duration(milliseconds: 80);

/// 锚点象限：扇形自锚点朝屏内展开的对角方向（2026-10-04 拍板：悬浮球
/// 四缘吸附后扇出方向随停靠缘泛化——右缘下段=upLeft、左缘下段=upRight、
/// 顶缘=down*、底缘=up*；水平/竖直各取「朝屏内」方向组合而定）。
/// 值名 = 扇形展开方向，锚点恒在其对角：upLeft 即锚点在面板右下角。
enum DialSide { upLeft, upRight, downLeft, downRight }

/// 四象限镜像归一：把任意 [DialSide] 的几何映射到 canonical upLeft
///（锚点右下角、扇形向左上）后复用同一套角度数学——命中/绘制/文字
/// 三处共用，防象限间漂移。
extension DialSideMirror on DialSide {
  /// 水平镜像（扇形朝右展开的象限）。
  bool get mirrorX => this == DialSide.upRight || this == DialSide.downRight;

  /// 竖直镜像（扇形朝下展开的象限）。
  bool get mirrorY => this == DialSide.downLeft || this == DialSide.downRight;
}

// ---------- 配置模型（menu / geometry / feel 三节） ----------

/// 三级叶子项：标签 + 相对角度权重（同环内占比，全部默认 1 = 等分）。
class DialLeaf {
  const DialLeaf(this.label, {this.angleWeight = 1.0});

  final String label;
  final double angleWeight;
}

/// 内环分类项：标签 + 三级叶子（空 = 无三级，内环松手直选）+ 置灰 +
/// 相对角度权重。
class DialCategory {
  const DialCategory(
    this.label, {
    this.leaves = const [],
    this.disabled = false,
    this.angleWeight = 1.0,
  });

  final String label;

  /// 三级叶子内容；空列表 = 无三级（直选类，内环松手即生效）。
  final List<DialLeaf> leaves;

  /// 静态禁用置灰（动态置灰走 FormatDial.disabledCategories）。
  final bool disabled;

  final double angleWeight;

  bool get hasLeaves => leaves.isNotEmpty;
}

/// 默认菜单（2026-10-04 拍板业界通俗标识：H=标题层级、Aa=正文段落、
/// BIU=行内加粗/斜体/下划线——中文二字在 36dp 环宽里局促）。
const List<DialLeaf> kTitleLeaves = [DialLeaf('H1'), DialLeaf('H2')];
const List<DialLeaf> kInlineLeaves = [DialLeaf('B'), DialLeaf('I'), DialLeaf('U')];
const List<DialCategory> kDialCategories = [
  DialCategory('H', leaves: kTitleLeaves),
  DialCategory('Aa'),
  DialCategory('BIU', leaves: kInlineLeaves),
];

/// 环尺寸/扇角配置（未指定项用 DialGeometry 构造默认值回落）。
class DialGeometry {
  const DialGeometry({
    this.hubRadius = kDialHubRadius,
    this.innerRadius = kDialInnerRadius,
    this.outerRadius = kDialOuterRadius,
    this.leafOuterRadius = kDialLeafOuterRadius,
    this.backRadius = kDialBackRadius,
    this.fanoutOvershoot = 10,
    this.sweepAngle = kDialSweepAngle,
  });

  /// L1 hub（格式按钮本体）半径；与 L2 内缘间为视觉缝隙。
  final double hubRadius;

  /// L2 内缘（缝隙外缘）。
  final double innerRadius;

  /// L2 外缘。
  final double outerRadius;

  /// L3 外缘（叶子环着陆区外缘）。
  final double leafOuterRadius;

  /// 三级态滑回锚点深处（< backRadius）回根态阈值。
  final double backRadius;

  /// 根态向外续滑越过 L2 外缘此距离即扇出三级（无需抬手）。
  final double fanoutOvershoot;

  /// 手心象限总扇角（弧度；>90° 时面板包围盒自动放宽）。
  final double sweepAngle;
}

/// 菜单内容配置：内环分类（含各自叶子与角度权重）+ 扇区自定义渲染。
class DialMenu {
  const DialMenu({this.categories = kDialCategories, this.sectorBuilder});

  final List<DialCategory> categories;

  /// 扇区自定义渲染（null = 默认文字标签，真实 Text 可被 find.text 定位
  /// + 无障碍可读）。返回 null 同样回落默认文字。定位（扇区中角/环带
  /// 中径）仍由组件统一计算，builder 只决定内容 widget。
  final Widget? Function(DialSectorContext context)? sectorBuilder;
}

/// 扇区渲染上下文（传入 sectorBuilder）。
class DialSectorContext {
  const DialSectorContext({
    required this.ring,
    required this.index,
    required this.label,
    required this.highlighted,
    required this.applied,
    required this.dimmed,
  });

  /// 环层级：0=内环分类、1=外环叶子。
  final int ring;
  final int index;
  final String label;

  /// 悬停/挂起强高亮（primaryContainer 实色配套）。
  final bool highlighted;

  /// 已生效弱高亮（选中路径回显）。
  final bool applied;

  /// 置灰（禁用）。
  final bool dimmed;
}

/// 手感配置：反悔停留、磁吸迟滞、触觉、动效时长与曲线。
class DialFeel {
  const DialFeel({
    this.leafDwell = kDialLeafDwell,
    this.leafDwellEnabled = true,
    this.hysteresis = kDialSectHysteresis,
    this.haptics = true,
    this.enterDuration = kDialEnterDuration,
    this.exitSoftDuration = kDialExitSoft,
    this.exitInstantDuration = kDialExitInstant,
    this.enterCurve = Curves.easeOutCubic,
    this.exitCurve = Curves.easeInCubic,
    this.stagger = kDialLeafStagger,
    this.commitPulse = true,
  });

  /// 三级反悔停留时长（leafDwellEnabled=false 时整段停用→松手即选）。
  final Duration leafDwell;
  final bool leafDwellEnabled;

  /// 扇区交界磁吸迟滞角（度）。
  final double hysteresis;

  /// 触觉反馈开关（划入 selectionClick / 挂起 mediumImpact / 生效 lightImpact）。
  final bool haptics;

  /// 入场时长与环带生长曲线；退场分级时长（超时柔和/打字极速）与曲线
  ///（easeInCubic：由快变慢的体面收拢，V11 非对称退场拍板）。
  final Duration enterDuration;
  final Duration exitSoftDuration;
  final Duration exitInstantDuration;
  final Curve enterCurve;
  final Curve exitCurve;

  /// 三级叶子环错峰入场延迟（相对内环；水波纹由内向外，0=同步）。
  final Duration stagger;

  /// 提交脉冲（2026-10-04 拍板）：selected 退场期保留选中叶高亮并微放大
  ///（1.0→1.15 随退场进度），其余扇区随整体淡出——零额外退场时长。
  final bool commitPulse;
}

/// 转盘配置聚合（三节；全部有默认值，按需覆盖）。
class DialSpec {
  const DialSpec({
    this.geometry = const DialGeometry(),
    this.menu = const DialMenu(),
    this.feel = const DialFeel(),
  });

  final DialGeometry geometry;
  final DialMenu menu;
  final DialFeel feel;
}

// ---------- 几何命中（纯函数） ----------

/// 权重 → 归一化累计起点分数（长度 n，starts[0]=0，末项 + frac = 1）。
/// 命中/绘制/文字三处共用同一角度映射，防漂移。
List<double> dialSectorStarts(List<double> weights) {
  assert(weights.isNotEmpty);
  final total = weights.fold<double>(0, (a, b) => a + b);
  final n = weights.length;
  final starts = <double>[];
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    starts.add(acc);
    acc += total <= 0 ? 1 / n : weights[i] / total;
  }
  return starts;
}

/// 第 i 扇区角宽分数（配合 [dialSectorStarts]）。
double dialSectorFraction(List<double> weights, int i) {
  final starts = dialSectorStarts(weights);
  return (i + 1 < weights.length ? starts[i + 1] : 1.0) - starts[i];
}

/// 扇环命中（权重版，纯函数）：面板局部坐标 → 扇区 index，未命中返回 null。
///
/// 锚点 [center] 在面板**外侧角**（象限对角，见 [DialSide]），扇形只占朝
/// 屏内的 [sweep] 弧（默认 90° 四分之一圆）。[weights] 为各扇区相对角度
/// 权重（和不必为 1）；扇区 index 0 贴水平方向，递增趋向竖直，镜像象限
/// 保序。手心弧域外、环带外一律 null。
int? dialHitRingWeighted(
  Offset pos,
  Offset center, {
  required DialSide side,
  required List<double> weights,
  double inner = kDialInnerRadius,
  double outer = kDialOuterRadius,
  double sweep = kDialSweepAngle,
}) {
  if (weights.isEmpty) return null;
  var dx = pos.dx - center.dx;
  var dy = pos.dy - center.dy;
  // 镜像归一到 canonical 象限（upLeft：锚点右下、扇形向左上）再算角度
  if (side.mirrorX) dx = -dx;
  if (side.mirrorY) dy = -dy;
  final r = math.sqrt(dx * dx + dy * dy);
  if (r < inner || r > outer) return null;
  final angle = math.atan2(dy, dx); // y 向下
  // canonical 手心弧域：锚点右下角，自 -180° 起向竖直扫 sweep
  final inHand = angle > -math.pi && angle <= -math.pi + sweep;
  if (!inHand) return null;
  // 归一化弧位 u ∈ [0,1]：0 贴水平、1 贴竖直边界（镜像保序，证明见
  // devlog 2026-10-04）
  final u = (angle + math.pi) / sweep;
  final starts = dialSectorStarts(weights);
  for (var i = 0; i < weights.length; i++) {
    final end = i + 1 < weights.length ? starts[i + 1] : 2.0;
    if (u < end) return i;
  }
  return weights.length - 1;
}

/// 扇环命中（等分版薄壳）：count 个等权扇区。
int? dialHitRing(
  Offset pos,
  Offset center, {
  required DialSide side,
  required int count,
  double inner = kDialInnerRadius,
  double outer = kDialOuterRadius,
  double sweep = kDialSweepAngle,
}) {
  return dialHitRingWeighted(
    pos,
    center,
    side: side,
    weights: List.filled(count, 1.0),
    inner: inner,
    outer: outer,
    sweep: sweep,
  );
}

/// 磁吸迟滞命中（权重版）：新 index 与旧不同、但夹角差在 [hysteresis] 度内
/// 时保持旧值。扇区中角与边界均按权重累计分数推得。
int? dialHitRingHysteresisWeighted(
  Offset pos,
  Offset center, {
  required DialSide side,
  required List<double> weights,
  int? previous,
  double inner = kDialInnerRadius,
  double outer = kDialOuterRadius,
  double sweep = kDialSweepAngle,
  double hysteresis = kDialSectHysteresis,
}) {
  final hit = dialHitRingWeighted(
    pos,
    center,
    side: side,
    weights: weights,
    inner: inner,
    outer: outer,
    sweep: sweep,
  );
  if (hit == null || previous == null || hit == previous) return hit;
  final starts = dialSectorStarts(weights);
  double frac(int i) => dialSectorFraction(weights, i);
  // 扇区中角（度）：镜像归一到 canonical（锚点右下）后统一口径——
  // 自 -180° 起向竖直递增；命中点角度同样在 canonical 系取值
  var dx = pos.dx - center.dx;
  var dy = pos.dy - center.dy;
  if (side.mirrorX) dx = -dx;
  if (side.mirrorY) dy = -dy;
  final prevMidU = starts[previous] + frac(previous) / 2;
  final prevMidDeg = -180.0 + prevMidU * sweep * 180 / math.pi;
  final deg = math.atan2(dy, dx) * 180 / math.pi;
  // 与相邻扇区共享的边界角（朝 hit 方向越过 prev 扇区半宽）
  final boundary =
      prevMidDeg + (hit > previous ? 1.0 : -1.0) * frac(previous) * sweep * 180 / math.pi / 2;
  if ((deg - boundary).abs() <= hysteresis) return previous;
  return hit;
}

/// 磁吸迟滞命中（等分版薄壳）。
int? dialHitRingHysteresis(
  Offset pos,
  Offset center, {
  required DialSide side,
  required int count,
  int? previous,
  double inner = kDialInnerRadius,
  double outer = kDialOuterRadius,
  double sweep = kDialSweepAngle,
  double hysteresis = kDialSectHysteresis,
}) {
  return dialHitRingHysteresisWeighted(
    pos,
    center,
    side: side,
    weights: List.filled(count, 1.0),
    previous: previous,
    inner: inner,
    outer: outer,
    sweep: sweep,
    hysteresis: hysteresis,
  );
}

// ---------- 组件 ----------

/// 径向格式转盘面板（展开态双环扇形 + 内整圆 hub，不含一级圆钮——展开期
/// hub 即格式按钮本体，宿主原钮隐藏）。零业务语义：菜单/几何/手感经
/// [spec] 注入，缺省 [DialSpec] 即默认转盘。
class FormatDial extends StatefulWidget {
  const FormatDial({
    super.key,
    required this.onCategorySelect,
    required this.onLeafSelect,
    required this.onDismiss,
    this.spec = const DialSpec(),
    this.onLeavesChanged,
    this.closing,
    this.onExitDone,
    this.currentLabel = 'Aa',
    this.hubLit = false,
    this.disabledCategories,
    this.appliedInner = const {},
    this.appliedLeaf = const {},
    this.side = DialSide.upLeft,
  });

  /// 配置（geometry/menu/feel 三节；缺省 = 默认菜单与真机定标几何）。
  final DialSpec spec;

  /// 无三级分类直选（如正文 Aa）：回调分类 index。
  final void Function(int categoryIndex) onCategorySelect;

  /// 三级叶子选中（反悔窗口走完或即时）：回调分类 index + 叶子 index。
  final void Function(int categoryIndex, int leafIndex) onLeafSelect;

  /// 根态死区/空选松手 = 收合；选中生效后同样回调（宿主借此自动闭合）。
  /// 携带关闭原因，宿主可按分级退场（V11）：selected 高亮确认 /
  /// timeout 柔和收缩 / keyPressed 极速淡出。
  final void Function(DialDismissReason reason) onDismiss;

  /// 三级叶子内容随二级联动变化时回调（联动瞬间宿主拉回键盘事件）。
  final VoidCallback? onLeavesChanged;

  /// 宿主发起的分级闭合（非 null 即进入退场动画：keyPressed 80ms 极速
  /// 淡出 / timeout 400ms 柔和收缩；selected 已在内部走选中退场）。
  /// 动画播完回调 [onExitDone]，宿主再摘除面板——避免生硬截断。
  final DialDismissReason? closing;

  /// 退场动画播完通知（宿主摘除面板的唯一出口）。
  final VoidCallback? onExitDone;

  /// hub 盘面字 = 当前所选格式（默认正文；宿主由档位/激活 mark 算）。
  final String currentLabel;

  /// hub 点亮态（有激活格式时 primaryContainer，对齐原圆钮点亮语言）。
  final bool hubLit;

  /// 动态禁用置灰的分类 index 集（如标题行上行内盘互斥置灰，§2.7）；
  /// 与 DialCategory.disabled 静态位取并集。
  final Set<int>? disabledCategories;

  /// 已生效（非悬停）持久回显：分类 index 集（选中路径回显——对应 L2
  /// 扇区文字主色加亮，用户始终看得到「当前在什么上」）。
  final Set<int> appliedInner;

  /// 已生效叶子回显：按分类 index 的叶子 index 集（仅三级态当前类消费）。
  final Map<int, Set<int>> appliedLeaf;

  /// 锚点象限（决定扇出方向，真机反馈：向手心出环；宿主按停靠位计算）。
  final DialSide side;

  /// 面板尺寸（象限无关，宿主定位共用）：扇弧包围盒 + hub 完整圆外扩
  /// 余量（hub 中心=锚点，全圆完整呈现须矩形各向外扩 hub 半径）。扇角
  /// >90° 时弧越过竖直边，包围盒相应放宽（镜像象限对称，总尺寸不变）。
  static Size panelSize(DialGeometry geo) {
    final relOverhang = geo.sweepAngle > math.pi / 2
        ? geo.leafOuterRadius * math.cos(-math.pi + geo.sweepAngle)
        : 0.0;
    return Size(
      geo.leafOuterRadius + math.max(relOverhang, geo.hubRadius),
      geo.leafOuterRadius + 4 + geo.hubRadius,
    );
  }

  /// 锚点（hub 圆心）在面板内的位置（宿主定位共用）：canonical upLeft =
  /// 扇叶侧贴边、锚点距对边 hub 半径内收；镜像象限按边翻转——漏内收会让
  /// 扇环/整圆整体外漂（真机实证：文字命中与扇形错位、hub 半个圆被屏缘
  /// 裁掉）。
  static Offset anchorInPanel(Size panelSize, DialSide side, DialGeometry geo) {
    return Offset(
      side.mirrorX ? panelSize.width - geo.leafOuterRadius : geo.leafOuterRadius,
      side.mirrorY ? geo.hubRadius : panelSize.height - geo.hubRadius,
    );
  }

  @override
  State<FormatDial> createState() => _FormatDialState();
}

class _FormatDialState extends State<FormatDial>
    with TickerProviderStateMixin {
  // 三控制器（_enter/_exit/_dwell）→ 不能用 SingleTickerProviderStateMixin
  int? _stageCat; // null=根态；非 null=当前三级态的分类 index
  int? _innerHighlight;
  int? _leafHighlight;

  /// 三级反悔停留态（2026-10-04 拍板）：非 null = 该叶子已松手挂起待提交，
  /// [_dwell] 倒计时走完自动提交；期间再次按压/回根即反悔取消。
  int? _pendingLeaf;

  /// 二级直选反悔停留态（2026-10-05 拍板：直选类同样停留，防误触切档）。
  /// 与 [_pendingLeaf] 互斥（不同手势阶段）。
  int? _pendingCat;

  /// 提交脉冲态（feel.commitPulse）：selected 退场期保留的选中叶 index，
  /// 退场播完/再次按压清除。
  int? _commitLeaf;
  bool _dragging = false;
  bool _exiting = false;

  /// 双击加速（2026-10-05 拍板）：反悔窗口内再按同项 → 松手即跳过等待
  /// 立即提交（拖离原项自动解除回常规反悔流）。
  bool _doubleTapCommit = false;
  late final AnimationController _enter;
  late final AnimationController _exit;
  late final AnimationController _dwell;

  /// 三级叶子环错峰入场（换类/入三级时重放：延迟 stagger + 生长淡入）。
  late final AnimationController _leavesIn;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, duration: widget.spec.feel.enterDuration)
      ..forward();
    _exit = AnimationController(vsync: this, duration: widget.spec.feel.exitSoftDuration);
    _dwell = AnimationController(vsync: this, duration: widget.spec.feel.leafDwell)
      ..addListener(() {
        if (_dwell.isCompleted) _commitPending(notifyDismiss: true);
      });
    _leavesIn = AnimationController(vsync: this, duration: widget.spec.feel.enterDuration);
  }

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    _dwell.dispose();
    _leavesIn.dispose();
    super.dispose();
  }

  // ---------- 配置解引用 ----------

  DialGeometry get _geo => widget.spec.geometry;
  DialFeel get _feel => widget.spec.feel;
  DialMenu get _menu => widget.spec.menu;
  List<DialCategory> get _cats => _menu.categories;
  double get _innerR => _geo.innerRadius;
  double get _outerR => _geo.outerRadius;
  double get _leafR => _geo.leafOuterRadius;
  double get _sweep => _geo.sweepAngle;

  List<double> get _innerWeights => [
    for (final c in _cats) c.angleWeight,
  ];

  List<DialLeaf> get _leaves => _cats[_stageCat!].leaves;

  List<double> get _leafWeights => [for (final l in _leaves) l.angleWeight];

  bool get _inLeaves => _stageCat != null;

  /// 扇区禁用真值：静态 disabled 位 ∪ 宿主动态 disabledCategories。
  bool _catDisabled(int idx) =>
      _cats[idx].disabled ||
      (widget.disabledCategories?.contains(idx) ?? false);

  /// 禁用分类 index 集（painter 着色用）。
  Set<int> get _disabledCats => {
    for (var i = 0; i < _cats.length; i++)
      if (_catDisabled(i)) i,
  };

  /// 当前三级态对应的活动分类 index（根态 null）。
  /// 二级活动态回显（2026-10-04 拍板）：活动分类扇区持久着色区分其他二级。
  int? get _activeCategory => _stageCat;

  // ---------- 面板几何 ----------

  Size get _panelSize => FormatDial.panelSize(_geo);

  Offset _anchorOf(Size size) =>
      FormatDial.anchorInPanel(size, widget.side, _geo);

  // ---------- 手势状态机 ----------

  void _setInner(int? idx) {
    if (idx == _innerHighlight) return;
    setState(() => _innerHighlight = idx);
    if (idx != null && _feel.haptics) HapticFeedback.selectionClick();
  }

  void _setLeaf(int? idx) {
    if (idx == _leafHighlight) return;
    setState(() => _leafHighlight = idx);
    if (idx != null && _feel.haptics) HapticFeedback.selectionClick();
  }

  /// 双环态切类（三级随二级联动）：级联改写激活类与叶子内容，并触发宿主
  /// 键盘事件（2026-10-03 拍板：联动瞬间焦点拉回写作区）。根态入三级 /
  /// 双环态换类统一走此入口。叶子环错峰入场动画随每次换类重放。
  void _switchCategory(int categoryIdx) {
    setState(() {
      _stageCat = categoryIdx;
      _innerHighlight = categoryIdx;
      _leafHighlight = null;
    });
    _leavesIn.duration = _feel.enterDuration;
    _leavesIn.forward(from: 0);
    widget.onLeavesChanged?.call();
  }

  void _enterLeaf(int categoryIdx) {
    _switchCategory(categoryIdx);
    if (_feel.haptics) HapticFeedback.mediumImpact();
  }

  void _backToRoot() {
    _cancelDwell();
    setState(() {
      _stageCat = null;
      _innerHighlight = null;
      _leafHighlight = null;
    });
  }

  void _close() {
    _cancelDwell();
    _commitLeaf = null;
    _dragging = false;
    if (!mounted) return;
    setState(() {
      _stageCat = null;
      _innerHighlight = null;
      _leafHighlight = null;
    });
  }

  /// 三级反悔停留：叶子松手不立即生效（2026-10-04 拍板），挂起 + 倒计时；
  /// 窗口内用户再按压（[_onDown]）/滑回深处（[_backToRoot]）即反悔。
  void _armDwell(int idx) {
    _dwell.duration = _feel.leafDwell;
    setState(() => _pendingLeaf = idx);
    if (_feel.haptics) HapticFeedback.mediumImpact(); // 挂起确认震感
    _dwell.forward(from: 0);
  }

  /// 二级直选反悔停留（2026-10-05 拍板：直选切档同走窗口，防无聊点按误切）。
  void _armCategoryDwell(int idx) {
    _dwell.duration = _feel.leafDwell;
    setState(() {
      _pendingCat = idx;
      _innerHighlight = idx;
    });
    if (_feel.haptics) HapticFeedback.mediumImpact();
    _dwell.forward(from: 0);
  }

  void _cancelDwell() {
    _dwell.stop();
    if (_pendingLeaf == null && _pendingCat == null) return;
    _pendingLeaf = null;
    _pendingCat = null;
  }

  /// 挂起落地分发（倒计时走完 / 宿主打断视为确认）。
  void _commitPending({required bool notifyDismiss}) {
    if (_pendingLeaf != null && _stageCat != null) {
      final cat = _stageCat!;
      final idx = _pendingLeaf!;
      _pendingLeaf = null;
      _applyLeafNow(cat, idx, notifyDismiss: notifyDismiss);
    } else if (_pendingCat != null) {
      final idx = _pendingCat!;
      _pendingCat = null;
      _applyCategoryNow(idx, notifyDismiss: notifyDismiss);
    }
  }

  /// 倒计时走完（或停留停用时的松手）→ 提交叶子，语义落地在宿主。
  /// commitPulse 开启时保留三级态与选中叶高亮进入 selected 退场（微放大
  /// 随退场进度），关=立即回根态整体淡出。
  void _applyLeafNow(int catIdx, int leafIdx, {bool notifyDismiss = true}) {
    _cancelDwell();
    _dragging = false;
    if (_feel.haptics) HapticFeedback.lightImpact();
    final pulse = _feel.commitPulse;
    setState(() {
      _stageCat = pulse ? catIdx : null;
      _innerHighlight = pulse ? catIdx : null;
      _leafHighlight = pulse ? leafIdx : null;
      _commitLeaf = pulse ? leafIdx : null;
      _pendingLeaf = null;
    });
    widget.onLeafSelect(catIdx, leafIdx);
    if (notifyDismiss) {
      widget.onDismiss(DialDismissReason.selected); // 停留窗口走完，自动闭合
    }
  }

  /// 二级直选提交（直选类松手切档；pulse 同叶子口径：保留高亮进退场）。
  void _applyCategoryNow(int catIdx, {bool notifyDismiss = true}) {
    _cancelDwell();
    _dragging = false;
    if (_feel.haptics) HapticFeedback.lightImpact();
    setState(() {
      _innerHighlight = catIdx;
      _pendingCat = null;
    });
    widget.onCategorySelect(catIdx);
    if (notifyDismiss) {
      widget.onDismiss(DialDismissReason.selected);
    }
  }

  void _onDown(PointerDownEvent e) {
    if (_exiting) return; // 退场（含 commit pulse）期不再吃手势
    _commitLeaf = null;
    final size = context.size;
    if (size == null) return;
    _dragging = true;
    final p = e.localPosition;
    final anchor = _anchorOf(size);
    final inner = dialHitRingWeighted(
      p,
      anchor,
      side: widget.side,
      weights: _innerWeights,
      sweep: _sweep,
    );
    final leaf = dialHitRingWeighted(
      p,
      anchor,
      side: widget.side,
      weights: _inLeaves ? _leafWeights : const [],
      inner: _outerR,
      outer: _leafR,
      sweep: _sweep,
    );
    // 双击加速（2026-10-05 拍板）：反悔窗口内再按同项 = 跳过等待立即提交；
    // 挂起与倒计时原样保留（微动不解除，拖离即回常规流，见 _onMove）
    final sameLeaf = _pendingLeaf != null && _inLeaves && leaf == _pendingLeaf;
    final sameCat = _pendingCat != null && !_inLeaves && inner == _pendingCat;
    if (sameLeaf || sameCat) {
      _doubleTapCommit = true;
      if (sameLeaf) {
        _setLeaf(leaf);
      } else {
        _setInner(inner);
      }
      return;
    }
    _doubleTapCommit = false;
    // 反悔窗口内再按压 = 反悔（改选/放弃），挂起态即清
    _cancelDwell();
    if (!_inLeaves) {
      _setInner(inner);
    } else {
      _setLeaf(leaf);
      if (leaf == null) {
        _setInner(inner);
      }
    }
  }

  void _onMove(PointerEvent e) {
    if (!_dragging) return;
    if (_doubleTapCommit) {
      // 仍在原项上的微动不解除双击加速；拖离即回常规反悔流
      final size = context.size;
      var still = false;
      if (size != null) {
        final anchor = _anchorOf(size);
        if (_pendingLeaf != null && _inLeaves) {
          still =
              dialHitRingWeighted(
                e.localPosition,
                anchor,
                side: widget.side,
                weights: _leafWeights,
                inner: _outerR,
                outer: _leafR,
                sweep: _sweep,
              ) ==
              _pendingLeaf;
        } else if (_pendingCat != null && !_inLeaves) {
          still =
              dialHitRingWeighted(
                e.localPosition,
                anchor,
                side: widget.side,
                weights: _innerWeights,
                sweep: _sweep,
              ) ==
              _pendingCat;
        }
      }
      if (still) return;
      _doubleTapCommit = false;
      _cancelDwell();
    }
    final size = context.size;
    if (size == null) return;
    final p = e.localPosition;
    final anchor = _anchorOf(size);
    final r = (p - anchor).distance;
    // 死区深处（< backRadius）：三级态滑回根态
    if (_inLeaves && r < _geo.backRadius) {
      _backToRoot();
      return;
    }
    if (!_inLeaves) {
      final inner = dialHitRingHysteresisWeighted(
        p,
        anchor,
        side: widget.side,
        weights: _innerWeights,
        previous: _innerHighlight,
        sweep: _sweep,
        hysteresis: _feel.hysteresis,
      );
      _setInner(inner);
      // 向外环续滑（越过 L2 外缘 + fanoutOvershoot）即扇出三级，无需抬手
      if (inner != null &&
          r > _outerR + _geo.fanoutOvershoot &&
          _cats[inner].hasLeaves &&
          !_catDisabled(inner)) {
        _enterLeaf(inner);
      }
    } else {
      // 双环态：外环优先（叶子高亮），无叶子命中则内环分类跟随
      final leaf = dialHitRingHysteresisWeighted(
        p,
        anchor,
        side: widget.side,
        weights: _leafWeights,
        previous: _leafHighlight,
        inner: _outerR,
        outer: _leafR,
        sweep: _sweep,
        hysteresis: _feel.hysteresis,
      );
      _setLeaf(leaf);
      if (leaf == null) {
        final inner = dialHitRingHysteresisWeighted(
          p,
          anchor,
          side: widget.side,
          weights: _innerWeights,
          previous: _innerHighlight,
          sweep: _sweep,
          hysteresis: _feel.hysteresis,
        );
        final currentCat = _stageCat!;
        if (inner != null && !_cats[inner].hasLeaves) {
          // 滑到直选类（无三级）：收起外环回根态
          _backToRoot();
        } else if (inner != null &&
            inner != currentCat &&
            _cats[inner].hasLeaves &&
            !_catDisabled(inner)) {
          // 滑到别的分类：三级随二级联动即时换内容（无需收合重开）
          _switchCategory(inner);
        } else {
          _setInner(inner);
        }
      } else {
        _setInner(null);
      }
    }
  }

  void _onUp(PointerUpEvent e) {
    if (!_dragging) return;
    if (_exiting) {
      // 挂起倒计时在按住期间走完已提交并进入退场：本次抬手不再触发手势语义
      _dragging = false;
      return;
    }
    final size = context.size;
    final leaf = _leafHighlight;
    final inner = _innerHighlight;
    final stageCat = _stageCat;
    if (size != null) {
      final r = (e.localPosition - _anchorOf(size)).distance;
      // 死区/深处松手：根态收合、三级态回根
      if (r < _innerR) {
        if (!_inLeaves) {
          _close();
          widget.onDismiss(DialDismissReason.timeout); // 回撤=放弃：柔和收缩
        } else {
          _backToRoot();
        }
        return;
      }
    }
    if (!_inLeaves) {
      if (inner == null) {
        _close();
        widget.onDismiss(DialDismissReason.timeout); // 扇外空选松手 = 收合
      } else {
        final cat = _cats[inner];
        if (!cat.hasLeaves) {
          if (_doubleTapCommit && _pendingCat == inner) {
            _doubleTapCommit = false;
            _commitPending(notifyDismiss: true); // 双击同项：立即提交
          } else if (_feel.leafDwellEnabled) {
            // 直选类：停留停用才松手即生效；默认走反悔窗口（2026-10-05 拍板）
            _armCategoryDwell(inner);
          } else {
            _applyCategoryNow(inner);
            widget.onDismiss(DialDismissReason.selected); // 选完即闭合
          }
        } else if (_catDisabled(inner)) {
          setState(() => _innerHighlight = null); // 置灰不响应，保持展开
        } else {
          _enterLeaf(inner); // 快速 tap 分类：扇出三级等第二次手势
        }
      }
    } else if (leaf != null) {
      if (_doubleTapCommit && _pendingLeaf == leaf) {
        _doubleTapCommit = false;
        _commitPending(notifyDismiss: true); // 双击同叶：跳过等待立即提交
      } else if (_feel.leafDwellEnabled) {
        _armDwell(leaf); // 叶子松手 → 反悔停留（倒计时走完才提交）
      } else {
        _applyLeafNow(stageCat!, leaf); // 停留停用：松手即选
      }
    } else if (inner != null && _cats[inner].hasLeaves) {
      // 双环态点按（未拖动）L2 分类：切类并联动换三级（与拖动路径同口径）——
      // 此前点按只高亮不切类，真机感知为「二三级不能联动」
      if (inner != stageCat && !_catDisabled(inner)) {
        _switchCategory(inner);
      }
      // 原类重按：保持展开等下一次手势
    } else if (inner != null && !_cats[inner].hasLeaves) {
      // 双环态点直选类（无三级类）：收起外环回根态（2026-10-04 拍板）
      _backToRoot();
    }
    // 其余（内环分类高亮松手）：切类/保持展开，等下一次手势
  }

  void _onCancel(PointerCancelEvent e) => _close();

  @override
  void didUpdateWidget(covariant FormatDial old) {
    super.didUpdateWidget(old);
    _enter.duration = widget.spec.feel.enterDuration;
    // 宿主分级闭合（打字即收/失焦超时）：进入退场动画，播完交还宿主摘除
    if (widget.closing != null && old.closing == null && !_exiting) {
      // 2026-10-05 修正：打断反悔窗口（打字/失焦）= **强确认**——先落地
      // 挂起中的选择再退场，绝不作废（否则「选完立刻打字」高频流静默丢
      // 提交=真机实证「选了没效果」）。post-frame 落地：宿主正处 build
      // 期（onChanged→setState→rebuild），此刻反向回调宿主 setState 会
      // 触发 during-build 断言。
      if (_pendingLeaf != null || _pendingCat != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _commitPending(notifyDismiss: false);
        });
      } else {
        _cancelDwell(); // 无挂起：纯取消（原语义）
      }
      _exiting = true;
      _exit.duration = widget.closing == DialDismissReason.keyPressed
          ? widget.spec.feel.exitInstantDuration
          : widget.spec.feel.exitSoftDuration;
      _exit.forward().then((_) {
        if (mounted) {
          setState(() {
            _commitLeaf = null;
            _stageCat = null;
            _innerHighlight = null;
            _leafHighlight = null;
          });
          widget.onExitDone?.call();
        }
      });
    }
  }

  /// 三级叶子环错峰入场进度（0→1）：stagger 延迟作 Interval 前缀，余段
  /// easeOut 生长淡入（水波纹由内向外）。根态恒 0。
  double get _leafT {
    if (!_inLeaves) return 0;
    final enterMs = _feel.enterDuration.inMilliseconds;
    final begin = enterMs <= 0
        ? 0.0
        : (_feel.stagger.inMilliseconds / enterMs).clamp(0.0, 0.9);
    return CurvedAnimation(
      parent: _leavesIn,
      curve: Interval(begin, 1.0, curve: Curves.easeOut),
    ).value;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = _panelSize;
    final anchor = _anchorOf(size);
    final showLeaves = _inLeaves;
    // 完整路径回显（2026-10-04 拍板）：已生效格式的持久高亮由宿主直给
    //（appliedInner/appliedLeaf），组件按当前三级态取当前类的叶子回显。
    // 与悬停强高亮（primaryContainer 实色）分层：生效弱高亮（主色加粗）。
    final appliedLeafNow =
        (_inLeaves ? widget.appliedLeaf[_stageCat] : null) ?? const <int>{};
    // 入场：透明度 + 环带生长（0.7→1.0）——**不做整面板 ScaleTransition**，
    // hub 会跟着膨胀挤占 L2（真机实证）；退场：透明度极速/柔和分级
    final radiusScale = Tween(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _enter, curve: _feel.enterCurve),
    );
    final opacityAnim = _exiting
        ? CurvedAnimation(parent: _exit, curve: _feel.exitCurve).drive(
            Tween(begin: 1.0, end: 0.0),
          )
        : CurvedAnimation(parent: _enter, curve: Curves.easeOut);
    final disabledCats = _disabledCats;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: FadeTransition(
        opacity: opacityAnim,
        child: Listener(
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          // _leavesIn 驱动叶子环错峰入场（painter 半径 + 文字透明度同帧）
          child: AnimatedBuilder(
            animation: Listenable.merge([_enter, _dwell, _leavesIn]),
            builder: (context, _) {
              final leafT = _leafT;
              return Stack(
                children: [
                  // 环带 painter：入场随 _enter 生长（0.7→1.0），hub 恒定；
                  // _dwell 驱动反悔倒计时弧；_leavesIn 驱动叶子环错峰生长
                  CustomPaint(
                    size: size,
                    painter: _DialPainter(
                      stageCat: _stageCat,
                      innerHighlight: _innerHighlight,
                      leafHighlight: _leafHighlight,
                      side: widget.side,
                      disabledCats: disabledCats,
                      hubLabel: widget.currentLabel,
                      hubLit: widget.hubLit,
                      scheme: scheme,
                      radiusScale: _exiting ? 1.0 : radiusScale.value,
                      appliedInner: widget.appliedInner,
                      appliedLeaf: appliedLeafNow,
                      activeInner: _activeCategory,
                      dwellProgress:
                          _pendingLeaf != null || _pendingCat != null
                          ? _dwell.value
                          : null,
                      geo: _geo,
                      innerWeights: _innerWeights,
                      leafWeights: _inLeaves ? _leafWeights : const [],
                      leafRadiusScale: 0.85 + 0.15 * leafT,
                      leafOpacity: leafT,
                      pulseLeaf: _commitLeaf,
                      pulseT: _exiting ? _exit.value : 0,
                    ),
                  ),
                  // hub 盘面字：当前所选格式（默认正文；真实 Text 可被
                  // find.text 定位 + 无障碍可读）
                  _hubLabel(anchor, scheme),
                  // 扇区内容用真实 Text（或宿主 sectorBuilder 定制）：可被
                  // find.text 定位（widget 测试）+ 无障碍语义可读
                  for (var i = 0; i < _cats.length; i++)
                    _sectorItem(
                      anchor,
                      _innerWeights,
                      i,
                      ring: 0,
                      radius: (_innerR + _outerR) / 2,
                      label: _cats[i].label, // 盘面字恒定地标（2026-10-04
                          // 拍板：不再升级完整路径——叶子高亮+倒计时弧+
                          // 触觉已三重冗余，恒定标签胜过瞬时路径字）
                      highlighted: _innerHighlight == i && !_catDisabled(i),
                      applied: widget.appliedInner.contains(i),
                      dimmed: _catDisabled(i),
                    ),
                  if (showLeaves)
                    for (var i = 0; i < _leaves.length; i++)
                      _sectorItem(
                        anchor,
                        _leafWeights,
                        i,
                        ring: 1,
                        // 叶子文字随错峰环带同径生长（中径 × 叶环缩放）
                        radius: ((_outerR + _leafR) / 2) * (0.85 + 0.15 * leafT),
                        label: _leaves[i].label,
                        highlighted: _leafHighlight == i,
                        applied: appliedLeafNow.contains(i),
                        dimmed: false,
                        opacity: leafT,
                        // 提交脉冲：选中叶随退场进度微放大（1.0→1.15）
                        scale: i == _commitLeaf && _exiting
                            ? 1 + 0.15 * (1 - _exit.value)
                            : 1.0,
                      ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// hub 盘面字：当前所选格式（默认正文），圆心定位真实 Text。
  Widget _hubLabel(Offset anchor, ColorScheme scheme) {
    return Positioned(
      left: anchor.dx,
      top: anchor.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Text(
          widget.currentLabel,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: widget.hubLit ? scheme.onPrimaryContainer : scheme.onSurface,
          ),
        ),
      ),
    );
  }

  /// 扇区内容定位：扇区中角（按权重累计分数推得）、环带中径；内容走
  /// 宿主 sectorBuilder（null 回落默认文字 Text）。[opacity]/[scale] 供
  /// 叶子环错峰淡入与提交脉冲微放大（内环扇区用默认值 1.0）。
  Widget _sectorItem(
    Offset anchor,
    List<double> weights,
    int idx, {
    required int ring,
    required double radius,
    required String label,
    required bool highlighted,
    required bool applied,
    required bool dimmed,
    double opacity = 1.0,
    double scale = 1.0,
  }) {
    final uMid = dialSectorStarts(weights)[idx] + dialSectorFraction(weights, idx) / 2;
    // 扇区中角与 dialHitRingWeighted 同一映射：canonical（锚点右下）自
    // -180° 起递增趋向竖直，镜像象限翻转方向向量（index 0 恒贴水平）
    final mid = -math.pi + uMid * _sweep;
    final dir = Offset(
      widget.side.mirrorX ? -math.cos(mid) : math.cos(mid),
      widget.side.mirrorY ? -math.sin(mid) : math.sin(mid),
    );
    final pos = anchor + dir * radius;
    final content =
        _menu.sectorBuilder?.call(
          DialSectorContext(
            ring: ring,
            index: idx,
            label: label,
            highlighted: highlighted,
            applied: applied,
            dimmed: dimmed,
          ),
        ) ??
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: highlighted || applied
                ? FontWeight.w700
                : FontWeight.w600,
            color: dimmed
                ? Theme.of(context).colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  )
                : highlighted
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : applied
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurface,
          ),
        );
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Opacity(
          opacity: opacity,
          child: scale == 1.0
              ? content
              : Transform.scale(scale: scale, child: content),
        ),
      ),
    );
  }
}

/// 扇形绘制：内环分类 +（三级态）外环叶子扇环，锚点角 [sweep] 扇弧。
/// 几何全部经 [DialGeometry] 注入（与命中函数同一映射）。
class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.stageCat,
    required this.innerHighlight,
    required this.leafHighlight,
    required this.side,
    required this.disabledCats,
    required this.hubLabel,
    required this.hubLit,
    required this.scheme,
    this.radiusScale = 1.0,
    this.appliedInner = const {},
    this.appliedLeaf = const {},
    this.activeInner,
    this.dwellProgress,
    required this.geo,
    required this.innerWeights,
    required this.leafWeights,
    this.leafRadiusScale = 1.0,
    this.leafOpacity = 1.0,
    this.pulseLeaf,
    this.pulseT = 0,
  });

  /// 三级态激活分类 index（null=根态）。
  final int? stageCat;
  final int? innerHighlight;
  final int? leafHighlight;
  final DialSide side;

  /// 禁用分类 index 集（静态位 ∪ 动态置灰）。
  final Set<int> disabledCats;

  /// hub 盘面字（仅用于点亮色判断配套的语义位，绘制走 Text widget）。
  final String hubLabel;

  /// hub 点亮态（有激活格式 → primaryContainer）。
  final bool hubLit;

  final ColorScheme scheme;

  /// 扇环生长系数（入场 0.7→1.0）：环带从内向外展开，**hub 恒定不缩放**
  ///——整面板 ScaleTransition 会让 hub 膨胀挤占 L2（真机实证）。
  final double radiusScale;

  /// 已生效（非悬停）持久高亮：L2 分类索引集 / 三级叶子索引集——选中路径
  /// 回显，用户始终看得到「当前在什么上」（悬停强高亮、生效弱高亮叠加）。
  final Set<int> appliedInner;
  final Set<int> appliedLeaf;

  /// 三级态活动分类：secondaryContainer 持久着色，与其他二级扇区一眼区分
  ///（2026-10-04 拍板：二级选中即变装显路径）。
  final int? activeInner;

  /// 三级反悔倒计时进度（0→1，null=无挂起）：hub 外缘弧随时间填充。
  final double? dwellProgress;

  final DialGeometry geo;
  final List<double> innerWeights;
  final List<double> leafWeights;

  /// 叶子环错峰入场：相对缩放（0.85→1.0）与淡入透明度（feel.stagger）。
  final double leafRadiusScale;
  final double leafOpacity;

  /// 提交脉冲：selected 退场期保留高亮并加亮的选中叶 index + 退场进度
  ///（0→1，用于加亮强度随退场衰减）。
  final int? pulseLeaf;
  final double pulseT;

  double get _hubR => geo.hubRadius;
  double get _innerR => geo.innerRadius;
  double get _outerR => geo.outerRadius;
  double get _leafR => geo.leafOuterRadius;
  double get _sweep => geo.sweepAngle;

  @override
  void paint(Canvas canvas, Size size) {
    // 与 FormatDial.anchorInPanel 同一口径：面板矩形已为 hub 完整圆外扩，
    // 锚点按象限内收——漏内收会让扇环/整圆整体外漂（真机实证：文字命中
    // 与扇形错位、hub 半个圆被屏缘裁掉）
    final anchor = FormatDial.anchorInPanel(size, side, geo);
    // 内整圆 hub（格式按钮本体）：先画满圆，环带扇形后画压边即无缝
    canvas.drawCircle(
      anchor,
      _hubR,
      Paint()
        ..color = hubLit ? scheme.primaryContainer : scheme.surfaceContainerHigh
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      anchor,
      _hubR,
      Paint()
        ..color = hubLit ? scheme.primary : scheme.outlineVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    // 三级反悔倒计时弧（挂起态）：hub 外缘随 leafDwell 顺时针填满，
    // 走完即提交——用户可读的「反悔窗口剩余量」
    if (dwellProgress != null) {
      canvas.drawArc(
        Rect.fromCircle(center: anchor, radius: _hubR + 3),
        -math.pi / 2,
        2 * math.pi * dwellProgress!,
        false,
        Paint()
          ..color = scheme.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
    // 内环：分类（radiusScale 只作用于环带，hub 恒定不缩放）。环带在
    // canonical 象限绘制后按侧镜像（负 scale 翻转弧域，圆与文字不在
    // 变换内不受影响）；倒计时弧在变换外恒为顺时针
    canvas.save();
    canvas.translate(anchor.dx, anchor.dy);
    canvas.scale(side.mirrorX ? -1 : 1, side.mirrorY ? -1 : 1);
    canvas.translate(-anchor.dx, -anchor.dy);
    _paintRing(
      canvas,
      anchor,
      weights: innerWeights,
      inner: _innerR * radiusScale,
      outer: _outerR * radiusScale,
      highlight: innerHighlight,
      disabled: disabledCats,
      filled: stageCat != null,
      active: activeInner,
    );
    // 外环：三级叶子（仅三级态；两环同显——真机拍板）。错峰入场：半径
    // 随 leafRadiusScale 生长、填色随 leafOpacity 淡入；脉冲叶加亮
    if (stageCat != null) {
      _paintRing(
        canvas,
        anchor,
        weights: leafWeights,
        inner: _outerR * radiusScale * leafRadiusScale,
        outer: _leafR * radiusScale * leafRadiusScale,
        highlight: leafHighlight,
        disabled: const {},
        filled: false,
        active: null,
        opacity: leafOpacity,
        pulse: pulseLeaf,
      );
    }
    canvas.restore();
  }

  void _paintRing(
    Canvas canvas,
    Offset anchor, {
    required List<double> weights,
    required double inner,
    required double outer,
    required int? highlight,
    required Set<int> disabled,
    required bool filled,
    required int? active,
    double opacity = 1.0,
    int? pulse,
  }) {
    final starts = dialSectorStarts(weights);
    for (var i = 0; i < weights.length; i++) {
      final frac = dialSectorFraction(weights, i);
      final isDisabled = disabled.contains(i);
      final highlighted = highlight == i && !isDisabled;
      final isActive = active == i && !isDisabled;
      final isPulse = pulse == i && !isDisabled;
      // 扇区角域与 dialHitRingWeighted 同一映射（index 0 贴水平，递增
      // 趋向竖直）：paint 在 canonical 象限进行（自 -180° 起正向扫），
      // 镜像象限由外层 canvas 负 scale 翻转，此处恒用 canonical 公式
      final sweepI = frac * _sweep;
      final sectorStart = -math.pi + starts[i] * _sweep;
      final path = Path()
        ..arcTo(
          Rect.fromCircle(center: anchor, radius: outer),
          sectorStart,
          sweepI,
          false,
        )
        ..arcTo(
          Rect.fromCircle(center: anchor, radius: inner),
          sectorStart + sweepI,
          -sweepI,
          false,
        )
        ..close();
      final fill = isDisabled
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
          : isPulse
          ? scheme.primary // 提交脉冲：选中叶加亮至主色实底
          : highlighted
          ? scheme.primaryContainer
          : isActive
          ? scheme.secondaryContainer // 活动分类：异色持久区分同级
          : scheme.surfaceContainerHigh;
      final stroke = isDisabled
          ? scheme.outlineVariant.withValues(alpha: 0.4)
          : isPulse
          ? scheme.primary
          : highlighted
          ? scheme.primary
          : isActive
          ? scheme.secondary
          : scheme.outlineVariant;
      if (opacity < 1) {
        // 错峰入场淡入：填/描色按叶环透明度衰减（不影响内环）
        canvas.drawPath(
          path,
          Paint()
            ..color = fill.withValues(alpha: fill.a * opacity)
            ..style = PaintingStyle.fill,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = stroke.withValues(alpha: stroke.a * opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        continue;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = fill
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.stageCat != stageCat ||
      old.innerHighlight != innerHighlight ||
      old.leafHighlight != leafHighlight ||
      old.side != side ||
      old.disabledCats != disabledCats ||
      old.scheme != scheme ||
      old.activeInner != activeInner ||
      old.dwellProgress != dwellProgress ||
      old.appliedInner != appliedInner ||
      old.appliedLeaf != appliedLeaf ||
      old.geo != geo ||
      old.radiusScale != radiusScale ||
      old.hubLit != hubLit ||
      old.innerWeights != innerWeights ||
      old.leafWeights != leafWeights ||
      old.leafRadiusScale != leafRadiusScale ||
      old.leafOpacity != leafOpacity ||
      old.pulseLeaf != pulseLeaf ||
      old.pulseT != pulseT;
}
