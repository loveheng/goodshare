import 'dart:async';
import 'package:flutter/foundation.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../data/repository.dart';
import 'reconstructor.dart';

/// ai_task_queue 消费者（PRD 模块二 v1 脚手架）：轮询 pending 任务，
/// 经 ReconstructorRegistry 取实现做双态重构，把产出写回条目。
/// 失败：任务置 failed、条目 is_processed=-1（退避重试/死信属 V2 §3.5 范畴）。
class QueueConsumer {
  QueueConsumer(this._repo, this._registry, this._handler, {this.pollInterval = const Duration(seconds: 3)});

  final Repository _repo;
  final ReconstructorRegistry _registry;
  final ItemActionHandler _handler;
  final Duration pollInterval;

  /// 推理门控（第 3 档设备状态感知调度）：返回 false 时本次 poll 停止认领新任务，
  /// 任务停留 pending 等待时机（如低电量 / 内存压力下暂停，不抛异常）。null = 不门控。
  Future<bool> Function()? canProcess;

  Timer? _timer;
  bool _running = false;
  bool _busy = false;

  bool get isRunning => _running;

  /// 启动轮询；与 app 同生命周期（前台服务保活场景下持续消费）。
  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(pollInterval, (_) => pollOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  /// 回收僵尸任务（delegate Repository.reclaimStaleTasks）：将卡在 processing 的超时任务
  /// 重置为 pending，供前台轮询重新认领。冷启动与生命周期 resumed 各调一次。
  Future<int> reclaimStaleTasks() => _repo.reclaimStaleTasks();

  /// 排空当前 pending 任务（单条串行，防止并发写同一条目）。返回处理条数。
  Future<int> pollOnce() async {
    if (_busy) return 0;
    _busy = true;
    var processed = 0;
    try {
      while (true) {
        if (canProcess != null && !(await canProcess!())) break; // 设备状态不允许则停手
        final tasks = await _repo.pendingTasks(limit: 1);
        if (tasks.isEmpty) break;
        await _process(tasks.first);
        processed++;
      }
    } finally {
      _busy = false;
    }
    return processed;
  }

  Future<void> _process(Map<String, Object?> task) async {
    final taskId = task['task_id'] as String;
    final itemId = task['item_id'] as String;
    if (!await _repo.claimTask(taskId)) return; // 已被取消/认领，跳过

    final item = await _repo.byId(itemId, includeDeleted: true);
    if (item == null || item.isDeleted) {
      // 条目在入队后被删（软删已会取消任务，此处兜底竞态）
      await _repo.finishTask(taskId, 'cancelled');
      return;
    }

    // 心跳：端侧 AI 任务可能耗时较长，每 5s 刷新 updated_at，
    // 避免被 reclaimStaleTasks 误判为僵尸任务（进程被杀时心跳停，才会被回收）。
    final heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      _repo.touchTask(taskId);
    });
    try {
      final input = ReconstructInput(
        itemId: item.id!,
        itemType: item.itemType,
        sourceType: item.sourceType,
        rawContent: item.rawContent,
        rawFilePath: item.rawFilePath,
      );
      final impl = await _registry.resolve(input);
      final result = await impl.reconstruct(input);
      // 经 Handler 特权入口回写（machine_json 过 Schema、item_type 变更受 AI 特权约束），
      // 与 UI / MCP 共用同一落库出口；落库复用 repo 通知驱动前台刷新。
      // actor=pipeline 由本文件（管线传输层）指定，命令载荷本身无法伪造。
      await _handler.execute(ApplyAiResultCommand(item.id!, result), actor: CommandActor.pipeline);
      await _repo.finishTask(taskId, 'completed');
    } catch (e) {
      debugPrint('[QueueConsumer] task failed: $e');
      await _repo.update(item.id!, {'is_processed': -1});
      await _repo.finishTask(taskId, 'failed');
    } finally {
      heartbeat.cancel();
    }
  }
}
