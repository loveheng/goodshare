import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repository.dart';
import '../mcp/mcp_server.dart';
import '../update/remote_config_store.dart';
import 'foreground_task_init.dart';

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

  /// 调试端点：服务仅绑定 loopback（127.0.0.1），局域网不可达；
  /// 桌面端经 USB + `adb reverse tcp:8765 tcp:8765` 后访问该地址（内部调试用）。
  String get endpoint => 'http://127.0.0.1:$defaultPort/mcp';

  /// 打开 MCP 服务：前台服务保活（经统一协调器，与 AI 队列解绑）+ 启动内嵌 HTTP server。
  /// 返回 null 表示成功，否则为错误信息。
  Future<String?> enable() async {
    _lastError = null;
    try {
      // Binder 插件路径由 goodhub 随调随起、不依赖本前台服务；此处仅 HTTP 回退
      // （用户手动开启）需要保活，交由协调器与 AI 队列共享单实例、互不误杀。
      await ForegroundServiceCoordinator.instance.acquire(
        ForegroundServiceCoordinator.mcpTag,
        channelId: mcpFgChannelId,
        title: '拾贝 · MCP 服务运行中',
        text: '仅绑定 loopback（桌面端经 adb reverse 接入，见 app 内 MCP 页）',
      );
      _server ??= McpServer(
        repo: repo,
        tokenProvider: () => _token,
        // 配置热更：远程下发的 mcpInstructions 非空时覆盖内置说明
        instructionsProvider: () => RemoteConfigStore.instance.current.mcpInstructions,
      );
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

  /// 冷启动自动恢复：上次为开启状态则重新 enable（进程被杀/重装后无需手动开）。
  /// 失败不阻断启动，错误落 lastError 供 MCP 页展示（R1）。
  Future<void> restoreIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefEnabled) != true) return;
    final error = await enable();
    if (error != null) {
      debugPrint('[MCP] 冷启动自动恢复失败: $error');
    }
  }

  /// §3.12 任务通知的 **HTTP/SSE 承载**（桌面调试路）：供 UI 主 isolate 的通知 fan-out
  /// 调用；HTTP server 未运行（MCP 未开启）即静默 no-op——通知 best-effort，不承担正确性。
  ///
  /// 注：goodhub 真机主路径不经此维护isk（`goodhub` 是 Binder-only），走 `McpBridgeChannel`
  /// 的原生信号跳板；两承载由 app 组合根统一 fan-out，避免 `Repository.onTaskQueued`
  /// 单 hook 被互相覆盖。
  void notifyTaskQueued() {
    try {
      _server?.notifyTaskQueued();
    } catch (e) {
      debugPrint('[DEGRADE] task_queued_sse_dispatch_failed error=$e');
    }
  }

  Future<void> _shutdown() async {
    try {
      await _server?.stop();
    } catch (_) {/* 服务可能已停止 */}
    // 仅释放 MCP 的保活声明；若 AI 队列仍持有，协调器不会停止服务（#2 解绑）。
    try {
      await ForegroundServiceCoordinator.instance.release(ForegroundServiceCoordinator.mcpTag);
    } catch (_) {/* 协调器内部已容错 */}
    _server = null;
  }
}
