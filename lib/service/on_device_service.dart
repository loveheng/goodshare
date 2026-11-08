import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/lifecycle_manager.dart';
import 'mcp_bridge_channel.dart';

/// W6-a 端侧算力联合态回执（SSOT = ai-app-split.md §3.11.2 /
/// goodhub `on-device-residency.md` 第七节）。
///
/// 联合态装进现有 JSON 信封：宿主 result 的 `content.text` 为
/// - 同步直出（温热）→ 纯文本推理结果（[OnDeviceImmediate]）；
/// - 冷态入池（`allow_deferred: true` 显式 opt-in）→ JSON
///   `{"execution_mode":"deferred","task_id":"…","status":"queued","expiry_ms":…}`
///   （[OnDeviceDeferred]）。
///
/// 解析纪律：text 须为**含 `execution_mode` 键且值为 `"deferred"` 的 JSON 对象**
/// 才判联合态——同步产出本身可能是 JSON（模型输出），禁 JSON 嗅探误判；
/// deferred 回执缺 `task_id` = 宿主契约违约，抛错显式暴露（禁静默降级）。
sealed class OnDeviceOutcome {
  const OnDeviceOutcome();

  factory OnDeviceOutcome.parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return OnDeviceImmediate(text);
    }
    if (decoded is! Map || decoded['execution_mode'] != 'deferred') {
      return OnDeviceImmediate(text);
    }
    final taskId = decoded['task_id'];
    if (taskId is! String || taskId.isEmpty) {
      throw ArgumentError('on_device_complete deferred 回执缺 task_id（宿主契约违约）：$text');
    }
    return OnDeviceDeferred(
      taskId: taskId,
      status: decoded['status'] is String ? decoded['status'] as String : 'queued',
      expiryMs: (decoded['expiry_ms'] is num) ? (decoded['expiry_ms'] as num).toInt() : -1,
    );
  }
}

/// 同步直出（温热态）：[text] 即最终推理结果。
final class OnDeviceImmediate extends OnDeviceOutcome {
  const OnDeviceImmediate(this.text);
  final String text;
}

/// 冷态入池回执（queued）：不阻塞调用方，后续经 [OnDeviceAsyncService]
/// 以 [taskId] 经 Pull 取结果（Pull = 交付真理源，Push best-effort 不依赖）。
final class OnDeviceDeferred extends OnDeviceOutcome {
  const OnDeviceDeferred({
    required this.taskId,
    required this.status,
    required this.expiryMs,
  });
  final String taskId;
  final String status; // 'queued'
  /// 宿主下发的剩余保质期（毫秒）；未携带为 -1（不可作过期判据，以 status 为准）。
  final int expiryMs;
}

/// 宿主不可用（环境态）：桥未就绪 / 宿主未连入——UI 按「宿主离线」降级，
/// 与宿主侧失败（配额/拒绝）区分（后者经 [PlatformException] 上抛）。
class OnDeviceHostUnavailable implements Exception {
  const OnDeviceHostUnavailable([this.message = '宿主未连入']);
  final String message;
  @override
  String toString() => 'OnDeviceHostUnavailable: $message';
}

/// Deferred 任务本地登记（W6-a 持久化）：宿主侧 WAL 是唯一任务事实，
/// 本表是**消费端占位上下文**——App 重启后仍能按 taskId 续 Pull，
/// 并据此做结果归属（itemId）与时效校验（bodyMd5）。
///
/// 不存 input 全文（宿主已持有请求载荷；本地只留可观测摘要）。
class OnDeviceTaskRecord {
  const OnDeviceTaskRecord({
    required this.taskId,
    required this.itemId,
    required this.bodyMd5,
    required this.instruction,
    required this.createdAtMs,
    required this.expiryAtMs,
  });

  final String taskId;
  final String itemId;
  /// 提交时刻条目正文指纹（item.bodyMd5）：结果到达时比对，正文已变 → stale 收敛。
  final String bodyMd5;
  /// 任务指令摘要（日志/调试展示用，非交付载荷）。
  final String instruction;
  final int createdAtMs;
  final int expiryAtMs;

  Map<String, Object?> toJson() => {
        'taskId': taskId,
        'itemId': itemId,
        'bodyMd5': bodyMd5,
        'instruction': instruction,
        'createdAtMs': createdAtMs,
        'expiryAtMs': expiryAtMs,
      };

