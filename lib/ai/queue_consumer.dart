import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../data/block_artifacts.dart'
    show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import '../media/block_media.dart' show resolveBlockMediaPath;
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
    final taskAction = task['task_action'] as String?;
    // 块附件通道（block-artifact-workflow.md §2.5/§2.6）：block_* 任务豁免
    // aiProcess 门禁（手动即授权——UI 主体入队时动作层已按 actor 分叉校验过，
    // 到达队列的块任务必然是 ui 发起或已授权的），失败也不标条目 is_processed
    //（块任务的产物在块级，条目状态零触碰）。
    final blockParsed = Repository.parseBlockAction(taskAction);
    final isBlock = blockParsed != null;
    if (!await _repo.claimTask(taskId)) return; // 已被取消/认领，跳过

    final item = await _repo.byId(itemId, includeDeleted: true);
    if (item == null || item.isDeleted) {
      // 条目在入队后被删（软删已会取消任务，此处兜底竞态）
      await _repo.finishTask(taskId, 'cancelled');
      return;
    }

    // 管线回写授权门禁（ai-visibility 补丁）：人类笔记默认不授权管线处理，
    // 未开启「允许 AI 处理」则直接跳过该任务——不跑重建、不标失败，
    // 避免误判失败与空耗算力。原因落 note，UI 任务态/详情状态条可读到。
    // 块任务豁免（§2.6）：手动即授权；MCP 侧未授权的块任务在动作层入队前已被拒。
    if (!isBlock && !item.aiProcess) {
      await _repo.finishTask(
        taskId,
        'skipped',
        note: '未授权 AI 处理：在笔记详情开启「允许 AI 处理」后方可处理',
      );
      return;
    }

    // §6.1 防呆兜底：block 前缀但解析非法（伪造 key / 格式坏——动作层是唯一
    // 合法入队口，此为纵深防御）→ failed + note，**不得**静默落占位实现把
    // rawContent 写进 human_md。
    if (!isBlock &&
        taskAction != null &&
        Repository.blockActionHeads.any((h) => taskAction.startsWith('$h:'))) {
      await _repo.finishTask(
        taskId,
        'failed',
        note: 'block 任务动作串非法（block_key 须为正文媒体行的 local:// 路径），未执行',
      );
      return;
    }

    // 块任务输入源解析（§2.5）：块媒体绝对路径 + 块翻译/摘要的源产物文本。
    String? blockFilePath;
    String? blockSourceText;
    if (blockParsed != null) {
      // 顶级条目统一（§2.7）：block_key='item' 的媒体源就是条目 rawFilePath
      //（顶级音/视频区没有 local:// 媒体行）；行内块仍按 key 解析物理路径。
      blockFilePath = blockParsed.$2 == BlockArtifactKind.topLevelKey
          ? item.rawFilePath
          : await resolveBlockMediaPath(blockParsed.$2);
      if (blockParsed.$1 == 'block_translate') {
        final src = Repository.blockTranslateSourceKindOf(taskAction);
        if (src != null) {
          blockSourceText =
              (await _repo.blockArtifacts.get(itemId, blockParsed.$2, src))?.text;
        }
      } else if (blockParsed.$1 == 'block_summarize') {
        for (final kind in const [BlockArtifactKind.transcript, BlockArtifactKind.ocrText]) {
          final a = await _repo.blockArtifacts.get(itemId, blockParsed.$2, kind);
          final t = a?.text;
          if (t != null && t.trim().isNotEmpty) {
            blockSourceText = t;
            break;
          }
        }
      }
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
        taskAction: taskAction,
        humanTags: item.tags,
        blockKey: blockParsed?.$2,
        blockFilePath: blockFilePath,
        blockSourceText: blockSourceText,
      );
      final impl = await _registry.resolve(input);
      // 超时兜底：任一实现挂起（如 Sherpa 转写在部分机型不返回）都会永久占住
      // _busy 与任务心跳，导致队列堵死、后续条目（含图片 OCR）永远不被消费。
      // 超时降级为「占位完成」，与项目「降级不卡死」口径一致。
      // 端侧 LLM 任务单独放宽到 120s（设计 §5）：LLM 生成首 token + decode 数秒~数十秒，
      // 60s 对 1.5B 模型长输入偏紧。
      final isLlmTask = input.taskAction == Repository.taskLlmSummarize ||
          input.taskAction == Repository.taskLlmTags;
      // 切片任务 = 提区间音轨 + ASR + LLM 摘要三段串行，单独放宽到 180s（设计 video-clips.md）
      final isClipTask = input.taskAction?.startsWith(Repository.taskClipPrefix) ?? false;
      final timeout = isClipTask
          ? const Duration(seconds: 180)
          : isLlmTask
              ? const Duration(seconds: 120)
              : const Duration(seconds: 60);
      // 执行侧计时（§4 卡头耗时）：upsert 的 ON CONFLICT 只刷 updated_at
      //（created_at 保留首建），重算后「created/updated 差值」掺入闲置时间
      // 不准——耗时在重建器执行处实测，注入各产物 meta_json.elapsed_ms。
      final sw = Stopwatch()..start();
      var result = await impl.reconstruct(input).timeout(
            timeout,
            onTimeout: () => ReconstructResult(
              humanMd: input.rawContent ?? '',
              // 超时也是「静默成功」：任务记 completed 却零产出，用户/AI 会误判正常。
              // 按 R1/R3 必须明说——降级完成也要带原因（2026-09-28 决策）。
              note: '处理超时（${timeout.inSeconds}s 未结束），已降级为占位完成，未执行 AI 重构'
                  '（可手动重试，或在设置中触发对应 AI 动作）',
            ),
          );
      sw.stop();
      // §4 卡头耗时注入：块任务把实测耗时合入各产物 meta_json.elapsed_ms
      //（读旧值防覆盖重建器已写的 cues/mode 等元数据）。
      if (result.blockKey != null && result.blockArtifacts != null) {
        result = ReconstructResult(
          humanMd: result.humanMd,
          machineJson: result.machineJson,
          tags: result.tags,
          masked: result.masked,
          itemType: result.itemType,
          facets: result.facets,
          translatedMd: result.translatedMd,
          translateLang: result.translateLang,
          summaryMd: result.summaryMd,
          note: result.note,
          clip: result.clip,
          docMetaJson: result.docMetaJson,
          blockKey: result.blockKey,
          blockArtifacts: [
            for (final a in result.blockArtifacts!)
              BlockArtifactInput(
                a.kind,
                text: a.text,
                filePath: a.filePath,
                metaJson: _mergeElapsed(a.metaJson, sw.elapsedMilliseconds),
              ),
          ],
        );
      }
      // 经 Handler 特权入口回写（machine_json 过 Schema、item_type 变更受 AI 特权约束），
      // 与 UI / MCP 共用同一落库出口；落库复用 repo 通知驱动前台刷新。
      // actor=pipeline 由本文件（管线传输层）指定，命令载荷本身无法伪造。
      await _handler.execute(ApplyAiResultCommand(item.id!, result), actor: CommandActor.pipeline);
      // 完成也带 note：「跑完了但没产出」必须有原因，否则用户分不清成功与失败
      await _repo.finishTask(taskId, 'completed', note: result.note);
    } catch (e) {
      debugPrint('[QueueConsumer] task failed: $e');
      // 块任务不写条目 is_processed（§2.5「条目字段零触碰」）：块产物在块级，
      // 条目处理位与块任务成败无关——条目级任务才标失败位。
      if (!isBlock) await _repo.markItemFailed(item.id!);
      // 错误原因必须落库：否则只剩 debugPrint，人和 AI 都看不到到底为什么失败
      await _repo.finishTask(taskId, 'failed', note: '处理异常：$e');
    } finally {
      heartbeat.cancel();
    }
  }

  /// 实测耗时合入产物 meta_json（保留重建器已写的 cues/mode 等键）。
  /// meta_json 为空 / 非 JSON 对象时新建（坏值直接覆盖——耗时展示不为其让路）。
  static String? _mergeElapsed(String? metaJson, int elapsedMs) {
    Map<String, Object?> m = {};
    if (metaJson != null && metaJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(metaJson);
        if (decoded is Map) m = Map<String, Object?>.from(decoded);
      } catch (_) {}
    }
    m['elapsed_ms'] = elapsedMs;
    return jsonEncode(m);
  }
}
