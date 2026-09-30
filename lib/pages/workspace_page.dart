import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../models/workspace.dart';
import '../ui/content_card.dart';
import '../ui/goodshare_image.dart';
import '../ui/tokens.dart';
import 'item_detail_page.dart';

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
      out.add(_WsEntry(ws, _WsPreview.of(await widget.repo.listWorkspaceItems(ws.id))));
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

  Future<void> _create() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建工作区'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(hintText: '工作区名称'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.handler.execute(CreateWorkspaceCommand(name));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // ☰ 只保留在「全部」页（2026-09-30 用户拍板）；工作区 AppBar 仅
        // 进入某工作区时给返回箭头
        leading: _selected == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selected = null),
              ),
        automaticallyImplyLeading: false,
        title: Text(_selected?.name ?? '工作区'),
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
    );
  }

  /// ①工作区列表：卡片网格（mymind Spaces 形态，D2 用户拍板）。
  /// 高度贴内容的固定比例小卡，不做低密度大卡（否决小红书式大卡的教训延续）。
  Widget _buildList() => FutureBuilder<List<_WsEntry>>(
        future: _workspaces,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snap.data!;
          if (entries.isEmpty) {
            return Center(
              child: Text(
                '还没有工作区\n点右下角 + 新建',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: Insets.sm,
            crossAxisSpacing: Insets.sm,
            childAspectRatio: 1.15,
            // 底部 96 让出右下角 FAB（与列表层 FAB bottom:96 同一让位语言）
            padding:
                const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.sm, 96),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      child: InkWell(
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
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
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
                    child: Icon(Icons.image_outlined,
                        size: 24, color: scheme.outline),
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
        style:
            Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return Center(
      child: Icon(Icons.workspaces_outlined,
          size: 40, color: scheme.outlineVariant),
    );
  }

  /// ②工作区内条目：瀑布流双列（与「全部」页同一套卡片语言，D2 用户拍板）。
  Widget _buildItems() => FutureBuilder<List<InboxItem>>(
        future: _items,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Text(
                '这个工作区还没有条目',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return MasonryGridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: Insets.sm,
            crossAxisSpacing: Insets.sm,
            padding:
                const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.sm, Insets.lg),
            itemCount: items.length,
            itemBuilder: (context, i) => ContentCard(
              item: items[i],
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ItemDetailPage(
                    repo: widget.repo,
                    handler: widget.handler,
                    caps: widget.caps,
                    item: items[i],
                    vaultContext: false,
                  ),
                ),
              ),
            ),
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
