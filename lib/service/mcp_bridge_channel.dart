import 'dart:async';
import 'dart:convert';

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

  /// 调试注入开关（联调设施 §G6，debug-only）：true = 全通道按「宿主不可达」
  /// 处理（onDeviceCall → null 环境态、notifyTaskQueued → false），供真机验收
  /// S1-S3（宿主未安装/未启动/未绑定）的**可重复注入**，免真实卸载/停止宿主——
  /// 两侧收敛行为与真实离线同路径（OnDeviceHostUnavailable / best-effort 丢弃）。
  /// 仅调试动作面（`host_sim`）置位；生产路径恒 false，零行为变化。
  static bool debugNotReady = false;

  /// 向 goodhub 推 `task_queued`；无在线回调返回 false（调用方不重试——这就是 best-effort）。
  Future<bool> notifyTaskQueued() async {
    if (debugNotReady) {
      debugPrint('[debug-sim] host offline injected → notifyTaskQueued 丢弃（best-effort）');
      return false;
    }
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

  /// W6-a 端侧算力双向调用（UI 主 isolate → 原生 → Binder isolate → 宿主）：
  /// [method] ∈ ai/complete | host/onDeviceTaskStatus（宿主契约 0.5.0——
  /// 2026-11-09 收编迁移：推理入口收口 ai/complete，拉取面仍私有）。
  /// 返回宿主 result 信封（含 content.text 联合态 JSON）；**null = 桥不可用**
  /// （非 Android / 宿主未连入 / 服务未拉起——调用方按「宿主离线」降级）。
  /// 宿主侧错误（配额/冷态拒绝/身份不可辨）以 [PlatformException] 抛出，
  /// 调用方按失败态显式收敛（降级语义显式可知，不静默吞）。
  Future<Object?> onDeviceCall(String method, Map<String, Object?> params) async {
    if (debugNotReady) {
      // 离线注入（host_sim）：与 bridge_not_ready 同归「环境态 null」，调用方
      // 按「宿主未连入」降级——模拟的是**结果**而非根因，两侧日志可辨识。
      debugPrint('[debug-sim] host offline injected → onDeviceCall($method) null');
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<String>(
        'onDeviceCall',
        {'method': method, 'paramsJson': jsonEncode(params)},
      );
      debugPrint('[mcp_bridge] onDeviceCall raw=${raw == null ? 'null' : raw.substring(0, raw.length > 400 ? 400 : raw.length)}');
      return raw == null ? null : jsonDecode(raw);
    } on MissingPluginException {
      // 非 Android / 原生未接桥（桌面、单测）：静默降级为「宿主不可用」。
      return null;
    } on PlatformException catch (e) {
      // bridge_not_ready 属环境态（宿主未连入）→ 归 null 降级；
      // 其余（bridge_timeout / bridge_error / 宿主 error 帧）属失败态 → 上抛。
      if (e.code == 'bridge_not_ready') {
        // 环境态降级为 null（UI 按宿主离线处理），留痕供联调定位（服务未拉起/
        // 引擎未就绪/已摘除三种根因在原生 McpBinderBridge 日志区分）。
        debugPrint('[DEGRADE] mcp_bridge_on_device_call not_ready（桥 channel 未 attach）');
        return null;
      }
      debugPrint('[DEGRADE] mcp_bridge_on_device_failed code=${e.code} msg=${e.message}');
      rethrow;
    }
  }
}
