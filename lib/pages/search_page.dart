import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../ui/actions/item_actions.dart';
import '../ui/content_card.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/selection/selection_scope.dart';
import '../ui/tokens.dart';
import 'item_detail_page.dart';

/// 全屏搜索页（2026-09-30 改版，用户拍板）：点首页搜索框进入。
///
/// 结构：大搜索框（× 清空 / 空时关闭）→ 实时瀑布流结果（固定最新排序，
/// 用户拍板不要排序切换）。**类型入口 chips 已移除**（2026-10-03 用户拍板
/// 「去掉分类的筛选，现在没有分类了」）——搜索回归纯关键词。
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

  /// 批量选择模式（card-batch-selection §3.2 配置：搜索页=全量四动作）。
  final SelectionController _selection = SelectionController();

  Future<void> _onBatchAction(String actionId) => runSelectionBatch(
    context,
    handler: widget.handler,
    repo: widget.repo,
    selection: _selection,
    items: _items,
    actionId: actionId,
    vaultView: false,
  );

  Widget _gridCard(InboxItem it) => ContentCard(
    item: it,
    selected: _selection.isSelected(it.id!),
    onTap: () {
      if (_selection.active) {
        _selection.toggle(it.id!);
      } else {
        _open(it);
      }
    },
    onLongPress: () {
      HapticFeedback.lightImpact();
      _selection.enter(it.id!);
    },
  );

  /// 类型入口 chips 已移除（2026-10-03 用户拍板）：搜索纯关键词，
  /// 类型浏览由首页 tab 承担。
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
    _selection.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(
      query: _ctrl.text.trim(),
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
    return PopScope(
      // 返回手势先退选择模式，再退页面（card-batch-selection §2.1）。
      canPop: !_selection.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selection.exit();
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
          // 全面屏手势时代不需要返回箭头（用户拍板）；退出=右侧 × / 系统侧滑
          automaticallyImplyLeading: false,
          titleSpacing: Insets.sm,
          title: _selection.active
              ? SelectionHeaderRow(
                  controller: _selection,
                  onExit: _selection.exit,
                )
              : TextField(
                  controller: _ctrl,
                  autofocus: true,
                  onChanged: (_) => _reload(),
                  decoration: InputDecoration(
                    hintText: '搜索标题 / 正文 / 标签',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      // 全系统去胶囊（2026-10-01）：24 于输入框高即胶囊，改 xl20
                      borderRadius: BorderRadius.circular(Radii.xl),
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
            const Divider(height: 1),
            // 结果区：点空白处返回首页（用户拍板「点空白回到全部」）；
            // 选择模式中点空白=退出选择（模式出口优先于页面出口）。
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (_selection.active) {
                    _selection.exit();
                  } else {
                    Navigator.of(context).pop();
                  }
                },
                child: _results(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final hasFilter = _ctrl.text.trim().isNotEmpty;
    if (!hasFilter) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search,
              size: 48,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: Insets.md),
            Text(
              '输入关键词搜索',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('没有匹配的条目', style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return MasonryGridView.count(
      // 选择模式禁下拉刷新语义同全部页（搜索结果区无 RefreshIndicator，
      // 但滚动物理保持一致的手感）；卡片接选择态。
      physics: _selection.active
          ? const ClampingScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: Insets.sm,
      crossAxisSpacing: Insets.sm,
      padding: const EdgeInsets.all(Insets.md),
      itemCount: _items.length,
      itemBuilder: (context, i) => _gridCard(_items[i]),
    );
  }
}
