import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/lifecycle_manager.dart';
import '../data/repository.dart';
import '../service/foreground_task_init.dart';
import '../service/mcp_controller.dart';
import 'queue_consumer.dart';

/// 第 3 档：AI 队列后台常驻引擎。
///
/// 复用 [McpController] 已持有的单前台服务（flutter_foreground_task 仅支持单实例）
/// 保活主 isolate，使 OCR / 端侧转写 / 链接抓取等离线推理在 app 退后台后仍能继续消费
/// `ai_task_queue`；按设备状态（电量 / 充电）调度，并在内存压力下优雅中断（V2 §3.x）。
///
/// 生命周期：
/// - 退后台且有待处理任务且设备状态允许 → 拉起 / 复用前台服务（进程保活，consumer 的
///   3s 轮询继续跑），通知栏显示「AI 离线处理中（剩余 N 条）」；
/// - 回前台 → 若本服务独立持有前台服务且 MCP 未运行则停止（consumer 在前台照常跑）；
/// - 内存压力 → 暂停认领新任务 + 当前 processing 任务回滚 pending，待恢复后续跑，不崩溃。
class AiQueueService extends ChangeNotifier {
  AiQueueService({
    required this.repo,
    required this.consumer,
    required this.mcp,
  });

  final Repository repo;
  final QueueConsumer consumer;
  final McpController mcp;

  static const _prefBgProcess = 'ai_bg_process';

  final Battery _battery = Battery();
  BatteryState _batteryState = BatteryState.unknown;
  int _batteryLevel = 100;
  bool _memoryPressure = false;
  bool _isBackgrounded = false;
  bool _owningService = false; // 当前是否由本服务独立持有前台服务

  /// 设置开关：退后台是否继续 AI 处理（默认开）。
  bool backgroundProcessingEnabled = true;

  Timer? _progressTimer;
  Timer? _memoryResumeTimer;

  bool get isMemoryPressure => _memoryPressure;

  /// 设备状态是否允许推理。前台（用户正在使用 APP）时始终允许——用户主动操作
  /// 不应被省电门控静默丢弃；仅退后台的自动处理受电量 / 内存约束（V2 §3.x）。
  bool get inferenceAllowed => !_isBackgrounded || (_deviceOk && !_memoryPressure);

  /// 用户在前台主动触发（重新处理等）：绕过省电 / 内存门控，立即认领一次任务。
  /// 即便 consumer 因内存压力被 stop，也先重启再强制 poll，确保用户操作有响应。
  Future<void> kick() async {
    if (!consumer.isRunning) consumer.start();
    await consumer.pollOnce(force: true);
  }

  bool get _deviceOk =>
      _batteryState == BatteryState.charging ||
      _batteryState == BatteryState.full ||
      _batteryLevel >= 40;

  /// 装配：设备状态探测 + 生命周期订阅。替代 main 中内联的 consumer 启动 / 回收。
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    backgroundProcessingEnabled = prefs.getBool(_prefBgProcess) ?? true;

    try {
      _batteryState = await _battery.batteryState;
      _batteryLevel = await _battery.batteryLevel;
    } catch (_) {
      // 取不到（如桌面 / 模拟器）→ 维持默认 100% & unknown，视为可推理
    }
    _battery.onBatteryStateChanged.listen((s) {
      _batteryState = s;
      _onBatteryChanged();
    });

    // 注入推理门控：低电量 / 内存压力下暂停认领新任务，任务停留 pending
    consumer.canProcess = () async => inferenceAllowed;

    consumer.start();
    await consumer.reclaimStaleTasks();

    AppLifecycleManager.instance.onBackgrounded.listen((_) => _onBackgrounded());
    AppLifecycleManager.instance.onResumed.listen((_) => _onResumed());
    AppLifecycleManager.instance.onMemoryPressure.listen((_) => _onMemoryPressure());
  }

  Future<void> setBackgroundProcessingEnabled(bool v) async {
    backgroundProcessingEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefBgProcess, v);
    if (!v && _owningService && _isBackgrounded) {
      await _stopService();
    }
    notifyListeners();
  }

  /// 退后台：有待处理任务且设备状态允许 → 保活前台服务让队列继续消费。
  Future<void> _onBackgrounded() async {
    _isBackgrounded = true;
    if (!backgroundProcessingEnabled) return;
    if (!_deviceOk) return; // 低电量不保活，任务留待下次时机
    final pending = await repo.pendingCount();
    if (pending == 0) return;

    if (await FlutterForegroundTask.isRunningService) {
      // MCP 已持有前台服务，进程本身已保活，consumer 继续跑；不抢通知
      _owningService = false;
      return;
    }
    await ensureForegroundTaskInit();
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: '拾贝 · AI 离线处理中',
      notificationText: '剩余 $pending 条待处理',
    );
    _owningService = true;
    _startProgressTimer();
  }

  /// 回前台：本服务独立持有且 MCP 未运行则停止前台服务（consumer 在前台照常）。
  Future<void> _onResumed() async {
    _isBackgrounded = false;
    _stopProgressTimer();
    if (_owningService && !mcp.running) {
      await _stopService();
    }
    // 前台继续处理（并回收可能的僵尸任务）
    unawaited(consumer.reclaimStaleTasks());
    unawaited(consumer.pollOnce());
  }

  Future<void> _onBatteryChanged() async {
    if (!_deviceOk && _owningService && _isBackgrounded) {
      // 退后台期间电量跌破阈值：停止保活以省电，任务留待充电后续跑
      await _stopService();
    }
    notifyListeners();
  }

  /// 内存压力：暂停新任务认领 + 当前 processing 任务回滚 pending，待恢复续跑。
  Future<void> _onMemoryPressure() async {
    _memoryPressure = true;
    consumer.stop();
    await repo.reclaimStaleTasks(); // 当前处理中任务退回 pending，下次续跑
    notifyListeners();
    _memoryResumeTimer?.cancel();
    _memoryResumeTimer = Timer(const Duration(seconds: 60), _resumeAfterMemory);
  }

  void _resumeAfterMemory() {
    _memoryPressure = false;
    if (!consumer.isRunning) consumer.start();
    notifyListeners();
  }

  Future<void> _stopService() async {
    _stopProgressTimer();
    _owningService = false;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // 服务可能已被 MCP 或系统停止
    }
  }

  void _startProgressTimer() {
    _stopProgressTimer();
    _progressTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_owningService) return;
      final pending = await repo.pendingCount();
      if (pending == 0) {
        // 队列已空：停止保活（进程回前台或交还系统调度）
        await _stopService();
        return;
      }
      try {
        await FlutterForegroundTask.updateService(
          notificationText: '剩余 $pending 条待处理',
        );
      } catch (_) {
        // 通知更新失败不阻塞队列
      }
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }
}
