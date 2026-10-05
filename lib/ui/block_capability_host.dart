import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/capability.dart';
import '../ai/capability_chain.dart';
import '../ai/workflow.dart' show WorkflowStep, workflowFor;
import '../share/attachments.dart' show resolveLocalMediaSrc;
import 'block_capability_page.dart';
import 'block_workflow_page.dart';
import 'image_viewer.dart';
import 'workflow_track.dart' show BlockArtifactsView;

/// 触发方式（detail-two-zone.md §5.1 拍板 2026-10-01：按块类型分派）。
enum BlockCapabilityTrigger {
  /// 选区菜单入口（文本载体块）：**无常驻图标**——2026-10-01 二次改版，
  /// 常驻 ✨ 的入口密度 = 块密度（一行文本也是一个块），长文图标泛滥；
  /// 改为划词后由系统选字菜单追加「AI 处理本段」项，入口随选区走，
  /// 与系统选字长按不抢手势（菜单项只做追加）。
  selection,

  /// 长按唤出（媒体块）：阅读态零 AI 图标，长按=能力页（+触觉）。
  /// 媒体块需先退出选区容器——SelectionArea 会吃掉长按弹系统选字菜单
  /// （真机实测），图片非文本，退出无选择能力损失。
  longPress,
}

/// 块锚点（注册表条目）：一个已渲染、可承载能力的块。
class BlockAnchor {
  const BlockAnchor({
    required this.kind,
    required this.preview,
    this.anchorLabel,
    this.previewFile,
    this.previewUrl,
  });

  /// 块类型（决定三级页能力链内容）。
  final BlockKind kind;

  /// 三级页顶部资源预览（复用已渲染块实例）。
  final Widget preview;

  /// 能力页来源锚点文案（「来自：代码块」等）。
  final String? anchorLabel;

  /// 预览激活源（图片块点按全屏查看）。
  final String? previewFile;
  final String? previewUrl;
}

/// 块锚点注册中心：Host 注册自身几何，选区菜单按锚点坐标反查命中块。
///
/// 存在的理由（detail-two-zone.md §5.1 二次改版）：入口从「每块一个常驻
/// 图标」退到「一个选区菜单项」后，菜单必须知道选区落在哪个块——本表是
/// 这唯一的几何桥梁。无状态外泄：宿主 dispose（滑出视口）即注销。
class BlockAnchorStore {
  final Map<Object, _AnchorEntry> _entries = {};

  /// 注册 / 更新（同 token 覆盖）。[context] 用于量取块矩形。
  void register(Object token, BlockAnchor anchor, BuildContext context) {
    _entries[token] = _AnchorEntry(anchor: anchor, context: context);
  }

  void unregister(Object token) => _entries.remove(token);

  /// 命中测试：[globalPosition]（选区菜单锚点的全局坐标）落在哪个块。
  ///
  /// - 纵向落在块矩形内 → 取**高度最小**的那块（嵌套块取最内层）；
  /// - 落在块间空隙 → 取纵向最近的块，超过 [tolerance] 判为未命中（避免
  ///   在图文交界处误判到远处的块）。
  BlockAnchor? hitTest(Offset globalPosition, {double tolerance = 48}) {
    BlockAnchor? inside;
    var insideHeight = double.infinity;
    BlockAnchor? nearest;
    var nearestDistance = double.infinity;
    for (final entry in _entries.values) {
      final rect = _rectOf(entry.context);
      if (rect == null) continue;
      if (rect.top <= globalPosition.dy && globalPosition.dy <= rect.bottom) {
        if (rect.height < insideHeight) {
          inside = entry.anchor;
          insideHeight = rect.height;
        }
        continue;
      }
      final distance = globalPosition.dy < rect.top
          ? rect.top - globalPosition.dy
          : globalPosition.dy - rect.bottom;
      if (distance < nearestDistance) {
        nearest = entry.anchor;
        nearestDistance = distance;
      }
    }
    return inside ?? (nearestDistance <= tolerance ? nearest : null);
  }

  Rect? _rectOf(BuildContext context) {
    final obj = context.findRenderObject();
    if (obj is! RenderBox || !obj.attached || !obj.hasSize) return null;
    return obj.localToGlobal(Offset.zero) & obj.size;
  }
}