  factory OnDeviceTaskRecord.fromJson(Map<String, Object?> j) => OnDeviceTaskRecord(
        taskId: j['taskId'] as String,
        itemId: j['itemId'] as String,
        bodyMd5: j['bodyMd5'] as String,
        instruction: j['instruction'] as String? ?? '',
        createdAtMs: (j['createdAtMs'] as num).toInt(),
        expiryAtMs: (j['expiryAtMs'] as num).toInt(),
      );
}

/// Deferred 任务终态事件（UI 收敛占位 → 结果/失败卡）。
class OnDeviceTaskEvent {
  const OnDeviceTaskEvent._(this.kind, this.taskId, this.itemId,
      {this.result, this.reason});

  factory OnDeviceTaskEvent.resultOf(String taskId, String itemId, String result) =>
      OnDeviceTaskEvent._(OnDeviceTaskEventKind.result, taskId, itemId, result: result);

  factory OnDeviceTaskEvent.failedOf(String taskId, String itemId, String reason) =>
      OnDeviceTaskEvent._(OnDeviceTaskEventKind.failed, taskId, itemId, reason: reason);

  factory OnDeviceTaskEvent.staleOf(String taskId, String itemId) =>
      OnDeviceTaskEvent._(OnDeviceTaskEventKind.stale, taskId, itemId,
          reason: '条目正文已变化，分析结果已过期');

  final OnDeviceTaskEventKind kind;
  final String taskId;
  final String itemId;
  final String? result;
  final String? reason;

  bool get isResult => kind == OnDeviceTaskEventKind.result;
  bool get isFailed => kind == OnDeviceTaskEventKind.failed;
  bool get isStale => kind == OnDeviceTaskEventKind.stale;
}

enum OnDeviceTaskEventKind { result, failed, stale }

/// W6-a 端侧异步消费服务（goodshare 消费端单点）。
///
/// 职责：① 联合态回执解析（[OnDeviceOutcome]）；② Deferred 任务登记与
/// 持久化（重启可续拉）；③ **Pull 轮询**——回前台批量拉 + 前台 30s 定时器
/// （No Active Polling 纪律：无独立后台线程，退后台即停）；④ 结果归属与
/// 时效收敛（bodyMd5 比对）→ [events] 事件流供 UI 消费。
///
/// 分层边界：本服务**不读 Repository**——正文指纹经 [init] 注入的只读
/// 端口取得（组合根 main.dart 装配），保持服务与数据层解耦（测试可注入 fake）。
class OnDeviceAsyncService {
  OnDeviceAsyncService({McpBridgeChannel? bridge}) : _bridge = bridge ?? McpBridgeChannel();

  /// UI 主 isolate 单例（main.dart 装配 init）。
  static final OnDeviceAsyncService instance = OnDeviceAsyncService();

  final McpBridgeChannel _bridge;

  static const String _prefKey = 'on_device.deferred.v1';
  /// 前台轮询间隔（W6 指令拍板：30s；退后台即停，不占后台资源）。
  static const Duration _pollInterval = Duration(seconds: 30);
  /// 宿主未携带 expiry_ms 时的本地兜底保质期（与宿主缺省 24h 同源）。
  static const int _defaultExpiryMs = 24 * 60 * 60 * 1000;

  final List<OnDeviceTaskRecord> _tasks = [];
  final Set<String> _inflight = {};
  bool _inited = false;
  bool _foreground = false;
  Timer? _timer;
  StreamSubscription<AppLifecycleState>? _lifecycleSub;
  late final StreamController<OnDeviceTaskEvent> _events =
      StreamController<OnDeviceTaskEvent>.broadcast();

  /// 结果到达时读当前正文指纹的端口（组合根注入 repo.byId → bodyMd5）。
  Future<String?> Function(String itemId)? _readBodyMd5;

  Stream<OnDeviceTaskEvent> get events => _events.stream;

  /// 待处理任务快照（UI 占位恢复用：页面打开时查本条目是否有在途 deferred）。
  List<OnDeviceTaskRecord> tasksForItem(String itemId) =>
      _tasks.where((t) => t.itemId == itemId).toList();

  /// 登记表快照（调试桥 /debug/state 消费）：值拷贝，不暴露内部列表引用；
  /// 空表 = 无在途 deferred（e2e 断言「摘登记/无残留」的状态真源）。
  List<Map<String, Object?>> tasksSnapshot() =>
      [for (final t in _tasks) t.toJson()];

