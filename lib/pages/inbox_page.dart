import 'package:flutter/material.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../ai/reconstructor.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../share/attachments.dart';
import '../share/text_collector.dart';
import '../ui/content_card.dart';
import '../ui/drawer_menu_button.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/slogans.dart';
import 'add_sheet.dart';
import 'item_detail_page.dart';

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
  final _searchCtrl = TextEditingController();
  String? _query = '';
  String? _type; // null = 全部
  ItemSort _sort = ItemSort.newest;
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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(
      query: _query,
      type: _type,
      vault: widget.vaultOnly,
      sort: _sort,
      limit: 500,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onSearchChanged(String q) {
    _query = q;
    _reload();
  }

  void _setType(String? t) {
    setState(() => _type = t);
    _reload();
  }

  void _toggleSort() {
    setState(() => _sort = _sort == ItemSort.newest ? ItemSort.oldest : ItemSort.newest);
    _reload();
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
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuLeading(widget.onOpenDrawer),
        title: TextField(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          decoration: const InputDecoration(
            hintText: '搜索标题 / 正文 / 标签',
            isDense: true,
            border: InputBorder.none,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: '添加',
            onSelected: _onAddMenu,
            itemBuilder: (_) => const [
              PopupMenuItem<String>(value: 'camera', child: Text('拍照')),
              PopupMenuItem<String>(value: 'scan', child: Text('扫描文档')),
              PopupMenuItem<String>(value: 'import', child: Text('导入资源')),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _filterBar(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 筛选 / 排序维度（一行 chips，可横滑）。
  Widget _filterBar() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _chip(
            label: '全部',
            selected: _type == null && !widget.vaultOnly,
            onSelected: (_) => _setType(null),
          ),
          for (final t in InboxItem.allTypes)
            _chip(
              label: ContentCard.labelOf(t),
              avatar: Icon(ContentCard.iconOf(t), size: 16),
              selected: _type == t,
              onSelected: (_) => _setType(_type == t ? null : t),
            ),
          _chip(
            label: '保险箱',
            avatar: const Icon(Icons.lock_outline, size: 16),
            selected: widget.vaultOnly,
            onSelected: (v) => widget.onVaultOnlyChanged?.call(v),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: ActionChip(
              label: const Text('标签'),
              onPressed: () {
                // facets 由 AI 打标产出（V2）；无数据时不给假入口
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('标签随离线 AI 打标生效后开放')),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: ActionChip(
              avatar: Icon(
                _sort == ItemSort.newest
                    ? Icons.arrow_downward
                    : Icons.arrow_upward,
                size: 16,
              ),
              label: Text(_sort == ItemSort.newest ? '最新' : '最早'),
              onPressed: _toggleSort,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
    Widget? avatar,
  }) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          avatar: avatar,
          selected: selected,
          onSelected: onSelected,
        ),
      );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return Center(
        child: Column(
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
            Text(
              _emptyTitle(),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              widget.vaultOnly ? '把条目移入保险箱后会出现在这里' : '用底部输入条记下第一条',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: _items.length,
        itemBuilder: (context, i) =>
            ContentCard(item: _items[i], onTap: () => _open(_items[i])),
      ),
    );
  }

  String _emptyTitle() {
    if (widget.vaultOnly) return '保险箱是空的';
    if (_type != null) return '还没有${ContentCard.labelOf(_type!)}';
    if ((_query ?? '').isNotEmpty) return '没有匹配的条目';
    return '还没有任何收集';
  }

  Future<void> _onAddMenu(String v) async {
    switch (v) {
      case 'camera':
        await _openAddSheet(initialType: InboxItem.typeImage);
      case 'scan':
        await _scanDocument();
      case 'import':
        await _openAddSheet();
    }
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ready.reason ?? '文档扫描不可用')),
        );
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.note ?? '未扫描到内容')),
          );
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
            content: Text(failed > 0
                ? '已添加 $n 个扫描页，$failed 个保存失败'
                : '已添加 $n 个扫描页'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文档入库中断：$e')),
        );
      }
    }
  }
}
