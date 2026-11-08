library;

import 'package:app_debug_bridge/app_debug_bridge.dart' show DebugRouteRegistry;
import 'package:flutter/material.dart';

import '../pages/mcp_page.dart';
import 'goodshare_app_refs.dart';

/// 调试可达页面白名单（宿主页面清单；公共包只认名字，不认业务）。
///
/// `McpPage` 是拾贝自带的 MCP 服务页（开关 / 端点 / 令牌 / 接入指南），借调试桥的
/// `navigate` 开放为调试期可达（release 编译剔除，不影响生产入口）。
final DebugRouteRegistry goodshareDebugRouteRegistry = DebugRouteRegistry(
  <String, WidgetBuilder>{
    'mcp': (_) => McpPage(controller: goodshareMcpController),
  },
);
