import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app/lifecycle_manager.dart';
import '../data/repository.dart';

/// 结构性约束：所有「读取仓库数据的页面」通过 `with RepoAutoReload` 自动订阅
/// [Repository] 变更通知，保证 MCP / 后台 / AI 管线写入后前台实时刷新
/// （见 goodshare-ui 规范「响应式数据流」）。
///
/// 子类须：
/// - 提供 [repo]（通常 `Repository get repo => widget.repo;`）；
/// - 实现 [reload]（重取数据并 setState；由本 mixin 作为仓库监听器调用）。
///
/// 无需手动 `addListener` / `removeListener`——`initState` / `dispose` 已托管，杜绝漏退订。
/// 新读页一律 `with` 本 mixin，取代散落的 `repo.addListener` 样板（见 epic 决策 1）。
mixin RepoAutoReload<T extends StatefulWidget> on State<T> {
  Repository get repo;

  void reload();

  /// 兜底「跨 isolate / 跨进程写回」：goodhub 经 Binder 后台 isolate 的 `Repository`
  /// 写库时，本进程 `Repository` 不会 `notifyListeners`，故订阅 `onResumed` 在回到
  /// 前台时统一重读（见 `mcp_binder_entrypoint.dart` 红线；典型漏刷新症状：goodhub
  /// 消费后详情页仍显示「等待 Goodhub 启动」）。
  StreamSubscription<AppLifecycleState>? _resumedSub;

  @override
  void initState() {
    super.initState();
    repo.addListener(reload);
    _resumedSub = AppLifecycleManager.instance.onResumed.listen((_) {
      if (mounted) reload();
    });
  }

  @override
  void dispose() {
    _resumedSub?.cancel();
    repo.removeListener(reload);
    super.dispose();
  }
}
