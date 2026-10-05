import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import 'asr.dart';
import 'model_manager.dart';
import 'reconstructor.dart';
import 'subtitle.dart';
import 'translation.dart';

/// 音频/视频离线转写重构器（2026-09-28，与 OcrReconstructor 同构）：
/// 转写产出 cue 后，若字幕模式非「仅原文」，交翻译层逐条补译文（失败保留原文）。
/// - 音频/视频条目：按设置选中的 Sherpa 模型转写（视频经同一 `_toWav16k` 抽
///   音轨），文本写入人类态；字幕（SRT/VTT 双份）落 `documents/subtitles/`；
/// - 字幕与文本同一 VAD 管线产出，字幕失败**不影响** human_md（「占位不卡死」
///   的字幕侧延伸，设计见 docs/design/asr-subtitle.md §6/§7）；
/// - 门控：开关关闭 / 模型未下载 / 转写失败 → 占位行为（raw_content 原样入
///   human_md），不置死信（与 OCR 降级策略一致）；
/// - 无模型下载能力（如测试环境）时 [models] 传 null，恒走占位。
class AsrReconstructor implements AiReconstructor {
  const AsrReconstructor({
    required this.isAsrEnabled,
    this.models,
    this.translation,
    this.subtitleMode,
    this.blockAudioFileOf,
  });

  /// 是否允许音频转写（设置开关门控）；null = 恒允许。
  final bool Function()? isAsrEnabled;

  /// 模型管理器；null = 环境无模型（恒占位，如 VM 测试）。
  final ModelManager? models;

  /// 字幕翻译服务；null = 不做字幕翻译（产物恒为原文）。
  final TranslationService? translation;

  /// 当前字幕译文模式；null = [SubtitleMode.sourceOnly]。
  final SubtitleMode Function()? subtitleMode;

  /// 查块已有 audio_file 产物路径（§2.5 输入源优先级：转写优先消费音轨，
  /// 省一次解码）；null = 不查（回落块本体）。main 装配注入（读 block_artifacts，
  /// 重建器不直依赖 store）。
  final Future<String?> Function(String itemId, String blockKey)? blockAudioFileOf;

  @override
  Future<bool> get isAvailable async => true;

