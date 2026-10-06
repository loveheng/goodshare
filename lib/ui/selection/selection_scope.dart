import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../action/commands.dart';
import '../../action/item_action_handler.dart';
import '../../data/repository.dart';
import '../../models/item.dart';
import '../actions/item_actions.dart';
import '../confirm_dialog.dart';
import '../toast.dart';
import '../tokens.dart';

/// 列表批量选择模式骨架（card-batch-selection.md §3.1）：
/// 长按进模式（触觉反馈由调用方给）→ 点按加/减选 → 底部批量操作栏。
/// 本文件只装骨架：选中集状态机、底部操作栏形态、「已选 N · ✕」顶栏行。
/// 动作规则全部来自 [ItemActions] 词汇表；执行通道（executeAll）由调用方注入。
///
/// 拍板口径（2026-10-02）：
/// - 零选中不退出模式，四动作按钮置灰（防跳动）；
/// - 无全选入口；取消 = ✕ / 返回手势（PopScope 由页面接）；
/// - 操作栏取代底部导航/输入条（由页面 & HomeShell 协作让位）；
/// - 删除批量二次确认只报数量；动作完成后由调用方退出模式。

/// 选中集状态机：id 集合 + 模式开关，ChangeNotifier 驱动局部重绘。
class SelectionController extends ChangeNotifier {
  bool _active = false;
  final Set<String> _ids = {};

  bool get active => _active;
  int get count => _ids.length;
  bool isSelected(String id) => _active && _ids.contains(id);

  /// 长按进入模式并选中该卡片。
  void enter(String id) {
    _active = true;
    _ids
      ..clear()
      ..add(id);
    notifyListeners();
  }

  /// 模式中点按：加选 / 减选（减到空仍保持模式——零选中置灰拍板）。
  void toggle(String id) {
    if (!_active) {
      enter(id);
      return;
    }
    if (_ids.contains(id)) {
      _ids.remove(id);
    } else {
      _ids.add(id);
    }
    notifyListeners();
  }

  /// 退出模式（✕ / 返回手势 / 动作完成后）。
  void exit() {
    if (!_active) return;
    _active = false;
    _ids.clear();
    notifyListeners();
  }
}

