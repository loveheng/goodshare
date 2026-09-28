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
  /// [force] = true 用于用户在前台主动触发（如「重新处理」）：跳过设备状态门控立即处理。
  Future<int> pollOnce({bool force = false}) async {
    if (_busy) return 0;
    _busy = true;
    var processed = 0;
    try {
      while (true) {
        // force=true 时无视 canProcess（省电/内存门控），确保用户主动操作有响应
        if (!force && canProcess != null && !(await canProcess!())) break; // 设备状态不允许则停手
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
        humanMd: item.humanMd,
        rawFilePath: item.rawFilePath,
        taskAction: task['task_action'] as String?,
      );
      final impl = await _registry.resolve(input);
      // 超时兜底：任一实现挂起（如 Sherpa 转写在部分机型不返回）都会永久占住
      // _busy 与任务心跳，导致队列堵死、后续条目（含图片 OCR）永远不被消费。
      // 超时降级为「占位完成」，与项目「降级不卡死」口径一致。
      final result = await impl.reconstruct(input).timeout(
            const Duration(seconds: 60),
            onTimeout: () => ReconstructResult(
              humanMd: input.rawContent ?? '',
              // 超时也是「静默成功」：任务记 completed 却零产出，用户/AI 会误判正常。
              // 按 R1/R3 必须明说——降级完成也要带原因（2026-09-28 决策）。
              note: '处理超时（60s 未结束），已降级为占位完成，未执行 AI 重构'
                  '（可手动重试，或在设置中触发对应 AI 动作）',
            ),
          );
      // 经 Handler 特权入口回写（machine_json 过 Schema、item_type 变更受 AI 特权约束），
      // 与 UI / MCP 共用同一落库出口；落库复用 repo 通知驱动前台刷新。
      // actor=pipeline 由本文件（管线传输层）指定，命令载荷本身无法伪造。
      await _handler.execute(ApplyAiResultCommand(item.id!, result), actor: CommandActor.pipeline);
      // 完成也带 note：「跑完了但没产出」必须有原因，否则用户分不清成功与失败
      await _repo.finishTask(taskId, 'completed', note: result.note);
    } catch (e) {
      debugPrint('[QueueConsumer] task failed: $e');
      await _repo.markItemFailed(item.id!);
      // 错误原因必须落库：否则只剩 debugPrint，人和 AI 都看不到到底为什么失败
      await _repo.finishTask(taskId, 'failed', note: '处理异常：$e');
    } finally {
      heartbeat.cancel();
    }
  }
}
