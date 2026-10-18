import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../mcp/mcp_server.dart' show kTaskQueuedFrame;

/// §3.12 通知桥的 Dart 侧（UI 主 isolate → 原生 → goodhub）。
///
/// 为什么必须有这根桥：goodhub 是 **Binder-only**，它的 `IMcpCallback` 注册在 Binder
/// 后台 isolate（`mcpBinderMain` 独占的 FlutterEngine，唯一持有 `onEventEmitter` 管道的
/// 地方）；而**所有任务入队都发生在 UI 主 isolate**（ItemActionHandler 各命令）。二者是
/// 两个独立 FlutterEngine，Dart 层无共享内存；但在 Android **同一进程**内，故借原生做
/// 一次单向信号跳板即可闭环（同进程 forwarding 由原生侧 [McpCallbackHub] 承担）。
///
/// 语义克制（对齐 §3.12 红线）：① 只传**一个无参信号帧**，不透业务数据；② fire-and-forget，
/// 不等返回值也**不回灌入队路径**（入队已提交，失败就退化为主机 catch-up）；③ 宿主未连接
/// 即静默丢弃——通知 best-effort，不承担正确性（§3.12.4「无通知能力 = 零影响」）。
class McpBridgeChannel {
  static const MethodChannel _channel = MethodChannel('goodshare/mcp_bridge');

  /// 向 goodhub 推 `task_queued`；无在线回调返回 false（调用方不重试——这就是 best-effort）。
  Future<bool> notifyTaskQueued() async {
    try {
      return await _channel.invokeMethod<bool>('notifyTaskQueued', kTaskQueuedFrame) ?? false;
    } on MissingPluginException {
      // 非 Android / 原生未接桥（桌面、单测）：静默降级为「无通知」。
      return false;
    } on PlatformException catch (e) {
      debugPrint('[DEGRADE] mcp_bridge_task_queued_failed code=${e.code}');
      return false;
    }
  }

  /// 单向派发（供 void 回调使用）：结果丢弃，不挂起调用方。
  void notifyTaskQueuedOnly() {
    unawaited(notifyTaskQueued());
  }
}
