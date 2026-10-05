import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../models/workspace.dart';
import '../ui/actions/item_actions.dart';
import '../ui/confirm_dialog.dart';
import '../ui/content_card.dart';
import '../ui/feedback_views.dart';
import '../ui/goodshare_image.dart';
import '../ui/selection/selection_scope.dart';
import '../ui/tokens.dart';
import 'item_detail_page.dart';
import 'workspace_create_page.dart';

/// 工作区（ui-spec §4.11）：条目集合容器，多对多。
///
/// 两层（2026-09-30 D2 用户拍板「卡片化」）：
/// ①工作区列表 = 卡片网格（mymind Spaces 形态：卡 = 工作区，封面拼贴
/// （最多 3 图 1:1 裁切）+ 名字 + 条目数；无图退首条文字预览，空区图标兜底）；
/// ②工作区内条目 = 瀑布流双列（与「全部」页同一套卡片语言，同一边距令牌）。
/// 与「AI 分类标签」区分：工作区是用户可创建/命名的容器，标签是 AI 产出的属性。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.repo,
    required this.handler,
    required this.caps,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final AiCapabilities caps;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  late Future<List<_WsEntry>> _workspaces;
  Workspace? _selected;
  late Future<List<InboxItem>> _items;

  /// 批量选择模式（card-batch-selection §3.2 配置：工作区内=全量四动作；
  /// 「移出本工作区」为预留候选）。选择仅存在于工作区内条目层。
  final SelectionController _selection = SelectionController();

  /// 最近一次加载的条目（批量动作的条目源；FutureBuilder 数据落一份到字段）。
  List<InboxItem> _selItems = const [];

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  Future<void> _onBatchAction(String actionId) async {
    await runSelectionBatch(
      context,
      handler: widget.handler,
      repo: widget.repo,
      selection: _selection,
      items: _selItems,
      actionId: actionId,
      vaultView: false,
    );
    // 批量改动后重拉工作区条目（本页无 RepoAutoReload 订阅）。
    if (_selected != null && mounted) setState(() => _items = widget.repo.listWorkspaceItems(_selected!.id));
  }

  Widget _gridCard(InboxItem it) => ContentCard(
        item: it,
        selected: _selection.isSelected(it.id!),
        onTap: () {
          if (_selection.active) {
            _selection.toggle(it.id!);
          } else {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ItemDetailPage(
                  repo: widget.repo,
                  handler: widget.handler,
                  caps: widget.caps,
                  item: it,
                  vaultContext: false,
                ),
              ),
            );
          }
        },
        onLongPress: () {
          HapticFeedback.lightImpact();
          _selection.enter(it.id!);
        },
      );

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _workspaces = _loadAll();
    });
  }

  /// 工作区数量通常个位数，逐个取条目做封面预览可接受（N 次小查询）。
  Future<List<_WsEntry>> _loadAll() async {
    final list = await widget.repo.listWorkspaces();
    final out = <_WsEntry>[];
    for (final ws in list) {
      // 与 list() 同口径：排除 Vault 与已删，工作区不得成为隐私隔离后门
      out.add(
        _WsEntry(
          ws,
          _WsPreview.of(await widget.repo.listWorkspaceItems(ws.id)),
        ),
      );
    }
    return out;
  }

  void _open(Workspace ws) {
    setState(() {
      _selected = ws;
      // 与 list() 同口径：排除 Vault 与已删，工作区不得成为隐私隔离后门
      _items = widget.repo.listWorkspaceItems(ws.id);
    });
  }

  /// 工作区卡长按弹层（docs/design/workspace.md §3.1 拍板）：重命名/删除。
  /// 删除仅列表层可达——天然排除「正在浏览的工作区被删」的态。
  Future<void> _showWsSheet(_WsEntry e) async {
    final scheme = Theme.of(context).colorScheme;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text('重命名「${e.ws.name}」'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      await _rename(e.ws);
    } else if (action == 'delete') {
      await _delete(e);
    }
  }

  Future<void> _rename(Workspace ws) async {
    final name = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => WorkspaceCreatePage(
          initialName: ws.name,
          title: '重命名工作区',
          cta: '保存',
        ),
      ),
    );
    if (name == null || name.isEmpty || name == ws.name) return;
    try {
      final result = await widget.handler.execute(RenameWorkspaceCommand(ws.id, name));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.note ?? '已重命名')));
      }
      _reload();
    } on ActionException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// 删除（§3.2 拍板 B 快捷删）：空区轻确认；非空弹窗明示条数与条目去向
  /// （「保留内容并删除」）——ackNonEmpty 只在此人类确认后携带。
  Future<void> _delete(_WsEntry e) async {
    final count = e.preview.count;
    final ok = await confirmDialog(
      context,
      title: '删除工作区「${e.ws.name}」',
      content: count > 0
          ? '这个工作区还有 $count 条内容。\n'
              '删除只解除归属，内容会保留在「全部」页。'
          : null,
      confirmText: count > 0 ? '保留内容并删除' : '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      final result = await widget.handler.execute(
        DeleteWorkspaceCommand(e.ws.id, ackNonEmpty: count > 0),
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.note ?? '已删除')));
      }
      _reload();
    } on ActionException catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err.message)));
      }
    }
  }

  Future<void> _create() async {
    // 整页创建（2026-10-01 拍板，mymind「Create new space」参照）取代裸
    // AlertDialog——本页只产名称，写路径仍走 CreateWorkspaceCommand
    final name = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const WorkspaceCreatePage()),
    );
    if (name == null || name.isEmpty) return;
    await widget.handler.execute(CreateWorkspaceCommand(name));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    // 进入某工作区后手势返回=退回工作区列表（ui-spec §3）；列表层级交还系统
    return PopScope(
      // 返回手势分层退出：选择模式 > 工作区内页 > 工作区列表（§2.1 模式出口优先）。
      canPop: _selected == null && !_selection.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_selection.active) {
            _selection.exit();
          } else {
            setState(() => _selected = null);
          }
        }
      },
      child: Scaffold(
        bottomNavigationBar: _selection.active
            ? SelectionActionBar(
                controller: _selection,
                actions: ItemActions.selectionBar(inVaultView: false),
                onExit: _selection.exit,
                onAction: _onBatchAction,
              )
            : null,
        appBar: AppBar(
          // ☰ 只保留在「全部」页（2026-09-30 用户拍板）；进入工作区后无返回
          // 箭头，出口=系统手势/返回键
          automaticallyImplyLeading: false,
          title: _selection.active
              ? SelectionHeaderRow(controller: _selection, onExit: _selection.exit)
              : Text(_selected?.name ?? '工作区'),
        ),
        body: Stack(
          children: [
            _selected == null ? _buildList() : _buildItems(),
            // 新建工作区 FAB：右下角、底栏上沿再抬高 ~96px——单手拇指自然
            // 扫掠弧内（2026-09-30 用户拍板，自 AppBar 右上角迁来）。
            // 仅工作区列表层显示；避免与底部导航/手势条重叠。
            if (_selected == null)
              Positioned(
                right: Insets.lg,
                bottom: 96,
                child: FloatingActionButton(
                  onPressed: _create,
                  tooltip: '新建工作区',
                  child: const Icon(Icons.add),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// ①工作区列表：卡片网格（mymind Spaces 形态，D2 用户拍板）。
  /// 高度贴内容的固定比例小卡，不做低密度大卡（否决小红书式大卡的教训延续）。
  Widget _buildList() => FutureBuilder<List<_WsEntry>>(
    future: _workspaces,
    builder: (ctx, snap) {
      if (snap.hasError) {
        return ErrorRetryView(onRetry: () => setState(() {}));
      }
      if (!snap.hasData) {
        return const LoadingView();
      }
      final entries = snap.data!;
      if (entries.isEmpty) {
        return const Center(child: EmptyStateView(text: '还没有工作区\n点右下角 + 新建'));
      }
      return GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: Insets.sm,
        crossAxisSpacing: Insets.sm,
        childAspectRatio: 1.15,
        // 底部 96 让出右下角 FAB（与列表层 FAB bottom:96 同一让位语言）
        padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.sm, 96),
        children: [for (final e in entries) _workspaceCard(e)],
      );
    },
  );

  Widget _workspaceCard(_WsEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: InkWell(
        onLongPress: () {
          HapticFeedback.lightImpact();
          _showWsSheet(e);
        },
        onTap: () => _open(e.ws),
        child: Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _cover(e.preview, scheme)),
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      e.ws.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    '${e.preview.count}',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面：图片条目拼贴（最多 3 张，等宽裁切铺满）→ 无图退首条文字预览
  /// → 空工作区图标兜底。
  Widget _cover(_WsPreview p, ColorScheme scheme) {
    if (p.imagePaths.isNotEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final path in p.imagePaths.take(3))
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: GoodshareImage(
                  file: File(path),
                  fit: BoxFit.cover,
                  // 拼贴小格约 1/3 卡宽，限解码宽防大图过解码（内存水位纪律）
                  cacheWidth: 480,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: scheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.image_outlined,
                      size: 24,
                      color: scheme.outline,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    final preview = p.textPreview;
    if (preview != null) {
      return Text(
        preview,
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return Center(
      child: Icon(
        Icons.workspaces_outlined,
        size: 40,
        color: scheme.outlineVariant,
      ),
    );
  }

  /// ②工作区内条目：瀑布流双列（与「全部」页同一套卡片语言，D2 用户拍板）。
  Widget _buildItems() => FutureBuilder<List<InboxItem>>(
    future: _items,
    builder: (ctx, snap) {
      if (snap.hasError) {
        return ErrorRetryView(onRetry: () => setState(() {}));
      }
      if (!snap.hasData) {
        return const LoadingView();
      }
      final items = snap.data!;
      _selItems = items;
      if (items.isEmpty) {
        return const Center(child: EmptyStateView(text: '这个工作区还没有条目'));
      }
      return MasonryGridView.count(
        // 选择模式中禁下拉刷新语义（拍板）——本页无下拉刷新，保持物理一致。
        physics: _selection.active
            ? const ClampingScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        crossAxisCount: 2,
        mainAxisSpacing: Insets.sm,
        crossAxisSpacing: Insets.sm,
        padding: const EdgeInsets.fromLTRB(
          Insets.sm,
          Insets.sm,
          Insets.sm,
          Insets.lg,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => _gridCard(items[i]),
      );
    },
  );
}

/// 工作区卡片数据：条目数 + 封面素材（图片路径 / 文字预览）。
class _WsPreview {
  const _WsPreview({
    required this.count,
    required this.imagePaths,
    this.textPreview,
  });

  factory _WsPreview.of(List<InboxItem> items) {
    String? textPreview;
    for (final it in items) {
      if (it.preview.isNotEmpty) {
        textPreview = it.preview;
        break;
      }
    }
    return _WsPreview(
      count: items.length,
      imagePaths: [
        for (final it in items)
          if (it.isImage && it.hasAttachment) it.rawFilePath!,
      ],
      textPreview: textPreview,
    );
  }

  final int count;
  final List<String> imagePaths;
  final String? textPreview;
}

class _WsEntry {
  const _WsEntry(this.ws, this.preview);

  final Workspace ws;
  final _WsPreview preview;
}
