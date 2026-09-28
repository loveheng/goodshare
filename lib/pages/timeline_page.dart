import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../ui/drawer_menu_button.dart';
import '../models/item.dart';
import '../ui/content_card.dart';
import '../ui/repo_auto_reload.dart';
import 'item_detail_page.dart';

/// 时光机（首页）：按「天」分组的内容时间线（设计 §4.1）。
/// MVP/V2 阶段 daily_metrics 无数据（健康/日历 V3 接入），即纯内容分组线。
class TimelinePage extends StatefulWidget {
  const TimelinePage({
    super.key,
    required this.repo,
    required this.handler,
    required this.caps,
    this.onOpenDrawer,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final AiCapabilities caps; // 详情页翻译预检用
  final VoidCallback? onOpenDrawer;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> with RepoAutoReload {
  List<InboxItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  Repository get repo => widget.repo;

  @override
  void reload() => _reload();

  Future<void> _reload() async {
    final items = await widget.repo.list(limit: 500);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _dayLabel(DateTime day) {
    final today = DateTime.now();
    final diff = DateTime(today.year, today.month, today.day)
        .difference(DateTime(day.year, day.month, day.day))
        .inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final Widget body;
    if (_items.isEmpty) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('还没有收集'),
            const SizedBox(height: 4),
            Text('在任意 app 点「分享」→「拾贝」，或点下方「速记」',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    } else {
      // 按「天」分组（created_at 本机日期，倒序天序、正序条目）
      final days = <String, List<InboxItem>>{};
      for (final it in _items) {
        final d = DateTime.fromMillisecondsSinceEpoch(it.createdAt);
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        (days[key] ??= []).add(it);
      }
      final keys = days.keys.toList()..sort((a, b) => b.compareTo(a));
      body = RefreshIndicator(
        onRefresh: _reload,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: keys.length,
          itemBuilder: (context, i) {
            final key = keys[i];
            final dayItems = days[key]!;
            final day = DateTime.parse(key);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: [
                      Text(_dayLabel(day),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Text('${dayItems.length} 条', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                for (final it in dayItems)
                  ContentCard(
                    item: it,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ItemDetailPage(
                          repo: widget.repo,
                          handler: widget.handler,
                          item: it,
                          caps: widget.caps,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuLeading(widget.onOpenDrawer),
        title: const Text('时光机'),
      ),
      body: body,
    );
  }
}