  /// 音频与视频（离线转写 + 字幕）；图片/链接由 OcrReconstructor 处理。
  @override
  Future<bool> handles(ReconstructInput input) async {
    // 块任务认领（block-artifact-workflow.md §2.5）：仅 block_transcribe——
    // note 条目（itemType=note）不挡块通道，块任务的类型合法性由动作层校验。
    final block = Repository.parseBlockAction(input.taskAction);
    if (block != null) return block.$1 == 'block_transcribe';
    final isMedia = input.itemType == 'audio' || input.itemType == 'video';
    if (!isMedia) return false;
    // 音频 / 视频转写**仅手动触发**（2026-09-28 用户拍板：不做实时转写、摄入不自动
    // 转写，只存文件）。仅 transcribe 类任务动作走 ASR（含 `transcribe_audio:<mode>:<lang>`
    // 任务级覆盖变体——MCP transcribe_item，2026-10-02）；摄入后的通用重构落占位实现，
    // 避免自动跑 Sherpa 长任务长期占住队列（曾导致整队堵死）。
    return Repository.isTranscribeAction(input.taskAction);
  }

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final blockKey = input.blockKey;
    final isBlock = blockKey != null;
    // 块任务不受条目类型约束（合法性已由动作层校验；note 条目内音视频块照常转写）。
    if (!isBlock && input.itemType != 'audio' && input.itemType != 'video') {
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    final on = isAsrEnabled?.call() ?? true;
    final models = this.models;
    if (!on) {
      return ReconstructResult(humanMd: input.rawContent ?? '', note: '转写开关已关闭（设置 → AI 模式）');
    }
    if (models == null) {
      return ReconstructResult(humanMd: input.rawContent ?? '', note: '当前环境没有模型管理器，未执行转写');
    }
    final model = models.selectedModel;
    if (!await models.isDownloaded(model)) {
      debugPrint('[AsrReconstructor] model not downloaded (${model.id}), placeholder');
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '模型「${model.name}」未下载，未执行转写（设置 → 语音转写模型 下载后再试）',
      );
    }
    // 输入源分叉（§2.5）：块任务用块媒体路径（queue_consumer 已解析），条目任务用
    // rawFilePath。路径缺失 = 文件不存在，块级按失败占位（blockKey 带回走跳过门禁）。
    // 块任务优先消费已有 audio_file 产物（§3.6 锚点切换的数据侧：视频块先提取
    // 音轨后转写时，直接用音轨文件省一次解码；无产物回落块本体——同一音轨内容）。
    String? path = isBlock ? input.blockFilePath : input.rawFilePath;
    if (isBlock) {
      final audio = await blockAudioFileOf?.call(input.itemId, blockKey);
      if (audio != null && audio.isNotEmpty) path = audio;
    }
    if (path == null || path.isEmpty) {
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: isBlock ? '块媒体文件缺失，无法转写（媒体行可能已被移除）' : '条目没有音频文件，无法转写',
        blockKey: blockKey,
        blockArtifacts: const [],
      );
    }
    final modelDir = (await models.dirFor(model)).path;
    // 统一走 cue 通道（VAD 分段）：human_md 文本由 cue 拼接，字幕双份落盘。
    // 任一环节失败 → 占位，不置死信。
    final raw = await AsrEngine.instance.transcribeToCues(path, model,
        modelDir: modelDir);
    if (raw == null) {
      debugPrint('[AsrReconstructor] transcribe failed, placeholder: $path');
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '转写失败：模型未产出结果',
        blockKey: blockKey,
        blockArtifacts: const [],
      );
    }
    var cues = raw;
    // 「跑完但一个字都没有」是用户最难判断的一档（看起来和失败一样），
    // 必须落成明说的原因而不是静默成功——中文模型跑英文音频正是典型。
    if (usableCues(cues).isEmpty) {
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '未识别出任何语音内容：音频可能无语音、音量过低，'
            '或语言与所选模型不匹配（如用中文模型转写英文——请切换「全能 · 多语种」档）',
        blockKey: blockKey,
        blockArtifacts: const [],
      );
    }
    // 字幕译文：仅「非仅原文」模式才跑翻译；失败（引擎不可用 / 单条报错）保留原文，
    // 与「占位不卡死」同口径——字幕档位与 human_md 都不受翻译影响。
    // 任务动作串可携带模式 / 目标语言覆盖（MCP transcribe_item），缺省沿用设置项。
    // 但「有动作无结果」要可观测（R1/R3）：把字幕翻译 / 落盘失败的原因汇总进 note，
    // 否则用户/AI 看到字幕缺译文或缺文件却不知为何。
    String? subNote;
    // 任务级覆盖（§2.5）：条目级走 transcribe_audio: 前缀解析，块级走 block 串解析，
    // 缺省都沿用设置项。
    final modeOverride =
        Repository.transcribeSubtitleModeOf(input.taskAction) ??
            Repository.blockTranscribeModeOf(input.taskAction);
    final langOverride =
        Repository.transcribeTargetLangOf(input.taskAction) ??
            Repository.blockTranscribeLangOf(input.taskAction);
    final mode = modeOverride != null
        ? SubtitleMode.values.byName(modeOverride)
        : (subtitleMode?.call() ?? SubtitleMode.sourceOnly);
    final tr = translation;
    if (mode != SubtitleMode.sourceOnly && tr != null) {
      try {
        cues = await tr.translateCues(cues, target: langOverride);
      } catch (e) {
        debugPrint('[AsrReconstructor] subtitle translation failed (ignored): $e');
        subNote = '字幕译文未生成（翻译引擎不可用），字幕保留原文';
      }
    }
    // 块级（§2.5 一步双产物）：先落字幕文件（SRT/VTT，文件名含 blockStem），
    // 再把 transcript + subtitle 载荷交 handler 单事务 upsertAll（原子落库——
    // 半态会让「按产物反推续点」误判转写已完成）。字幕落盘失败按五轮拍板
    // 降级为 transcript-only（明说，不留半态行）。
    if (isBlock) {
      // §2.5 一步双产物（拍板 2026-10-05）：单事务全有或全无——字幕落盘失败
      // 不再降级为 transcript-only（半态会让「按产物反推续点」误判转写已完成），
      // 整任务按失败处理（空产物载荷 + 原因明说），重跑即重算。
      String? subtitlePath;
      try {
        subtitlePath = await SubtitleStore.saveBlock(
          input.itemId,
          blockKey,
          cues,
          mode: mode,
          targetLang: langOverride ?? tr?.targetLang(),
        );
      } catch (e) {
        debugPrint('[AsrReconstructor] block subtitle save failed: $e');
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: '字幕文件保存失败，转写产物未落库（整任务重跑即重算，零算力回退除外）',
        );
      }
      final text = cues.map((c) => c.text.trim()).join('\n');
      return ReconstructResult(
        // 块任务不触碰条目字段：humanMd=rawContent 走 rawEcho 保护保留现正文
        humanMd: input.rawContent ?? '',
        blockKey: blockKey,
        blockArtifacts: [
          BlockArtifactInput(
            BlockArtifactKind.transcript,
            text: text,
            metaJson: jsonEncode({'cues': cues.length}),
          ),
          if (subtitlePath != null) // ignore: unnecessary_null_comparison
            BlockArtifactInput(
              BlockArtifactKind.subtitle,
              text: text,
              filePath: subtitlePath,
              metaJson: jsonEncode({'cues': cues.length, 'mode': mode.name}),
            ),
        ],
        note: subNote,
      );
    }
    // 条目级（现行）：字幕落盘失败只记日志，不影响 human_md（占位不卡死的字幕侧口径）；原因进 note。
    try {
      await SubtitleStore.save(
        input.itemId,
        cues,
        mode: mode,
        targetLang: langOverride ?? tr?.targetLang(),
      );
    } catch (e) {
      debugPrint('[AsrReconstructor] subtitle save failed (ignored): $e');
      subNote = subNote == null
          ? '字幕文件保存失败，仅人类态文本已生成'
          : '$subNote；字幕文件保存失败，仅人类态文本已生成';
    }
    return ReconstructResult(
        humanMd: cues.map((c) => c.text.trim()).join('\n'),
        note: subNote);
  }
}
