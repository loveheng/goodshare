import 'package:flutter/material.dart';

import '../../models/item.dart';

/// 条目动作词汇表（card-batch-selection.md §3.2/§3.4）：全 app 条目动作的
/// **唯一规则声明处**。列表批量菜单（组合D）/ 详情页底栏 / `⋯` 功能面板
/// 各自挑子集渲染；条件收录（机器码仅开关开、Vault 上下文可移出）、文案
/// 切换（移入/移出保险箱、置顶/取消）、危险态在这里判定——改一处两端
/// 生效，杜绝同一动作两套手写实现的规则漂移。
///
/// 执行不进声明：规则层只产出 [ItemAction]（onInvoke 闭包由调用场景注入
/// 执行通道——详情页单条 `execute` / 列表批量 `executeAll`）。呈现层
/// （底栏/面板/批量操作栏）只消费 icon/label/danger/checked，不写规则。

/// 动作判定上下文：调用场景的条目快照 + 页面态（只读快照，判定无副作用）。
class ItemActionContext {
  const ItemActionContext({
    required this.item,
    this.inVaultView = false,
    this.vaultContext = false,
    this.machineModeEnabled = false,
    this.machineMode = false,
  });

  final InboxItem item;

  /// 列表处于保险箱视图（组合D 裁剪用；详情页恒 false）。
  final bool inVaultView;

  /// 详情页具备 Vault 上下文（从保险箱进入，可移出）。
  final bool vaultContext;

  final bool machineModeEnabled;
  final bool machineMode;
}

/// 词汇表条目：声明 + 规则判定结果 + 场景注入的执行闭包。
class ItemAction {
  const ItemAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.onInvoke,
    this.danger = false,
    this.checked,
    this.grouped = false,
  });

  final String id;
  final IconData icon;
  final String label;

  /// 场景注入的执行通道（单条命令 / 批量命令 / 纯 UI 回调统一走此口）。
  final Future<void> Function() onInvoke;

  /// 危险动作：呈现层红字呈现；二次确认在 onInvoke 内部（规则：删除类必确认）。
  final bool danger;

  /// 勾选态（机器码开关类）；null = 非开关型。
  final bool? checked;

  /// 是否并入连接按钮组（`⋯` 溢出面板内同类开关连成一个整体胶囊的呈现提示）。
  final bool grouped;
}

/// 批量操作栏动作规格（呈现层数据，规则产出见 [ItemActions.selectionBar]）。
class SelectionActionSpec {
  const SelectionActionSpec({
    required this.id,
    required this.icon,
    required this.label,
    this.danger = false,
  });

  final String id;
  final IconData icon;
  final String label;
  final bool danger;
}

/// 词汇表规则源：静态工厂即规则本体，禁止在页面/呈现层复刻这些判定。
abstract final class ItemActions {
  /// 保险箱：未入箱恒可入；已入箱需 vaultContext 或处于保险箱视图方可移出。
  /// 文案随状态切换。不可用返回 null（呈现层不渲染）。
  static ItemAction? vault(
    ItemActionContext ctx, {
    required Future<void> Function(bool on) run,
    bool grouped = false,
  }) {
    final on = !ctx.item.isVault;
    if (!on && !ctx.vaultContext && !ctx.inVaultView) return null;
    return ItemAction(
      id: 'set_vault',
      icon: Icons.lock_outline,
      label: on ? '移入保险箱' : '移出保险箱',
      onInvoke: () => run(on),
      grouped: grouped,
    );
  }

  /// 置顶 / 取消置顶（set_pin，schema v18）：文案随状态，无隐私语义，UI/AI 同权。
  static ItemAction pin(
    ItemActionContext ctx, {
    required Future<void> Function(bool on) run,
  }) =>
      ItemAction(
        id: 'set_pin',
        icon: Icons.push_pin_outlined,
        label: ctx.item.isPinned ? '取消置顶' : '置顶',
        onInvoke: () => run(!ctx.item.isPinned),
      );

