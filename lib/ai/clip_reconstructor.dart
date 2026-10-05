import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/repository.dart';
import '../media/media_toolkit.dart';
import '../media/wav16k.dart';
import 'asr.dart';
import 'llm.dart';
import 'llm_reconstructor.dart';
import 'model_manager.dart';
import 'reconstructor.dart';
import 'video_clips.dart';

/// 视频切片重建器（2026-09-29，设计 docs/design/video-clips.md）：
/// 认领 `clip:<startMs>-<endMs>:<steps>` 任务，按用户勾选的链路子集对单区间执行
/// ①提取视频片段（libx264 精确重编码，E1 拍板）→ ②端侧 ASR 转写 → ③端侧 LLM 摘要
/// （E2：勾摘要自动带动转写）。**止步于片段本身合法**——只勾提取就没有文本。
///
/// 产出经 [ReconstructResult.clip] 合并进条目 `clips_json`（不触碰条目级字段）；
/// 任一环节失败 → 该区间 status=failed + note 明说哪一步失败（不置死信，可重启）。
class ClipReconstructor implements AiReconstructor {
  const ClipReconstructor({
    required this.engine,
    this.models,
    this.isAsrEnabled,
  });

  final OnDeviceLlmEngine engine;

  /// 模型管理器；null = 环境无模型（转写占位，如 VM 测试）。
  final ModelManager? models;

  /// 是否允许音频转写（设置开关门控，与整片转写同一开关）。
  final bool Function()? isAsrEnabled;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.taskAction?.startsWith(Repository.taskClipPrefix) ?? false;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    // 失败路径一律回传条目既有文本，防止 human_md 被清空（与 LlmReconstructor 同守卫）
    final base = input.humanMd ?? input.rawContent ?? '';
    final parsed = Repository.parseClipTaskAction(input.taskAction);
    if (parsed == null) {
      return ReconstructResult(humanMd: base, note: '切片任务动作非法：${input.taskAction}');
    }
    final (startMs, endMs, steps) = parsed;
    final now = DateTime.now().millisecondsSinceEpoch;
    String? clipPath;
    String? text;
    String? summary;
    final failures = <String>[];

    final srcPath = input.rawFilePath;
    if (srcPath == null || srcPath.isEmpty || !File(srcPath).existsSync()) {
      return ReconstructResult(
        humanMd: base,
        clip: ClipSegment(
          startMs: startMs, endMs: endMs, steps: steps, status: kClipStatusFailed,
          createdAt: now, note: '视频源文件缺失或已清理，无法处理',
        ),
      );
    }

    try {
      // ---- 步骤①：提取视频片段（media3 Transformer 硬编 trim 导出；
      //      media-native P3——libx264 软编退役，产物相对 documents 存档）----
      if (steps.contains(kClipStepExtract)) {
        final docs = await getApplicationDocumentsDirectory();
        final outDir = Directory(p.join(docs.path, 'clip_segments'));
        await outDir.create(recursive: true);
        final out = File(p.join(outDir.path, '${input.itemId}.$startMs-$endMs.mp4'));
        final trimmed = await mediaToolkit.trimVideo(
          srcPath,
          out.path,
          startMs: startMs,
          endMs: endMs,
        );
        if (trimmed != null) {
          clipPath = 'clip_segments/${p.basename(out.path)}';
        } else {
          failures.add('片段提取失败（冷门格式暂不支持或文件损坏，可反馈需求走云端支持）');
        }
      }

      // ---- 步骤②：端侧 ASR 转写（E2：勾摘要时本步必在）----
      if (steps.contains(kClipStepTranscribe)) {
        final gate = await _asrGate();
        if (gate != null) {
          failures.add(gate);
        } else {
          final mm = models!;
          final model = mm.selectedModel;
          final modelDir = (await mm.dirFor(model)).path;
          final tmp = await getTemporaryDirectory();
          final wav = File(p.join(tmp.path, 'clip_${startMs}_$endMs.wav'));
          try {
            final decoded = await extractWav16k(
              srcPath,
              wav.path,
              startMs: startMs,
              endMs: endMs,
            );
            final raw = decoded
                ? await AsrEngine.instance
                    .transcribeToCues(wav.path, model, modelDir: modelDir)
                : null;
            final cues = raw ?? const [];
            final joined = cues.map((c) => c.text.trim()).where((s) => s.isNotEmpty).join('\n');
            if (joined.isEmpty) {
              if (decoded) {
                failures.add('区间未识别出语音内容（可能无对话、音量过低或语言与模型不匹配）');
              } else {
                // R1：解码失败与「没有语音」必须区分——文案给可行动去向
                failures.add('区间音轨解码失败（冷门格式暂不支持或文件损坏，可反馈需求走云端支持）');
              }
            } else {
              text = joined;
            }
          } finally {
            try {
              if (await wav.exists()) await wav.delete();
            } catch (_) {}
          }
        }
      }

      // ---- 步骤③：端侧 LLM 摘要（依赖转写文本；复用 LlmReconstructor 提示词/降级口径）----
      if (steps.contains(kClipStepSummary)) {
        if (text == null) {
          failures.add('摘要未生成：没有转写文本');
        } else {
          final r = await LlmReconstructor(engine: engine).reconstruct(ReconstructInput(
            itemId: input.itemId,
            itemType: 'note',
            rawContent: text,
            humanMd: text,
            taskAction: Repository.taskLlmSummarize,
          ));
          if (r.summaryMd == null || r.summaryMd!.trim().isEmpty) {
            failures.add('摘要未生成：${r.note ?? '端侧大模型未产出'}');
          } else {
            summary = r.summaryMd!.trim();
          }
        }
      }
    } catch (e) {
      // DEGRADE: 任一环节异常按「区间置 failed + 明说原因」处理，不置死信不重入队。
      debugPrint('[ClipReconstructor] failed (item=${input.itemId}): $e');
      failures.add('切片处理异常：$e（可在队列里重启）');
    }

    return ReconstructResult(
      humanMd: base,
      clip: ClipSegment(
        startMs: startMs,
        endMs: endMs,
        steps: steps,
        status: failures.isEmpty ? kClipStatusDone : kClipStatusFailed,
        clipPath: clipPath,
        text: text,
        summary: summary,
        note: failures.isEmpty ? null : failures.join('；'),
        createdAt: now,
      ),
    );
  }

  /// ASR 前置门控文案；null = 可转写。
  Future<String?> _asrGate() async {
    if (!(isAsrEnabled?.call() ?? true)) return '转写开关已关闭（设置 → AI 模式）';
    final mm = models;
    if (mm == null) return '当前环境没有模型管理器，未执行转写';
    final model = mm.selectedModel;
    if (!await mm.isDownloaded(model)) return '模型「${model.name}」未下载（设置 → 语音转写模型 下载后再试）';
    return null;
  }
}
