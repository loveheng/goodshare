import 'package:flutter/widgets.dart';

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

  @override
  void initState() {
    super.initState();
    repo.addListener(reload);
  }

  @override
  void dispose() {
    repo.removeListener(reload);
    super.dispose();
  }
}
