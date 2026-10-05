import 'dart:async';

import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../ui/confirm_dialog.dart';
import '../ui/feedback_views.dart';

/// AI 任务队列：查看端侧 AI 处理任务（OCR / 转写 / 链接抓取）的状态**并管理**。
///
/// - 状态可见：一眼分清「没入队 / 卡在 processing / 已完成但产出为空 / 失败」；
/// - 任务管理：启动（paused、failed、cancelled → pending 重新排队）/ 暂停（pending →
///   paused，不再被消费者认领）/ 删除（移出队列，**不删条目**）。删除需二次确认。
///
/// 任务状态变化不经过条目通知（[Repository] 只在条目变更时广播），故页面可见期间
/// 以 3s 轮询刷新，另有手动刷新。
class TaskQueuePage extends StatefulWidget {
  const TaskQueuePage({super.key, required this.repo});

  final Repository repo;

  @override
  State<TaskQueuePage> createState() => _TaskQueuePageState();
}

class _TaskQueuePageState extends State<TaskQueuePage> {
  List<Map<String, Object?>> _tasks = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _reload() async {
    final tasks = await widget.repo.listTasks();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 暂停：仅对「等待」中的任务生效（已在 processing 的不打断）。
  Future<void> _pause(String taskId) async {
    final ok = await widget.repo.pauseTask(taskId);
    _snack(ok ? '已暂停，不再自动处理' : '只有「等待」中的任务能暂停');
    await _reload();
  }

  /// 启动：把暂停 / 失败 / 已取消的任务重新放回队列。
  Future<void> _resume(String taskId) async {
    final ok = await widget.repo.resumeTask(taskId);
    _snack(ok ? '已启动，重新排队' : '该任务当前状态无法启动');
    await _reload();
  }

  Future<void> _confirmDelete(String taskId) async {
    final ok = await confirmDialog(
      context,
      title: '删除这个任务？',
      content: '仅从队列移除，不会删除对应条目。',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true) return;
    await widget.repo.deleteTask(taskId);
    _snack('已删除任务');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('AI 任务队列'),
      ),
      body: _loading
          ? const LoadingView()
          // 下拉刷新（含空态：AlwaysScrollable 保证空列表也能拉起）。
          : RefreshIndicator(
              onRefresh: _reload,
              child: _tasks.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 200),
                        Center(child: EmptyStateView(text: '暂无任务')),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _tasks.length,
                      itemBuilder: (context, i) {
                        final t = _tasks[i];
                        final id = t['task_id'] as String? ?? '';
                        return _TaskTile(
                          task: t,
                          onPause: () => _pause(id),
                          onResume: () => _resume(id),
                          onDelete: () => _confirmDelete(id),
                        );
                      },
                    ),
            ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  final Map<String, Object?> task;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;

  /// 状态 → 中文标签 + 语义色。
  (String, Color) _statusStyle(String status, ColorScheme scheme) => switch (status) {
        'pending' => ('等待', scheme.outline),
        'processing' => ('处理中', scheme.primary),
        // 暂停/完成强调色克制：走色阶与语义槽位，不用 Material 调色板字面量
        // （mymind 基准，ui-spec §2.1）。
        'paused' => ('已暂停', scheme.onSurfaceVariant),
        'completed' => ('完成', scheme.secondary),
        'failed' => ('失败', scheme.error),
        'cancelled' => ('已取消', scheme.outline),
        _ => (status, scheme.outline),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = task['status'] as String? ?? '?';
    final (label, color) = _statusStyle(status, scheme);
    final action = task['task_action'] as String?;
    final itemType = task['item_type'] as String?;
    final title = (task['human_title'] as String?)?.trim();
    final itemId = task['item_id'] as String? ?? '';
    final ts = task['updated_at'] as int?;
    final time = ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
    final note = task['last_note'] as String?;

    final parts = <String>[
      ...[itemType, action].whereType<String>(),
      if (time != null)
        '${time.month}-${time.day.toString().padLeft(2, '0')} '
            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    ];
    final subtitleLines = <String>[
      parts.join(' · '),
      if (note != null && note.isNotEmpty) '原因：$note',
      if (itemId.isNotEmpty) '条目 ${itemId.substring(0, 8)}',
    ];

    return ListTile(
      leading: Icon(
        switch (status) {
          'completed' => Icons.check_circle_outline,
          'failed' => Icons.error_outline,
          'processing' => Icons.sync,
          'paused' => Icons.pause_circle_outline,
          _ => Icons.schedule_outlined,
        },
        color: color,
      ),
      title: Text(
        (title == null || title.isEmpty) ? '（无标题条目）' : title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitleLines.join('\n'),
        style: note != null && note.isNotEmpty && status == 'failed'
            ? Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error)
            : null,
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              // R7：字号一律映射 M3 textTheme，不写裸 fontSize 字面量
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '任务操作',
            onSelected: (v) => switch (v) {
              'pause' => onPause(),
              'resume' => onResume(),
              _ => onDelete(),
            },
            itemBuilder: (_) => [
              if (status == 'pending')
                const PopupMenuItem(value: 'pause', child: Text('暂停')),
              if (status == 'paused' || status == 'failed' || status == 'cancelled')
                const PopupMenuItem(value: 'resume', child: Text('启动')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }
}
