import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../ui/content_card.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/tokens.dart';
import 'item_detail_page.dart';

/// 全屏搜索页（2026-09-30 改版，用户拍板）：点首页搜索框进入。
///
/// 结构：大搜索框（× 清空 / 空时关闭）→ 类型入口 chips（便签/链接/图片/视频/
/// 音频/文档六类，用户拍板：聊天是标签不给类型入口）→ 实时瀑布流结果
/// （固定最新排序，用户拍板不要排序切换）。
/// **点结果区空白处即返回首页**——筛选状态随页销毁，首页保持「全部」。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.repo,
    required this.handler,
    required this.caps,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final AiCapabilities caps;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with RepoAutoReload {
  final _ctrl = TextEditingController();

  /// 类型入口（用户拍板六类；聊天/保险箱不在此列）。
  static const _types = [
    InboxItem.typeNote,
    InboxItem.typeUrl,
    InboxItem.typeImage,
    InboxItem.typeVideo,
    InboxItem.typeAudio,
    InboxItem.typeDocument,
  ];

  String? _type;
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
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(
      query: _ctrl.text.trim(),
      type: _type,
      vault: false, // 保险箱不进搜索（MCP 同口径，隐私隔离）
      sort: ItemSort.newest, // 固定最新（用户拍板）
      limit: 500,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _setType(String? t) {
    setState(() => _type = _type == t ? null : t);
    _reload();
  }

  /// × ：有字清空重搜，无字关闭页面。
  void _onClear() {
    if (_ctrl.text.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    _ctrl.clear();
    _reload();
  }

  void _open(InboxItem it) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ItemDetailPage(
          repo: widget.repo,
          handler: widget.handler,
          caps: widget.caps,
          item: it,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // 全面屏手势时代不需要返回箭头（用户拍板）；退出=右侧 × / 系统侧滑
        automaticallyImplyLeading: false,
        titleSpacing: Insets.sm,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: (_) => _reload(),
          decoration: InputDecoration(
            hintText: '搜索标题 / 正文 / 标签',
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              onPressed: _onClear,
              icon: const Icon(Icons.close),
              tooltip: '清空 / 关闭',
            ),
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _typeChips(),
          const Divider(height: 1),
          // 结果区：点空白处返回首页（用户拍板「点空白回到全部」）
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: _results(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.sm,
        children: [
          for (final t in _types)
            FilterChip(
              label: Text(ContentCard.labelOf(t)),
              avatar: Icon(ContentCard.iconOf(t), size: 16),
              selected: _type == t,
              onSelected: (_) => _setType(t),
            ),
        ],
      ),
    );
  }

  Widget _results() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final hasFilter = _type != null || _ctrl.text.trim().isNotEmpty;
    if (!hasFilter) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search,
                size: 48, color: Theme.of(context).colorScheme.outlineVariant),
            const SizedBox(height: Insets.md),
            Text(
              '输入关键词搜索\n或点上方类型浏览',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的条目',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return MasonryGridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: Insets.sm,
      crossAxisSpacing: Insets.sm,
      padding: const EdgeInsets.all(Insets.md),
      itemCount: _items.length,
      itemBuilder: (context, i) =>
          ContentCard(item: _items[i], onTap: () => _open(_items[i])),
    );
  }
}