class _AnchorEntry {
  const _AnchorEntry({required this.anchor, required this.context});

  final BlockAnchor anchor;
  final BuildContext context;
}

/// 注册中心作用域：详情页正文包一层，Host 与选区菜单经 context 取同一实例。
class BlockAnchorRegistry extends InheritedWidget {
  const BlockAnchorRegistry({
    super.key,
    required this.store,
    required super.child,
  });

  final BlockAnchorStore store;

  /// 取注册中心（不建立依赖：实例恒定，Host 无需因其变化重建）。
  static BlockAnchorStore? storeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BlockAnchorRegistry>()?.store;

  @override
  bool updateShouldNotify(BlockAnchorRegistry oldWidget) => false;
}

/// 区块能力外壳（detail-two-zone.md §5.1 二次改版 2026-10-01）：按块类型
/// 分派触发——文本块无常驻图标，经划词后的选区菜单项进三级能力页；媒体块
/// 长按唤出（无常驻图标，阅读态零 AI）。两者都直进三级能力页（单入口，
/// 能力清单菜单层已废除）；块本体手势不动（媒体点按播放/预览、文本块系统
/// 选字）。
///
/// - **抽象到位、注册从简**：块类型是编译期封闭集合，静态 switch 分发，
///   不做动态 Registry；
/// - **无障碍**：选区菜单项是真实按钮节点；触发配 `HapticFeedback.lightImpact()`。
class BlockCapabilityHost extends StatefulWidget {
  const BlockCapabilityHost({
    super.key,
    required this.kind,
    required this.child,
    this.anchorLabel,
    this.trigger = BlockCapabilityTrigger.selection,
    this.previewFile,
    this.previewUrl,
    this.blockKey,
  });

  /// 被包裹的已渲染块（buildRichBlock 产出）。
  final Widget child;

  /// 块类型（决定三级页能力链内容）。
  final BlockKind kind;

  /// 行内块 key（媒体行 `local://` 路径，块附件通道 §2.1）：非空 = 长按进
  /// **工作流页**（产物落 block_artifacts，续跑/锚点切换）；null = 条目级链
  /// （顶级媒体区/文本块，现行链式卡）。
  final String? blockKey;

  /// 能力页来源锚点文案（「来自：图片第 N 块」等）。
  final String? anchorLabel;

  /// 预览激活源（图片块点按全屏查看，2026-10-03 拍板）：本地文件路径或
  /// 网络 url 二选一；都空 = 预览不可激活。
  final String? previewFile;
  final String? previewUrl;

  final BlockCapabilityTrigger trigger;

  @override
  State<BlockCapabilityHost> createState() => _BlockCapabilityHostState();
}

class _BlockCapabilityHostState extends State<BlockCapabilityHost> {
  BlockAnchorStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRegistration();
  }

  @override
  void didUpdateWidget(BlockCapabilityHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRegistration(); // child 变了 → 预览实例同步更新
  }

  @override
  void dispose() {
    _store?.unregister(this); // 滑出视口即注销，不驻留
    super.dispose();
  }

  void _syncRegistration() {
    if (widget.trigger != BlockCapabilityTrigger.selection) return;
    final store = BlockAnchorRegistry.storeOf(context);
    if (store != _store) {
      _store?.unregister(this);
      _store = store;
    }
    store?.register(
      this,
      BlockAnchor(
        kind: widget.kind,
        preview: widget.child,
        anchorLabel: widget.anchorLabel,
        previewFile: widget.previewFile,
        previewUrl: widget.previewUrl,
      ),
      context,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.trigger == BlockCapabilityTrigger.longPress) {
      return SelectionContainer.disabled(
        child: GestureDetector(
          // translucent：整块矩形都响应长按（全宽热区原则，媒体块矮控件
          // 不要求精准按住）；点按不受影响照常下传子级（播放/预览）。
          behavior: HitTestBehavior.translucent,
          onLongPress: () => openBlockCapability(
            context,
            kind: widget.kind,
            anchorLabel: widget.anchorLabel,
            preview: widget.child,
            previewFile: widget.previewFile,
            previewUrl: widget.previewUrl,
            blockKey: widget.blockKey,
          ),
          child: widget.child,
        ),
      );
    }
    // 选区触发：无常驻入口，纯透传（正文零图标占用）。
    return widget.child;
  }
}

