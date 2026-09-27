import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repository.dart';
import '../mcp/mcp_server.dart';
import '../util/lan_ip.dart';

/// MCP 服务总控：token 与开关持久化 + 内嵌 HTTP server + 前台服务保活。
class McpController extends ChangeNotifier {
  McpController({required this.repo});

  final Repository repo;

  static const defaultPort = 8765;
  static const _prefToken = 'mcp_token';
  static const _prefEnabled = 'mcp_enabled';

  McpServer? _server;
  String? _token;
  String? _lastError;

  bool get running => _server?.running ?? false;
  int get port => _server?.port ?? defaultPort;
  String? get token => _token;
  String? get lastError => _lastError;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_prefToken);
    if (_token == null || _token!.isEmpty) {
      _token = _generateToken();
      await prefs.setString(_prefToken, _token!);
    }
  }

  Future<void> regenerateToken() async {
    _token = _generateToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefToken, _token!);
    notifyListeners();
  }

  String _generateToken() {
    final rnd = Random.secure();
    return List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  /// 当前 LAN 端点；无 Wi-Fi 时回退 127.0.0.1（仅 adb reverse 场景可用）。
  Future<String> endpoint() async {
    final ip = await lanIpv4();
    return 'http://${ip ?? '127.0.0.1'}:$defaultPort/mcp';
  }

  /// 打开 MCP 服务：前台服务保活 + 启动内嵌 HTTP server。
  /// 返回 null 表示成功，否则为错误信息。
  Future<String?> enable() async {
    _lastError = null;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'goodshare_mcp',
          channelName: 'MCP 服务',
          channelDescription: '拾贝收集器的 MCP 服务运行通知',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(showNotification: true),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
        ),
      );
      final addr = await lanIpv4();
      await FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationTitle: '拾贝 · MCP 服务运行中',
        notificationText: 'http://${addr ?? '127.0.0.1'}:$defaultPort/mcp（地址见 app 内 MCP 页）',
      );
      _server ??= McpServer(repo: repo, tokenProvider: () => _token);
      await _server!.start(port: defaultPort);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabled, true);
    } catch (e) {
      _lastError = '$e';
      await _shutdown();
      notifyListeners();
      return _lastError;
    }
    notifyListeners();
    return null;
  }

  Future<void> disable() async {
    await _shutdown();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, false);
    notifyListeners();
  }

  Future<void> _shutdown() async {
    try {
      await _server?.stop();
    } catch (_) {/* 服务可能已停止 */}
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {/* 前台服务可能未在运行 */}
    _server = null;
  }
}
