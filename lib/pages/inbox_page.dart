import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../ai/reconstructor.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../share/attachments.dart';
import '../share/text_collector.dart';
import '../ui/content_card.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/slogans.dart';
import '../ui/tokens.dart';
import 'add_sheet.dart';
import 'item_detail_page.dart';
import 'search_page.dart';

/// 全部 · 主列表（2026-09-30 改版：唯一内容列表页）。
///
/// 收敛结果：原「横滑切换类型」的 `PageView` **取消**（类型降为筛选维度后，
/// 横滑翻页与 chips 两套并存是重复交互）；时光机降为**排序维度**，AI 分类降为
/// **标签维度**，保险箱降为**筛选条件**（其入口在侧边栏，视图仍由本页承载）。
///
/// 顶部 `＋` 只管「把外部资源拿进来」（拍照 / 扫描文档 / 导入），
/// 速记归底部常驻条（ui-spec §4.6 的分工）。
class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.repo,
    required this.handler,
    required this.collector,
    required this.caps,
    this.onOpenDrawer,
    this.vaultOnly = false,
    this.onVaultOnlyChanged,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final AiCapabilities caps; // 详情页翻译预检 / 文档扫描能力
  final VoidCallback? onOpenDrawer;

  /// 仅显示保险箱条目（安全域视图）。由侧边栏入口或本页「保险箱」chip 切换。
  final bool vaultOnly;

  /// 保险箱视图切换回调：home_shell 据此同步 `SecureWindow`（FLAG_SECURE）。
  final ValueChanged<bool>? onVaultOnlyChanged;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> with RepoAutoReload {
  // 搜索/筛选已迁全屏搜索页（2026-09-30）：首页固定「全部 + 最新排序」。
  List<InboxItem> _items = [];
  bool _loading = true;

  @override
  Repository get repo => widget.repo;

  @override
  void reload() => _reload();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(InboxPage old) {
    super.didUpdateWidget(old);
    if (old.vaultOnly != widget.vaultOnly) _reload();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(
      vault: widget.vaultOnly,
      sort: ItemSort.newest,
      limit: 500,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          repo: widget.repo,
          handler: widget.handler,
          caps: widget.caps,
        ),
      ),
    );
  }

  void _open(InboxItem it) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ItemDetailPage(
          repo: widget.repo,
          handler: widget.handler,
          item: it,
          caps: widget.caps,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onSurfaceVariant = scheme.onSurfaceVariant;

    // 保险箱视图（2026-09-30 D1 范围外）：静态 AppBar 不参与隐显，现状保留
    if (widget.vaultOnly) {
      // 手势返回=退出保险箱视图回「全部」，而非退到后台（ui-spec §3）
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) widget.onVaultOnlyChanged?.call(false);
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            titleSpacing: Insets.md,
            title: _topBarRow(scheme, onSurfaceVariant),
          ),
          body: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: const Text('保险箱'),
            ),
            body: _listBody(),
          ),
        ),
      );
    }

    // 全部页（2026-09-30 D1 用户拍板）：顶栏并入滚动流——SliverAppBar
    // floating+snap（非 pinned、非 overlay），与列表同源联动：
    // 向下滚内容（继续阅读）→ 顶栏随内容滑出隐藏；向上滚（回看，轻微反向
    // 滚动即弹回）→ 顶栏 snap 展开；列表在顶部时恒显示。方向判定由滚动
    // 位置天然驱动，无需手写阈值防抖。
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reload,
        // 顶栏（搜索条）并入滚动流，spinner 锚点是视口顶边而非顶栏下缘——
        // 默认 displacement(40) 会让刷新动画落在搜索条上；加顶栏整高
        // （状态栏 + 工具栏 + 边距）使其落在内容区上缘（2026-09-30 方案1 拍板）。
        // 顶栏非 pinned，滚离后动画仍悬于内容上空，位置可接受。
        displacement:
            MediaQuery.of(context).padding.top + kToolbarHeight + Insets.lg,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              automaticallyImplyLeading: false,
              floating: true,
              snap: true,
              titleSpacing: Insets.md,
              title: _topBarRow(scheme, onSurfaceVariant),
            ),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _emptyView())
            else
              SliverPadding(
                // 边距收窄并与便利贴同宽语言（2026-09-30 用户拍板：内容区太宽了）；
                // 底部 96 让出便利贴拉手
                padding: const EdgeInsets.fromLTRB(
                  Insets.sm,
                  Insets.sm,
                  Insets.sm,
                  96,
                ),
                sliver: SliverMasonryGrid.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: Insets.sm,
                  crossAxisSpacing: Insets.sm,
                  itemBuilder: (context, i) => ContentCard(
                    item: _items[i],
                    onTap: () => _open(_items[i]),
                  ),
                  childCount: _items.length,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 顶栏一体块内容（mymind 同款）：☰ 嵌入搜索长条左端（无接缝），
  /// 右侧橘红方形 ＋ 块。SliverAppBar（全部页，随滚动隐显）与
  /// 保险箱视图静态 AppBar 共用。
  Widget _topBarRow(ColorScheme scheme, Color onSurfaceVariant) {
    return Row(
      children: [
        Expanded(
          child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _openSearch,
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    // ☰ 与搜索同处一体块，中间无接缝
                    InkWell(
                      onTap: widget.onOpenDrawer,
                      borderRadius: BorderRadius.circular(Radii.md),
                      child: SizedBox(
                        width: 48,
                        height: 44,
                        child: Icon(Icons.menu, color: onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '搜索',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: Insets.sm),
        // 橘红方形添加块（品牌种子色，与 mymind 的 ＋ 块同位）
        Material(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(Radii.md),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _onAddMenuTap,
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.add, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  void _onAddMenuTap() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(ctx);
                _openAddSheet(initialType: InboxItem.typeImage);
              },
            ),
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('扫描文档'),
              onTap: () {
                Navigator.pop(ctx);
                _scanDocument();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('导入资源'),
              onTap: () {
                Navigator.pop(ctx);
                _openAddSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 保险箱视图列表（D1 范围外：静态 AppBar + 普通列表，不参与隐显）。
  Widget _listBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) return Center(child: _emptyView());
    return RefreshIndicator(
      onRefresh: _reload,
      child: MasonryGridView.count(
        physics: const AlwaysScrollableScrollPhysics(),
        crossAxisCount: 2,
        mainAxisSpacing: Insets.sm,
        crossAxisSpacing: Insets.sm,
        padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, Insets.sm, 96),
        itemCount: _items.length,
        itemBuilder: (context, i) =>
            ContentCard(item: _items[i], onTap: () => _open(_items[i])),
      ),
    );
  }

  /// 空态视图（全部页 sliver 与保险箱视图共用）。
  Widget _emptyView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PoeticText(
          sloganFor(widget.vaultOnly ? SloganKeys.empty : SloganKeys.splash),
          large: false,
          align: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Icon(
          widget.vaultOnly ? Icons.lock_outline : Icons.note_add_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        const SizedBox(height: 12),
        Text(_emptyTitle(), style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(
          widget.vaultOnly ? '把条目移入保险箱后会出现在这里' : '用底部输入条记下第一条',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  String _emptyTitle() {
    if (widget.vaultOnly) return '保险箱是空的';
    return '还没有任何收集';
  }

  Future<void> _openAddSheet({String? initialType}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 1.0,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: AddSheet(
            handler: widget.handler,
            collector: widget.collector,
            initialType: initialType,
          ),
        ),
      ),
    );
  }

  /// 文档扫描（前台相机流）：经 [AiCapabilities.documentScan] 调起系统扫描，
  /// 产出直接新建条目（每页一张图片，或整本 PDF）。无 GMS 时运行时降级并提示原因
  /// （不做脆性预检，以免国内无 GMS 设备误关入口）。
  Future<void> _scanDocument() async {
    final cap = widget.caps.documentScan;
    if (cap == null) return;
    final ready = await cap.ensureReady();
    if (!ready.available) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ready.reason ?? '文档扫描不可用')));
      }
      return;
    }
    try {
      final result = await cap.reconstruct(
        ReconstructInput(
          itemId: '_docscan',
          itemType: InboxItem.typeDocument,
          rawContent: '',
        ),
      );
      final raw = result.machineJson?['document_scan'];
      if (raw == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(result.note ?? '未扫描到内容')));
        }
        return;
      }
      final scan = raw as Map<String, Object?>;
      final images = (scan['images'] as List? ?? const []).cast<String>();
      var n = 0;
      var failed = 0;
      // 入库前先落 app 私有目录：扫描器返回的路径可能被系统清理
      Future<void> import(String itemType, String path) async {
        final saved = await copyToAppDir(path);
        if (saved == null) {
          failed++;
          return;
        }
        await widget.handler.execute(
          CollectCommand(
            itemType: itemType,
            sourceApp: 'goodshare.docscan',
            rawFilePath: saved,
            humanTitle: '扫描文档',
          ),
        );
        n++;
      }

      for (final p in images) {
        await import(InboxItem.typeImage, p);
      }
      if (images.isEmpty && scan['pdf'] != null) {
        await import(InboxItem.typeDocument, scan['pdf'] as String);
      }
      if (mounted) {
        reload();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failed > 0 ? '已添加 $n 个扫描页，$failed 个保存失败' : '已添加 $n 个扫描页',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('文档入库中断：$e')));
      }
    }
  }
}