/// 唤出三级能力页（选区菜单项 / 媒体块长按共用的唯一出口）。
///
/// 接线分叉（block-artifact-workflow.md §4「结构保留只换芯」）：
/// - [blockKey] 非空 **且** Executor 提供块通道四回调 → **工作流页**
///   （BlockWorkflowPage：产物读写走 block_artifacts，续跑/Reset/应用/导出）；
/// - 否则走条目级链式卡（顶级媒体区/文本块/未注入块通道的场景，现行行为）。
Future<void> openBlockCapability(
  BuildContext context, {
  required BlockKind kind,
  String? anchorLabel,
  Widget? preview,
  String? previewFile,
  String? previewUrl,
  String? blockKey,
}) async {
  HapticFeedback.lightImpact();
  final executor = BlockCapabilityExecutor.maybeOf(context);
  if (executor == null) return; // 无执行作用域（如独立预览）不进页
  final chain = CapabilityChain(capabilitiesFor(kind))..init();
  final previewActivate = previewFile == null && previewUrl == null
      ? null
      : () => showImageFullScreen(
          context,
          file: previewFile == null
              ? null
              : File(resolveLocalMediaSrc(previewFile)),
          networkUrl: previewUrl,
        );
  // 块附件通道：块 key + Executor 块回调齐备 → 工作流页（§4 换芯）
  if (blockKey != null &&
      executor.loadBlockArtifacts != null &&
      executor.onRunWorkflowStep != null &&
      executor.onApplyArtifact != null &&
      executor.resetBlock != null) {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => BlockWorkflowPage(
          kind: kind,
          blockKey: blockKey,
          spec: workflowFor(kind),
          anchorLabel: anchorLabel,
          preview: preview,
          onPreviewActivate: previewActivate,
          loadArtifacts: executor.loadBlockArtifacts!,
          onRunStep: executor.onRunWorkflowStep!,
          onApplyArtifact: executor.onApplyArtifact!,
          onReset: executor.resetBlock!,
          onRunStandalone: executor.onRunStandalone,
          onCueSeek: executor.onCueSeek,
          onEditArtifact: executor.onEditArtifact,
        ),
      ),
    );
    return;
  }
  await showBlockCapabilityPage(
    context,
    kind: kind,
    chain: chain,
    anchorLabel: anchorLabel,
    preview: preview,
    onPreviewActivate: previewActivate,
    initialOutputs: executor.loadPersistedOutputs(),
    onRunStep: executor.onRunStep,
    onReset: executor.onReset,
    onEditOutput: executor.onEditOutput,
    onApply: executor.onApply,
    onRunStandalone: executor.onRunStandalone,
  );
}

