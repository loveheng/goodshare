import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/repository.dart';
import 'mcp/mcp_server.dart';

/// goodshare 本地 Binder 插件后台入口（headless FlutterEngine）。
///
/// 部署点：goodhub 经 `bindService(BIND_AUTO_CREATE)` 拉起 [McpBinderService]
/// （原生侧），原生侧创建独立 FlutterEngine 并执行本 entrypoint；本 isolate 持有
/// 独立 `McpServer`/`Repository`，经 MethodChannel `goodshare/mcp_binder` 把
/// `call(json)` 转现有 [McpServer.handleJsonRpc]（协议无关，与 HTTP 版同一套
/// `_dispatch`）。见 docs/design/goodhub-local-plugin.md #1、goodhub 契约
/// thirdconnect.md §1.2.2。
///
/// 设计红线：
/// - Binder 走同签名 `signature` 权限，零端口、零 `X-Api-Key` → [McpServer.tokenProvider] 恒 null。
/// - 本 isolate 与 MainActivity 主 isolate 互相独立（各自一套 McpServer/Repository，
///   sqlite WAL 下安全），故 Binder 路径不依赖 app 是否在前台——满足「随调随起」。
const _kChannel = 'goodshare/mcp_binder';

@pragma('vm:entry-point')
void mcpBinderMain() {
  // 后台 isolate 无 UI，但 MethodChannel 需要 ServicesBinding 初始化。
  WidgetsFlutterBinding.ensureInitialized();

  // 仓库懒初始化（首次 DB 访问开库）；与主 isolate 共享同一 goodshare.db 文件。
  final repo = Repository();
  final server = McpServer(
    repo: repo,
    tokenProvider: () => null, // Binder 同签名零鉴权
  );

  final channel = MethodChannel(_kChannel);
  // Binder 插件→宿主事件发射器（#4/#5）：Dart 侧经原生 `pushEvent` 通道转
  // `IMcpCallback.onEvent` 推给 goodhub（progress / 反向请求 / `_async` 终帧）。
  server.onEventEmitter = (payload) {
    channel.invokeMethod<void>('pushEvent', payload);
  };
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'dispatch':
        // 同步 JSON-RPC 请求 → 响应字符串；长任务（>5s）走 `_async` + onEvent 终帧（#4）。
        return await server.handleJsonRpc(call.arguments as String);
      case 'answerReverse':
        // 宿主回答本插件经 onEvent 发出的反向请求（sampling 闭环，#5）。
        server.answerReverse(call.arguments as String);
        return null;
      case 'hostCallbackReady':
        // 宿主已注册 IMcpCallback（registerCallback），onEvent 通道可用（#4/#5）。
        // 原生 pushEvent 在 callback 为 null 时静默丢弃，此处仅作可观测标记。
        return null;
      default:
        throw PlatformException(code: 'not_implemented', message: call.method);
    }
  });

  // 通知原生侧引擎就绪，解除 McpBinderService.call 首调竞态等待。
  // 用 microtask 确保上面 handler 已注册后再发 ready。
  scheduleMicrotask(() => channel.invokeMethod<void>('ready'));
}
