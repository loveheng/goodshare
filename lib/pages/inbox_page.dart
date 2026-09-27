import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../share/text_collector.dart';
import '../ui/content_card.dart';
import 'item_detail_page.dart';
import 'quick_note_sheet.dart';

/// 全部（分类视图）：顶部固定搜索 + 类型 FilterChip，条目按 item_type 分组带计数，
/// 每个分类可直接添加对应内容（设计 §4.7）。
/// 时间轴视图随 V3 与时光机分化后再加入（F5 决策，MVP/V2 仅分类视图）。
class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.repo,
    required this.handler,
    required this.collector,
    required this.caps,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final AiCapabilities caps;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final _searchCtrl = TextEditingController();
  String? _type;
  List<InboxItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.repo.removeListener(_reload);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.repo.list(query: _searchCtrl.text, type: _type, limit: 500);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onSearchChanged(String _) => _reload();

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
    final groups = <String, List<InboxItem>>{};
    for (final it in _items) {
      (groups[it.itemType] ??= []).add(it);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) => groups[b]!.length.compareTo(groups[a]!.length));

    return Scaffold(
      appBar: AppBar(
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
                    FilterChip(
                      label: const Text('全部'),
                      selected: _type == null,
                      onSelected: (_) {
                        setState(() => _type = null);
                        _reload();
                      },
                    ),
                    const SizedBox(width: 8),
                    for (final t in InboxItem.allTypes)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          avatar: Icon(ContentCard.iconOf(t), size: 16),
                          label: Text(ContentCard.labelOf(t)),
                          selected: _type == t,
                          onSelected: (_) {
                            setState(() => _type = _type == t ? null : t);
                            _reload();
                          },
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
          : _items.isEmpty
              ? Center(
                  child: Text('没有匹配的收集', style: Theme.of(context).textTheme.bodySmall),
                )
              : RefreshIndicator(
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
                                const Spacer(),
                                // 分类内直接添加对应内容（设计 §4.7 分类添加）
                                IconButton(
                                  tooltip: '添加${ContentCard.labelOf(type)}',
                                  icon: const Icon(Icons.add_circle_outline),
                                  onPressed: () => showModalBottomSheet<void>(
                                    context: context,
                                    showDragHandle: true,
                                    isScrollControlled: true,
                                    builder: (_) => QuickNoteSheet(
                                      repo: widget.repo,
                                      collector: widget.collector,
                                      caps: widget.caps,
                                      initialType: type,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          for (final it in list) ContentCard(item: it, onTap: () => _open(it)),
                        ],
                      );
                    },
                  ),
                ),
    );
  }
}
