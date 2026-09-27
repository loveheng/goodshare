import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import 'reconstructor.dart';

/// ai_task_queue 消费者（PRD 模块二 v1 脚手架）：轮询 pending 任务，
/// 经 ReconstructorRegistry 取实现做双态重构，把产出写回条目。
/// 失败：任务置 failed、条目 is_processed=-1（退避重试/死信属 V2 §3.5 范畴）。
class QueueConsumer {
  QueueConsumer(this._repo, this._registry, {this.pollInterval = const Duration(seconds: 3)});

  final Repository _repo;
  final ReconstructorRegistry _registry;
  final Duration pollInterval;

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

  /// 排空当前 pending 任务（单条串行，防止并发写同一条目）。返回处理条数。
  Future<int> pollOnce() async {
    if (_busy) return 0;
    _busy = true;
    var processed = 0;
    try {
      while (true) {
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

    try {
      final impl = await _registry.resolve();
      final result = await impl.reconstruct(ReconstructInput(
        itemId: item.id!,
        itemType: item.itemType,
        sourceType: item.sourceType,
        rawContent: item.rawContent,
        rawFilePath: item.rawFilePath,
      ));
      await _repo.update(item.id!, {
        'human_md': result.humanMd,
        'is_processed': 1,
        if (result.machineJson != null) 'machine_json': jsonEncode(result.machineJson),
        if (result.tags.isNotEmpty) 'tags': jsonEncode(result.tags),
        // AI 重分类走管线特权路径，不受手动/MCP 白名单约束（V2 §3.8）
        if (result.itemType != null && result.itemType != item.itemType)
          'item_type': result.itemType,
        if (result.facets != null) 'facets_json': jsonEncode(result.facets),
      });
      await _repo.finishTask(taskId, 'completed');
    } catch (e) {
      debugPrint('[QueueConsumer] task failed: $e');
      await _repo.update(item.id!, {'is_processed': -1});
      await _repo.finishTask(taskId, 'failed');
    }
  }
}
