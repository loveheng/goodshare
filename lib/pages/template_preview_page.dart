import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../models/template.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/rich_text_view.dart';

/// 模板库（人类只读预览页，ai-template P1）：按 workspace 分组展示内容生产模板，
/// 点开渲染 body_md 完整样式（{{占位符}} 可见）。
///
/// **管理权归 AI**——本页无任何新建 / 编辑 / 删除入口（ADR：模板管理权归 AI、
/// 人类仅消费，是有意不对称；写仍走统一出口，分层只在触发权）。模板由 AI 经 MCP
/// create/update/delete_template 管理，此处仅供人类预览其结构化样式。
class TemplatePreviewPage extends StatefulWidget {
  const TemplatePreviewPage({super.key, required this.repo});

  final Repository repo;

  @override
  State<TemplatePreviewPage> createState() => _TemplatePreviewPageState();
}

class _TemplatePreviewPageState extends State<TemplatePreviewPage>
    with RepoAutoReload {
  bool _loading = true;
  List<(String, String)> _workspaces = const []; // (id, name)
  Map<String, List<Template>> _byWorkspace = {};

  @override
  Repository get repo => widget.repo;

  @override
  void reload() => _reload();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final wsList = await widget.repo.listWorkspaces();
    final all = await widget.repo.listTemplates();
    final grouped = <String, List<Template>>{};
    for (final t in all) {
      grouped.putIfAbsent(t.workspaceId, () => []).add(t);
    }
    if (!mounted) return;
    setState(() {
      _workspaces = [for (final w in wsList) (w.id, w.name)];
      _byWorkspace = grouped;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('模板库')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _byWorkspace.isEmpty
              ? _empty(theme)
              : ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '模板由 AI 管理，此处仅预览',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    for (final entry in _orderedGroups())
                      _workspaceSection(theme, entry.$1, entry.$2),
                  ],
                ),
    );
  }

  /// 有序分组：先按工作区列表顺序，其下挂模板；workspace 已被删的孤儿模板
  /// （template_id 松散关联，删模板不影响条目、删 workspace 级联清 templates——
  /// 但模板可能先于 workspace 删除竞态残留）兜底归「未知工作区」，不丢内容。
  List<(String, List<Template>)> _orderedGroups() {
    final known = <String>{};
    final result = <(String, List<Template>)>[];
    for (final (id, name) in _workspaces) {
      final ts = _byWorkspace[id];
      if (ts != null && ts.isNotEmpty) {
        result.add((name, ts));
        known.add(id);
      }
    }
    for (final entry in _byWorkspace.entries) {
      if (!known.contains(entry.key)) {
        result.add(('未知工作区', entry.value));
      }
    }
    return result;
  }

  Widget _empty(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.description_outlined,
                  size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('还没有模板', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '模板由 AI 经 MCP 创建与管理；创建后在此预览完整样式。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );

  Widget _workspaceSection(
      ThemeData theme, String wsName, List<Template> templates) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(wsName, style: theme.textTheme.titleSmall),
        ),
        for (final t in templates) _TemplateCard(template: t),
      ],
    );
  }
}

/// 单模板卡片：name + origin + version + 展开 body_md 渲染（只读，无编辑入口）。
class _TemplateCard extends StatefulWidget {
  const _TemplateCard({required this.template});

  final Template template;

  @override
  State<_TemplateCard> createState() => _TemplateCardState();
}

class _TemplateCardState extends State<_TemplateCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.template;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(t.name, style: theme.textTheme.titleSmall),
                  ),
                  _originBadge(theme, t.origin),
                ],
              ),
              if (t.description != null && t.description!.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  t.description!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                'v${t.version} · ${_expanded ? "点击收起" : "点击展开预览"}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_expanded) ...[
                const Divider(height: 16),
                RichTextView(markdown: t.bodyMd, shrinkWrap: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _originBadge(ThemeData theme, String origin) {
    final label = switch (origin) {
      'official' => '官方',
      'user' => '自建',
      _ => 'AI',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: theme.textTheme.labelSmall),
    );
  }
}