/// 划词菜单构造（detail-two-zone.md §5.1 四版：**文本块唯一 AI 入口**）。
///
/// 在系统选字菜单项之后追加「AI 处理本段」——命中块由 [BlockAnchorStore]
/// 按菜单锚点反查；**未命中就不追加**，退回纯净系统菜单（杜绝「看得见
/// 点了没反应」的死项）。
///
/// [pageContext] 必须是页面树内的 context：builder 给的 context 在 Overlay
/// 里，取不到 [BlockCapabilityExecutor] 与 [BlockAnchorRegistry]。
Widget buildBlockCapabilityMenu(
  BuildContext pageContext,
  SelectableRegionState state,
) {
  final items = [...state.contextMenuButtonItems];
  final anchor = BlockAnchorRegistry.storeOf(pageContext)
      ?.hitTest(state.contextMenuAnchors.primaryAnchor);
  if (anchor != null) {
    items.add(
      ContextMenuButtonItem(
        label: 'AI 处理本段',
        onPressed: () {
          ContextMenuController.removeAny();
          openBlockCapability(
            pageContext,
            kind: anchor.kind,
            anchorLabel: anchor.anchorLabel,
            preview: anchor.preview,
            previewFile: anchor.previewFile,
            previewUrl: anchor.previewUrl,
          );
        },
      ),
    );
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}

/// 块渲染 → 能力外壳的统一入口（静态 switch，无注册表）。
Widget wrapWithCapabilityHost(
  Widget rendered, {
  required BlockKind kind,
  String? anchorLabel,
  BlockCapabilityTrigger trigger = BlockCapabilityTrigger.selection,
  String? previewFile,
  String? previewUrl,
  String? blockKey,
}) {
  return BlockCapabilityHost(
    kind: kind,
    anchorLabel: anchorLabel,
    trigger: trigger,
    previewFile: previewFile,
    previewUrl: previewUrl,
    blockKey: blockKey,
    child: rendered,
  );
}

/// 区块能力执行作用域（接线桥）：详情页提供真命令回调，选区菜单项/媒体
/// 长按/三级页经 context 取用——buildRichBlock 深处的块拿不到页面参数，
/// InheritedWidget 下传（detail-two-zone.md §5.2 能力对象 command() 出口
/// 对接命令层）。
class BlockCapabilityExecutor extends InheritedWidget {
  const BlockCapabilityExecutor({
    super.key,
    required this.onRunStep,
    required this.onReset,
    required this.onApply,
    required this.onEditOutput,
    required this.onRunStandalone,
    required this.loadPersistedOutputs,
    this.loadBlockArtifacts,
    this.onRunWorkflowStep,
    this.onApplyArtifact,
    this.resetBlock,
    this.onCueSeek,
    this.onEditArtifact,
    required super.child,
  });

  /// 执行链中某步（组装真命令入队，完成后回传产出文本；null=无产出按失败停步）。
  final Future<String?> Function(ContentCapability step) onRunStep;

  /// Reset：清该块已落库产物。
  final Future<void> Function() onReset;

  /// 回注：目标 + 文本（追加从属块/替换原块/发送灵感区，调用方落库）。
  final Future<void> Function(ReinjectTarget target, String text) onApply;

  /// 打开覆盖态编辑页（三级文本页），返回修订文本（null=取消）。
  final Future<String?> Function(String raw) onEditOutput;

  /// 独立能力执行（分类/条码/分析入队命令；切片打开工具流）。
  final Future<void> Function(String capabilityId) onRunStandalone;

  /// 读该块已落库产出（中断续跑 restore 数据源）。
  final Map<int, String> Function() loadPersistedOutputs;

  // ---- 块附件通道（workflow-track 接线，block-artifact-workflow.md §4）----
  // 四者齐备（详情页注入）时行内媒体块长按进工作流页；任一为 null = 该页面
  // 场景不支持块通道（如独立预览），保持条目级链路径。

  /// 读该块产物视图（工作流轨数据源，§3.3 续跑判定的唯一事实源）。
  final Future<BlockArtifactsView> Function(String blockKey)? loadBlockArtifacts;

  /// 执行工作流步骤（组装 block 命令入队 → 等任务落定 → 按产物判成功）。
  final Future<bool> Function(WorkflowStep step, String blockKey, String? sourceKind)?
      onRunWorkflowStep;

  /// 产物应用（回注：就近插入源媒体行正下方 / 灵感区，§3.4 动词体系）。
  final Future<void> Function(String blockKey, String kind, String text)? onApplyArtifact;

  /// Reset 该块全部产物（表行 + 文件产物删盘，§2.2 纪律 7）。
  final Future<void> Function(String blockKey)? resetBlock;

  /// §3.5 跳帧联动：字幕 cue 点句 → 宿主打开播放器定位该句起点播放。
  final void Function(String blockKey, int cueIndex)? onCueSeek;

  /// §4 文本产物修订：宿主打开编辑页，修订文本 upsert 回 block_artifacts
  ///（保 filePath/meta）。
  final Future<String?> Function(String blockKey, String kind, String currentText)?
      onEditArtifact;

  static BlockCapabilityExecutor? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BlockCapabilityExecutor>();

  @override
  bool updateShouldNotify(BlockCapabilityExecutor oldWidget) => false;
}
