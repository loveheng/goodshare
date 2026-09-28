import 'package:flutter/material.dart';

/// 顶层页面 AppBar 的 leading 按钮：打开主壳侧边抽屉（已开发功能入口聚合）。
/// 抽屉由 HomeShell 的 Scaffold 持有，这里只回调打开动作，不在页面内嵌导航状态。
Widget? drawerMenuLeading(VoidCallback? onOpen) {
  if (onOpen == null) return null;
  return IconButton(
    icon: const Icon(Icons.menu),
    tooltip: '功能菜单',
    onPressed: onOpen,
  );
}