/// 批量操作栏（取代底部导航的常驻栏）：「✕ 已选 N」在页面顶栏（见调用方），
/// 本栏只放动作按钮。按钮零选中置灰；删除红色；图标+文字并排（拍板视觉）。
/// 动作集由 [ItemActions.selectionBar] 产出（规则源），本组件只呈现。
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({
    super.key,
    required this.controller,
    required this.actions,
    required this.onExit,
    required this.onAction,
  });

  final SelectionController controller;
  final List<SelectionActionSpec> actions;
  final VoidCallback onExit;

  /// 动作 id（SelectionActionSpec.id）→ 执行。由页面注入（依赖 handler/repo）。
  final void Function(String actionId) onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = controller.count > 0;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: Insets.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // ✕ 出口也放操作栏左端（顶栏「已选 N」之外的保底出口，双通道同语义）
              IconButton(
                tooltip: '退出选择',
                onPressed: onExit,
                icon: Icon(Icons.close, size: 22, color: scheme.onSurfaceVariant),
              ),
              for (final a in actions)
                InkWell(
                  onTap: enabled ? () => onAction(a.id) : null,
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                  child: Opacity(
                    opacity: enabled ? 1 : 0.38,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            a.icon,
                            size: 22,
                            color: a.danger && enabled
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            a.label,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: a.danger && enabled
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶栏「已选 N · ✕」行（选择模式中替换页面顶栏内容）。
class SelectionHeaderRow extends StatelessWidget {
  const SelectionHeaderRow({super.key, required this.controller, required this.onExit});

  final SelectionController controller;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        IconButton(
          tooltip: '退出选择',
          onPressed: onExit,
          icon: Icon(Icons.close, size: 22, color: scheme.onSurfaceVariant),
        ),
        Text(
          '已选 ${controller.count}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }
}

/// 批量执行收口（card-batch-selection.md §3.3）：全部动作走
/// [ItemActionHandler.executeAll] 事务；UI 只组装命令 + 呈现结果反馈。
/// 部分失败由动作层整体回滚，本层把异常消息原样上屏（消息即 UI 友好文案契约）。
class BatchActionExecutor {
  BatchActionExecutor(this._handler);

  final ItemActionHandler _handler;

  /// 执行并弹反馈；返回是否全部成功。调用方据此退出选择模式。
  Future<bool> run(
    BuildContext context,
    List<InboxItem> selected, {
    required ItemCommand Function(InboxItem item) build,
    required String successMsg,
    bool vaultContext = false,
  }) async {
    if (selected.isEmpty) return false;
    try {
      await _handler.executeAll([for (final it in selected) build(it)],
          vaultContext: vaultContext);
      // 成功落库触感（ui-spec §6.0 触感映射：medium=成功落库）
      HapticFeedback.mediumImpact();
      ToastManager.show('$successMsg（${selected.length} 条）', kind: ToastKind.success);
      return true;
    } on ActionException catch (e) {
      ToastManager.show(e.message, kind: ToastKind.error);
      return false;
    }
  }
}

/// 列表批量动作统一执行（组合E 四个列表面共用；动作集规则在
/// [ItemActions.selectionBar]，执行语义在此收口）：
/// - 置顶：混合态整批置顶（拍板「混合态只显示置顶」）；
/// - 保险箱：全部页/搜索/工作区内 = 整批移入；保险箱视图 = 整批移出（vaultContext）；
/// - 工作区：选择器 → 整批加入（Vault 条目动作层拒绝，事务整体回滚不拆单）；
/// - 移出本工作区（workspace.md §3.3 转正）：仅工作区内页，整批解除归属回
///   「全部」，**不删条目**——文案与「删除」严格分开，Snackbar 明示去与留；
/// - 删除：确认弹窗只报数量（拍板），软删 30 天兜底。
/// 成功即退出选择模式（列表刷新由各页 RepoAutoReload / 重新拉取承担）。
Future<void> runSelectionBatch(
  BuildContext context, {
  required ItemActionHandler handler,
  required Repository repo,
  required SelectionController selection,
  required List<InboxItem> items,
  required String actionId,
  required bool vaultView,
  String? workspaceId,
}) async {
  final selected = [
    for (final it in items)
      if (selection.isSelected(it.id!)) it,
  ];
  final executor = BatchActionExecutor(handler);
  switch (actionId) {
    case 'set_pin':
      final anyUnpinned = selected.any((it) => !it.isPinned);
      final ok = await executor.run(
        context,
        selected,
        build: (it) => PinCommand(it.id!, anyUnpinned),
        successMsg: anyUnpinned ? '已置顶' : '已取消置顶',
      );
      if (ok) selection.exit();
    case 'set_vault':
      final ok = await executor.run(
        context,
        selected,
        build: (it) => SetVaultCommand(it.id!, !vaultView),
        successMsg: vaultView ? '已移出保险箱' : '已移入保险箱',
        vaultContext: vaultView,
      );
      if (ok) selection.exit();
    case 'workspace':
      final ws = await repo.listWorkspaces();
      if (!context.mounted) return;
      final chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('加入工作区'),
          children: [
            if (ws.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('还没有工作区，去「工作区」tab 新建一个'),
              ),
            for (final w in ws)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, w.id),
                child: Text(w.name),
              ),
          ],
        ),
      );
      if (chosen == null || !context.mounted) return;
      final ok = await executor.run(
        context,
        selected,
        build: (it) => AddToWorkspaceCommand(chosen, it.id!),
        successMsg: '已加入工作区',
      );
      if (ok) selection.exit();
    case 'remove_from_workspace':
      // §3.3 移除语义：解除归属回「全部」、不删条目——轻动作无确认，
      // Snackbar 文案明示去与留（与「删除」严格分开）。
      if (workspaceId == null || workspaceId.isEmpty) return;
      final ok = await executor.run(
        context,
        selected,
        build: (it) => RemoveFromWorkspaceCommand(workspaceId, it.id!),
        successMsg: '已移出工作区（条目保留在「全部」）',
      );
      if (ok) selection.exit();
    case 'delete':
      if (!context.mounted) return;
      final confirmed = await confirmDialog(
        context,
        title: '删除 ${selected.length} 条收集？',
        content: '删除后 30 天内可在「设置 → 最近删除」恢复。',
        confirmText: '删除',
        danger: true,
      );
      if (confirmed != true || !context.mounted) return;
      final ok = await executor.run(
        context,
        selected,
        build: (it) => DeleteItemCommand(it.id!),
        successMsg: '已删除',
        // 保险箱视图删除同样需要 Vault 上下文，否则动作层按不可见拒绝（「条目不存在」）。
        vaultContext: vaultView,
      );
      if (ok) selection.exit();
  }
}