  /// 装配（main.dart 一次）：载入持久化登记 + 挂生命周期（回前台即拉）。
  Future<void> init({Future<String?> Function(String itemId)? readBodyMd5}) async {
    if (_inited) return;
    _inited = true;
    _readBodyMd5 = readBodyMd5;
    await _load();
    // 过期清账先于事件订阅就位（重启后已过期任务直接收敛失败事件，防占位悬挂）。
    await _pruneExpired();
    _lifecycleSub = AppLifecycleManager.instance.onResumed.listen((_) {
      _foreground = true;
      _ensureTimer();
      unawaited(pollOnce());
    });
    AppLifecycleManager.instance.onBackgrounded.listen((_) {
      _foreground = false;
      _timer?.cancel();
      _timer = null;
    });
  }

  /// 发起端侧推理（反向 method `host/onDeviceComplete`）。
  /// [allowDeferred] = false 时宿主冷态走同步 failFast（存量语义零变化）。
  /// 抛错语义：[OnDeviceHostUnavailable]（环境态）/ [PlatformException]（宿主失败帧）。
  Future<OnDeviceOutcome> complete({
    required String instruction,
    required String input,
    bool allowDeferred = false,
  }) async {
    final env = await _bridge.onDeviceCall(
      'host/onDeviceComplete',
      {'instruction': instruction, 'input': input, 'allow_deferred': allowDeferred},
    );
    if (env == null) throw const OnDeviceHostUnavailable();
    final text = _extractText(env);
    if (text == null) {
      throw StateError('host/onDeviceComplete 回程缺 content.text（宿主契约违约）');
    }
    return OnDeviceOutcome.parse(text);
  }

  /// Deferred 回执登记（持久化）+ 确保轮询器就绪。
  Future<void> registerDeferred({
    required String taskId,
    required String itemId,
    required String bodyMd5,
    required String instruction,
    int? expiryMs,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiry = (expiryMs != null && expiryMs > 0)
        ? now + expiryMs
        : now + _defaultExpiryMs;
    _tasks.add(OnDeviceTaskRecord(
      taskId: taskId,
      itemId: itemId,
      bodyMd5: bodyMd5,
      instruction: instruction,
      createdAtMs: now,
      expiryAtMs: expiry,
    ));
    await _save();
    _ensureTimer();
  }

  /// 撤销本地占位（用户忽略 / 手动取消——宿主侧 queued 可撤接口宿主未开放，
  /// 本地摘除后该任务结果到达即无人认领，宿主到期清账兜底）。
  Future<void> dropTask(String taskId) async {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.taskId == taskId);
    if (_tasks.length != before) {
      await _save();
      _ensureTimer();
    }
  }

  /// 调试清表（联调设施 §G2 e2e 可重复性前置）：清空全部登记并持久化，
  /// 仅 debug 动作面（task_clear）消费——残留登记会让断言「登记数=1」类
  /// 用例不可重复；生产路径零调用。
  Future<void> clearForDebug() async {
    if (_tasks.isEmpty) return;
    _tasks.clear();
    await _save();
    _ensureTimer();
  }

  /// 单轮 Pull（回前台触发 + 前台 30s 周期）：逐任务拉取状态，终态收敛 + 持久化。
  Future<void> pollOnce() async {
    await _pruneExpired();
    final targets = _tasks.where((t) => !_inflight.contains(t.taskId)).toList();
    if (targets.isEmpty) return;
    // 并发拉取（各任务独立，宿主侧 M5 身份过滤互不可见）；单任务失败不影响其余。
    await Future.wait(targets.map(_pollOne));
  }

