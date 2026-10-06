import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../ui/confirm_dialog.dart';
import '../ui/feedback_views.dart';
import '../ui/repo_auto_reload.dart';
import '../ui/toast.dart';

/// 最近删除：保留期内可恢复或手动彻底删除；30 天后启动时自动物理清理。
class RecentDeletedPage extends StatefulWidget {
  const RecentDeletedPage({super.key, required this.handler, required this.repo});

  final ItemActionHandler handler;
  final Repository repo;

  @override
  State<RecentDeletedPage> createState() => _RecentDeletedPageState();
}

class _RecentDeletedPageState extends State<RecentDeletedPage> with RepoAutoReload {
  List<InboxItem> _items = [];
  bool _loading = true;

  /// 清空胶囊滚动隐显（与首页顶栏 D1 同向口径）：下滑（继续浏览）隐藏、
  /// 上滑（回看）与静止时显示——由用户滚动方向天然驱动，无手写阈值防抖。
  bool _clearVisible = true;

  @override
  Repository get repo => widget.repo;

  @override
  void reload() => _reload();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 滚动方向驱动清空胶囊隐显。
  bool _onUserScroll(UserScrollNotification n) {
    final v = n.direction != ScrollDirection.reverse;
    if (v != _clearVisible) setState(() => _clearVisible = v);
    return false;
  }

  Future<void> _reload() async {
    final items = await widget.handler.listDeleted();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  /// 写动作统一薄出口（R1：失败必须被感知）：SnackBar 弹原因，成功按需提示。
  Future<void> _run(Future<Object?> Function() action, String doneText) async {
    try {
      await action();
      if (mounted) {
        ToastManager.show(doneText, kind: ToastKind.success);
      }
    } on ActionException catch (e) {
      if (mounted) {
        ToastManager.show(e.message, kind: ToastKind.error);
      }
    }
    await _reload();
  }

  Future<void> _confirmClearAll() async {
    if (_items.isEmpty) return;
    final ok = await confirmDialog(
      context,
      title: '清空最近删除？',
      content: '将立即彻底删除全部 ${_items.length} 条，不可恢复。',
      confirmText: '清空',
      danger: true,
    );
    if (ok == true) {
      await _run(() => widget.handler.purgeAllDeleted(), '已清空');
    }
  }

  Future<void> _confirmDeleteForever(InboxItem it) async {
    final ok = await confirmDialog(
      context,
      title: '彻底删除这条？',
      content: '立即物理删除（含附件），不可恢复。',
      confirmText: '删除',
      danger: true,
    );
    if (ok == true) {
      await _run(() => widget.handler.execute(DeleteForeverCommand(it.id!)), '已彻底删除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // 出口=显式 ×（去箭头拍板的完整形态）
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('最近删除'),
      ),
      // 清空收底（2026-10-05 拍板）：破坏性动作离开顶栏高频区，落右下拇指区
      // 悬浮胶囊；滚动方向隐显（下滑浏览隐藏、上滑回看/静止显示）。
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onUserScroll,
        child: _loading
            ? const LoadingView()
            : _items.isEmpty
                ? const Center(child: EmptyStateView(text: '没有可恢复的条目'))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      final deletedAt = it.deletedAt == null
                          ? null
                          : DateTime.fromMillisecondsSinceEpoch(it.deletedAt!);
                      return ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(
                          it.preview.isEmpty ? '（无文本内容）' : it.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(deletedAt == null
                            ? '已删除'
                            : '删除于 ${deletedAt.month}-${deletedAt.day.toString().padLeft(2, '0')} '
                                '${deletedAt.hour}:${deletedAt.minute.toString().padLeft(2, '0')}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  _run(() => widget.handler.execute(RestoreCommand(it.id!)), '已恢复'),
                              child: const Text('恢复'),
                            ),
                            IconButton(
                              tooltip: '彻底删除',
                              icon: const Icon(Icons.delete_forever_outlined),
                              onPressed: () => _confirmDeleteForever(it),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
      // 右下悬浮胶囊（danger 实底禁半透明罩；空态禁用）。
      floatingActionButton: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _clearVisible && _items.isNotEmpty ? 1 : 0,
        child: IgnorePointer(
          ignoring: !_clearVisible || _items.isEmpty,
          child: FloatingActionButton.extended(
            heroTag: 'recent-deleted-clear',
            elevation: 2,
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
            onPressed: _confirmClearAll,
            icon: const Icon(Icons.clear_all),
            label: Text('清空全部（${_items.length}）'),
          ),
        ),
      ),
    );
  }
}
