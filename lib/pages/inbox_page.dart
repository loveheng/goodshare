import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../ui/drawer_menu_button.dart';
import '../models/item.dart';
import '../ui/content_card.dart';
import '../ui/repo_auto_reload.dart';
import 'item_detail_page.dart';

/// 全部（首页，2026-09-27 改版）：顶部固定搜索 + 类型 chips，条目区可**横滑切换类型**。
/// 第 0 页为「全部」（按 item_type 分组带计数），其后每页一个类型（可滑动切换，
/// chips 与页双向同步；切换后 chips 行自动滚动，选中 chip 完整可见）。
/// 添加入口统一为悬浮球（2026-09-27：页内各分类 ＋ 已移除）。
/// 时间轴视图随 V3 与时光机分化后再加入（F5 决策，MVP/V2 仅分类视图）。
class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.repo,
    required this.handler,
    this.onOpenDrawer,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final VoidCallback? onOpenDrawer;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> with RepoAutoReload {
  final _searchCtrl = TextEditingController();
  final _pageCtrl = PageController();
  /// 各 chip 的 key：切换 tab 后据此定位选中 chip 并自动滚动 chips 行
  final _chipKeys = List<GlobalKey>.generate(_typeTabs.length, (_) => GlobalKey());
  String? _query = '';
  List<InboxItem> _items = [];
  List<InboxItem> _all = [];
  bool _loading = true;
  int _pageIndex = 0;

  /// 页 ↔ 类型映射：index 0 = 全部(null)，1..n = allTypes
  static const _typeTabs = [
    null,
    InboxItem.typeNote,
    InboxItem.typeUrl,
    InboxItem.typeImage,
    InboxItem.typeVideo,
    InboxItem.typeAudio,
    InboxItem.typeChatlog,
    InboxItem.typeDocument,
  ];

  static String? typeAt(int i) => _typeTabs[i];

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
  void dispose() {
    _searchCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(query: _query, limit: 500);
    if (!mounted) return;
    setState(() {
      _all = items;
      _items = _filtered(typeAt(_pageIndex));
      _loading = false;
    });
  }

  List<InboxItem> _filtered(String? type) =>
      type == null ? _all : _all.where((it) => it.itemType == type).toList();

  void _onSearchChanged(String q) {
    _query = q;
    _reload();
  }

  /// 横滑切页：更新页 + 当前页数据
  void _onPageChanged(int i) {
    setState(() {
      _pageIndex = i;
      _items = _filtered(typeAt(i));
    });
    _scrollChipsTo(i);
  }

  /// 切换 tab 后 chips 行自动滚动，保证选中 chip 完整可见（设计 §4.2）
  void _scrollChipsTo(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _chipKeys[i].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// chips 点选：滑动到对应页（双向同步）
  void _jumpTo(String? type) {
    final i = _typeTabs.indexOf(type);
    if (i < 0 || i == _pageIndex) return;
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _open(InboxItem it) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ItemDetailPage(repo: widget.repo, handler: widget.handler, item: it),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuLeading(widget.onOpenDrawer),
        title: const Text('全部'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(92),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: '搜索标题 / 正文 / 标签',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                ),
              ),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final (i, t) in _typeTabs.indexed)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          key: _chipKeys[i],
                          avatar: t == null ? null : Icon(ContentCard.iconOf(t), size: 16),
                          label: Text(t == null ? '全部' : ContentCard.labelOf(t)),
                          selected: _pageIndex == i,
                          onSelected: (_) => _jumpTo(t),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : PageView(
              controller: _pageCtrl,
              onPageChanged: _onPageChanged,
              children: [
                _allPage(),
                for (final t in _typeTabs.skip(1)) _typePage(t as String),
              ],
            ),
    );
  }

  /// 第 0 页：全部（按类型分组带计数）
  Widget _allPage() {
    if (_all.isEmpty) {
      return Center(
        child: Text('没有匹配的收集', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    final groups = <String, List<InboxItem>>{};
    for (final it in _all) {
      (groups[it.itemType] ??= []).add(it);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) => groups[b]!.length.compareTo(groups[a]!.length));

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: keys.length,
        itemBuilder: (context, i) {
          final type = keys[i];
          final list = groups[type]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Icon(ContentCard.iconOf(type), size: 18),
                    const SizedBox(width: 6),
                    Text(ContentCard.labelOf(type),
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Text('${list.length}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              for (final it in list) ContentCard(item: it, onTap: () => _open(it)),
            ],
          );
        },
      ),
    );
  }

  /// 类型页（index ≥ 1）：单类型条目流（添加入口统一为悬浮球）
  Widget _typePage(String type) {
    final list = _items; // 当前页数据（已按 type 过滤）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Icon(ContentCard.iconOf(type), size: 18),
              const SizedBox(width: 6),
              Text(ContentCard.labelOf(type),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text('${list.length}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(ContentCard.iconOf(type),
                          size: 48,
                          color: Theme.of(context).colorScheme.outlineVariant),
                      const SizedBox(height: 12),
                      Text('还没有${ContentCard.labelOf(type)}',
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      Text('点屏幕 + 添加第一条',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: list.length,
                    itemBuilder: (context, i) =>
                        ContentCard(item: list[i], onTap: () => _open(list[i])),
                  ),
                ),
        ),
      ],
    );
  }
}