  Future<void> _pollOne(OnDeviceTaskRecord rec) async {
    _inflight.add(rec.taskId);
    try {
      final env =
          await _bridge.onDeviceCall('host/onDeviceTaskStatus', {'task_id': rec.taskId});
      if (env == null) return; // 宿主未连入：本轮跳过，下轮重试（不摘登记）
      final proj = _extractProjection(env);
      if (proj == null) return;
      final status = proj['status'];
      final failReason = proj['failReason'];
      switch (status) {
        case 'pendingDelivery':
        case 'delivered':
          // Pull 即交付（宿主 pendingDelivery 查询已置 delivered 并回结果）。
          final result = proj['result'];
          if (result is! String || result.isEmpty) return; // 产物未落账（理论不可达）
          await _deliver(rec, result);
          break;
        case 'queued':
        case 'running':
          break; // 在途：保持占位
        case 'expired':
          await _conclude(rec,
              event: OnDeviceTaskEvent.failedOf(rec.taskId, rec.itemId,
                  '任务已过期（宿主超过保质期清账）'));
          break;
        case 'failedExhausted':
          await _conclude(rec,
              event: OnDeviceTaskEvent.failedOf(
                  rec.taskId, rec.itemId,
                  (failReason is String && failReason.isNotEmpty)
                      ? '端侧推理失败（重试超限）：$failReason'
                      : '端侧推理失败（重试超限）'));
          break;
        case 'not_found':
          await _conclude(rec,
              event: OnDeviceTaskEvent.failedOf(
                  rec.taskId, rec.itemId, '任务不存在（宿主侧已清账）'));
          break;
        default:
          debugPrint(
              '[DEGRADE] on_device_status_unknown status=$status task=${rec.taskId}');
      }
    } on PlatformException catch (e) {
      // 宿主错误帧（身份不可辨/桥超时等）：本轮跳过，下轮重试（显式留痕不吞）。
      debugPrint(
          '[DEGRADE] on_device_poll_failed task=${rec.taskId} code=${e.code} msg=${e.message}');
    } finally {
      _inflight.remove(rec.taskId);
    }
  }

  /// 结果交付：bodyMd5 时效校验 → result 事件 + 摘登记。
  Future<void> _deliver(OnDeviceTaskRecord rec, String result) async {
    final reader = _readBodyMd5;
    if (reader != null) {
      final current = await reader(rec.itemId);
      if (current == null) {
        // 条目已删：无人认领，静默清账（页面不存在，事件无人消费）。
        await _conclude(rec, event: null);
        return;
      }
      if (current != rec.bodyMd5) {
        await _conclude(
            rec, event: OnDeviceTaskEvent.staleOf(rec.taskId, rec.itemId));
        return;
      }
    }
    await _conclude(rec,
        event: OnDeviceTaskEvent.resultOf(rec.taskId, rec.itemId, result));
  }

  Future<void> _conclude(OnDeviceTaskRecord rec, {OnDeviceTaskEvent? event}) async {
    _tasks.removeWhere((t) => t.taskId == rec.taskId);
    await _save();
    _ensureTimer();
    if (event != null && !_events.isClosed) _events.add(event);
  }

  /// 本地过期清账（expiryAtMs 已过 → failed 事件 + 摘登记）。
  Future<void> _pruneExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = _tasks.where((t) => t.expiryAtMs <= now).toList();
    for (final t in expired) {
      await _conclude(t,
          event: OnDeviceTaskEvent.failedOf(t.taskId, t.itemId, '任务已过期'));
    }
  }

  /// 轮询器纪律：仅前台 + 有待处理任务时运行（No Active Polling）。
  void _ensureTimer() {
    if (_foreground && _tasks.isNotEmpty && _timer == null) {
      _timer = Timer.periodic(_pollInterval, (_) => unawaited(pollOnce()));
    }
    if (!_foreground || _tasks.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final e in list) {
          if (e is Map<String, Object?>) {
            _tasks.add(OnDeviceTaskRecord.fromJson(e));
          }
        }
      }
    } catch (e) {
      // 脏数据兜底：清表重建（任务宿主侧为准，本地丢表不伤正确性，仅丢占位）。
      debugPrint('[DEGRADE] on_device_load_failed error=$e（已清表）');
      _tasks.clear();
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefKey, jsonEncode([for (final t in _tasks) t.toJson()]));
  }

  /// 宿主 result 信封 → content.text（联合态/投影的承载）。
  String? _extractText(Object? env) {
    if (env is! Map) return null;
    final content = env['content'];
    if (content is Map && content['text'] is String) return content['text'] as String;
    return null;
  }

  /// 宿主 result 信封 → content.text 的 JSON 投影（status 拉取）。
  Map<String, Object?>? _extractProjection(Object? env) {
    final text = _extractText(env);
    if (text == null) return null;
    try {
      final proj = jsonDecode(text);
      return proj is Map<String, Object?> ? proj : null;
    } catch (_) {
      return null;
    }
  }

  /// 测试/进程收尾：停轮询器 + 退订 + 关事件流。
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _lifecycleSub?.cancel();
    _lifecycleSub = null;
    await _events.close();
  }
}