  /// 删除（软删，30 天回收站）：危险态；二次确认由 onInvoke（页面 _confirmDelete /
  /// 批量场景的数量确认弹窗）承担——确认形态随场景，删除必确认的规则不变。
  static ItemAction delete(
    ItemActionContext ctx, {
    required Future<void> Function() onConfirm,
    bool grouped = false,
  }) =>
      ItemAction(
        id: 'delete',
        icon: Icons.delete_outline,
        label: '删除',
        danger: true,
        onInvoke: onConfirm,
        grouped: grouped,
      );

  /// 分享（纯 UI 回调：非 ItemCommand，词汇表允许回调型动作）。
  static ItemAction share(
    ItemActionContext ctx, {
    required Future<void> Function() onShare,
    bool grouped = false,
  }) =>
      ItemAction(
        id: 'share',
        icon: Icons.share_outlined,
        label: '分享',
        onInvoke: onShare,
        grouped: grouped,
      );

  /// 机器态开关：仅调试开关开启时收录（条件收录规则收口于此）。
  static ItemAction? machineMode(
    ItemActionContext ctx, {
    required VoidCallback onToggle,
    bool grouped = false,
  }) {
    if (!ctx.machineModeEnabled) return null;
    return ItemAction(
      id: 'machine_mode',
      icon: Icons.terminal_outlined,
      label: '机器码',
      checked: ctx.machineMode,
      onInvoke: () async => onToggle(),
      grouped: grouped,
    );
  }

  /// 工作区（加入/移出由页面选择器分流；Vault 条目被动作层拒绝的提示规则在动作层）。
  static ItemAction workspace(
    ItemActionContext ctx, {
    required Future<void> Function() onOpen,
  }) =>
      ItemAction(id: 'workspace', icon: Icons.workspaces_outlined, label: '工作区', onInvoke: onOpen);

  /// 重新处理（reprocess，2026-10-05 转正回 UI，推翻 2026-10-02 摘除拍板）：
  /// 仅管线有真实动作的类型收录（image=重跑 OCR / url=重抓正文 / chatlog=重
  /// 解析）；音/视频走专用「转写」入口、便签/文档无管线，收录即死项不渲染。
  /// 「重置为原文再重跑」的确认由页面承担（主动重做会覆盖现正文，memory §173）。
  static ItemAction? reprocess(
    ItemActionContext ctx, {
    required Future<void> Function() run,
  }) {
    const eligible = {
      InboxItem.typeImage,
      InboxItem.typeUrl,
      InboxItem.typeChatlog,
    };
    if (!eligible.contains(ctx.item.itemType)) return null;
    return ItemAction(
      id: 'reprocess',
      icon: Icons.autorenew_outlined,
      label: '重新处理',
      onInvoke: run,
    );
  }

  /// 重分类（reclassify，2026-10-05 转正；同日拍板「方向二」人工全放开）：
  /// 类型与标签同属用户权威元数据，UI 对全部条目收录「重分类…」选择器入口；
  /// AI 客户端白名单仍在动作层 `_reclassifyError`（仅 image→document）。
  /// 目标选择与「媒体→文本」后果确认由页面承担。
  static ItemAction reclassify(
    ItemActionContext ctx, {
    required Future<void> Function() run,
  }) =>
      ItemAction(
        id: 'reclassify',
        icon: Icons.category_outlined,
        label: '重分类…',
        onInvoke: run,
      );

  /// 对 AI 可见（ai-visibility v20）：人类笔记默认不可见；开启后 AI（MCP）方可读取。
  /// 仅人类笔记可切换（AI 自身笔记恒可见，无需开关）。
  static ItemAction? aiVisible(
    ItemActionContext ctx, {
    required Future<void> Function(bool on) run,
    bool grouped = false,
  }) {
    if (ctx.item.author == InboxItem.authorAi) return null;
    return ItemAction(
      id: 'set_ai_visible',
      icon: Icons.visibility_outlined,
      label: ctx.item.aiVisible ? '对 AI 可见（已开）' : '对 AI 可见（已关）',
      checked: ctx.item.aiVisible,
      onInvoke: () => run(!ctx.item.aiVisible),
      grouped: grouped,
    );
  }

