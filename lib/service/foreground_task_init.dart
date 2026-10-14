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

/// 拾贝前台服务统一协调器（flutter_foreground_task 仅单实例）。
///
/// MCP(HTTP 回退) 与 AI 队列各自独立 [acquire]/[release] 自己的保活需求
/// （#2：二者生命周期解耦）——服务在任一持有者存活时运行，最后一个
/// release 时停止。由此 MCP 的 disable 不再误杀 AI 的后台推理保活，AI 也
/// 不再复用/依赖 MCP 的前台服务。
///
/// 通知优先级：mcp（用户主动开启、想看端点，DEFAULT 档）> ai（后台长任务，LOW 档）。
class ForegroundServiceCoordinator {
  ForegroundServiceCoordinator._();

  static final ForegroundServiceCoordinator instance = ForegroundServiceCoordinator._();

  /// MCP(HTTP 回退) 持有者标签。
  static const String mcpTag = 'mcp';

  /// AI 队列后台推理保活持有者标签。
  static const String aiTag = 'ai';

  final Set<String> _holders = {};
  final Map<String, _FgSpec> _specs = {};

  /// 持有者声明保活需求。首次持有 → 拉起服务；已有持有者 → 按优先级重渲染通知
  /// （不重复 start，避免「服务已运行」异常）。
  Future<void> acquire(
    String tag, {
    required String channelId,
    required String title,
    required String text,
  }) async {
    final wasEmpty = _holders.isEmpty;
    _holders.add(tag);
    _specs[tag] = _FgSpec(channelId: channelId, title: title, text: text);
    if (wasEmpty) {
      // 服务可能因进程被系统回收而仍在运行（通知残留），先查再拉起，避免重复 start。
      if (!(await FlutterForegroundTask.isRunningService)) {
        await ensureForegroundTaskInit(channelId: channelId);
        await FlutterForegroundTask.startService(
          serviceTypes: [ForegroundServiceTypes.dataSync],
          notificationTitle: title,
          notificationText: text,
        );
      }
    } else {
      await _render();
    }
  }

  /// 持有者释放保活需求。最后释放 → 停止服务；否则按优先级重渲染通知。
  Future<void> release(String tag) async {
    if (!_holders.remove(tag)) return;
    _specs.remove(tag);
    if (_holders.isEmpty) {
      try {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
      } catch (_) {/* 服务可能已被系统/其他持有者停止 */}
    } else {
      await _render();
    }
  }

  /// 运行中更新某持有者通知文案（如 AI 剩余条数变化）；非当前展示标签则跳过。
  Future<void> update(String tag, {required String title, required String text}) async {
    final s = _specs[tag];
    if (s == null) return;
    _specs[tag] = _FgSpec(channelId: s.channelId, title: title, text: text);
    if (_holders.contains(tag)) await _render();
  }

  /// 按优先级选当前展示的通知（mcp > ai）并重渲染；无持有者则不动。
  Future<void> _render() async {
    if (_holders.isEmpty) return;
    final tag = _holders.contains(mcpTag) ? mcpTag : aiTag;
    final s = _specs[tag];
    if (s == null) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: s.title,
        notificationText: s.text,
      );
    } catch (_) {/* 通知更新失败不阻塞 */}
  }
}

class _FgSpec {
  const _FgSpec({required this.channelId, required this.title, required this.text});
  final String channelId;
  final String title;
  final String text;
}
