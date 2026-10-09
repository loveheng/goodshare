import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 拾贝前台服务统一通道（MCP 服务与 AI 队列共用同一前台服务单实例）。
///
/// `flutter_foreground_task` 仅支持单个前台服务实例；通道按「谁在拉起」分档：
/// - **MCP**：专用 [mcpFgChannelId]（DEFAULT 重要性，2026-10-09 拍板——用户
///   显式开启、期待可感知，抽屉置顶但不横幅轰炸）；
/// - **AI 队列**：[fgChannelId]（LOW，后台长任务安静为宜）。
///
/// 通道在 Android 8+ 首建后重要性不可改，故 init 按通道幂等：拉起前以目标
/// 通道调 [ensureForegroundTaskInit]，通道不同且服务未运行时重注册（插件
/// init 是全局覆写，服务运行中不可换——调用方保证先查 isRunningService）。
const String fgChannelId = 'goodshare_fg';
const String fgChannelName = '拾贝后台任务';
const String fgChannelDesc = '拾贝收集器后台 AI 离线推理通知';

const String mcpFgChannelId = 'goodshare_fg_mcp';
const String mcpFgChannelName = '拾贝 MCP 服务';
const String mcpFgChannelDesc = 'MCP 服务运行状态与端点通知';

String? _initializedChannel;

/// 按通道幂等初始化前台服务：[channelId] 缺省 = AI 低重要性通道。
/// MCP 拉起前传 [mcpFgChannelId]（DEFAULT 档）。
Future<void> ensureForegroundTaskInit({String? channelId}) async {
  final ch = channelId ?? fgChannelId;
  if (_initializedChannel == ch) return;
  final isMcp = ch == mcpFgChannelId;
  _initializedChannel = ch;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: ch,
      channelName: isMcp ? mcpFgChannelName : fgChannelName,
      channelDescription: isMcp ? mcpFgChannelDesc : fgChannelDesc,
      channelImportance: isMcp
          ? NotificationChannelImportance.DEFAULT
          : NotificationChannelImportance.LOW,
      priority: isMcp
          ? NotificationPriority.DEFAULT
          : NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: true),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      // MCP 服务须在 Doze 深度休眠下仍可应答桌面客户端：持 CPU 锁防 accept 线程
      // 被挂起，持 Wi-Fi 锁防 Wi-Fi 休眠断链（实测 force-idle 下无锁即假死超时）。
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}