  /// 允许 AI 编辑（ai-visibility v20）：人类笔记默认不可编辑；开启即人类对 AI 的静态同意。
  /// 仅人类笔记可切换（AI 自身笔记恒可编辑）。开关仅 UI 可改（动作层强制 actor=ui）。
  static ItemAction? aiEditable(
    ItemActionContext ctx, {
    required Future<void> Function(bool on) run,
    bool grouped = false,
  }) {
    if (ctx.item.author == InboxItem.authorAi) return null;
    return ItemAction(
      id: 'set_ai_editable',
      icon: Icons.edit_note_outlined,
      label: ctx.item.aiEditable ? '允许 AI 编辑（已开）' : '允许 AI 编辑（已关）',
      checked: ctx.item.aiEditable,
      onInvoke: () => run(!ctx.item.aiEditable),
      grouped: grouped,
    );
  }

  /// `⋯` 功能面板的动作序列：权限开关类（保险箱 / 对AI可见 / 允许AI编辑 /
  /// 机器码）连成连接按钮组；纠错类（重新处理 / 重分类）条件收录为独立项
  /// （2026-10-05 转正，推翻 2026-10-02 摘除拍板——AI 误判需要人类干预出口）。
  /// 分享、删除仍在详情页底栏常驻连接按钮组，不在此重复。
  /// 「允许 AI 处理」已删除（2026-10-05 拍板：管线回写授权不再要独立开关，
  /// 与 ai_editable 双开关冗余）。
  static List<ItemAction> overflowSheet(
    ItemActionContext ctx, {
    required Future<void> Function(bool on) onVault,
    required Future<void> Function(bool on) onAiVisible,
    required Future<void> Function(bool on) onAiEditable,
    required VoidCallback onMachineToggle,
    required Future<void> Function() onReprocess,
    required Future<void> Function() onReclassify,
  }) =>
      [
        vault(ctx, run: onVault, grouped: true),
        aiVisible(ctx, run: onAiVisible, grouped: true),
        aiEditable(ctx, run: onAiEditable, grouped: true),
        machineMode(ctx, onToggle: onMachineToggle, grouped: true),
        reprocess(ctx, run: onReprocess),
        reclassify(ctx, run: onReclassify),
      ].whereType<ItemAction>().toList();

  /// 列表批量操作栏动作集（§3.2 页面配置收敛于此，组合E 三页共用）：
  /// 全部页/搜索页 = 全量四项；保险箱视图 = 去「置顶/工作区」（置顶仅全部页
  /// 生效拍板、Vault 条目动作层拒绝入工作区），保险箱项换「移出」；
  /// 工作区内页加「移出本工作区」（workspace.md §3.3 转正：解除归属不删条目）。
  static List<SelectionActionSpec> selectionBar({
    required bool inVaultView,
    bool inWorkspaceView = false,
  }) =>
      [
        if (!inVaultView)
          const SelectionActionSpec(
              id: 'set_pin', icon: Icons.push_pin_outlined, label: '置顶'),
        if (!inVaultView)
          const SelectionActionSpec(
              id: 'workspace', icon: Icons.workspaces_outlined, label: '工作区'),
        if (inWorkspaceView)
          const SelectionActionSpec(
            id: 'remove_from_workspace',
            icon: Icons.playlist_remove_outlined,
            label: '移出工作区',
          ),
        SelectionActionSpec(
          id: 'set_vault',
          icon: Icons.lock_outline,
          label: inVaultView ? '移出保险箱' : '保险箱',
        ),
        const SelectionActionSpec(
            id: 'delete', icon: Icons.delete_outline, label: '删除', danger: true),
      ];
}
