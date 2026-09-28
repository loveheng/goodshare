import 'package:flutter/foundation.dart';

import 'asr.dart';
import 'model_manager.dart';
import 'reconstructor.dart';
import 'subtitle.dart';

/// 音频/视频离线转写重构器（2026-09-28，与 OcrReconstructor 同构）：
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
  });

  /// 是否允许音频转写（设置开关门控）；null = 恒允许。
  final bool Function()? isAsrEnabled;

  /// 模型管理器；null = 环境无模型（恒占位，如 VM 测试）。
  final ModelManager? models;

  @override
  Future<bool> get isAvailable async => true;

  /// 音频与视频（离线转写 + 字幕）；图片/链接由 OcrReconstructor 处理。
  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == 'audio' || input.itemType == 'video';

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    if (input.itemType != 'audio' && input.itemType != 'video') {
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    final on = isAsrEnabled?.call() ?? true;
    final models = this.models;
    if (!on || models == null) {
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    final model = models.selectedModel;
    if (!await models.isDownloaded(model)) {
      debugPrint('[AsrReconstructor] model not downloaded (${model.id}), placeholder');
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    final path = input.rawFilePath;
    if (path == null || path.isEmpty) {
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    final modelDir = (await models.dirFor(model)).path;
    // 统一走 cue 通道（VAD 分段）：human_md 文本由 cue 拼接，字幕双份落盘。
    // 任一环节失败 → 占位，不置死信。
    final cues = await AsrEngine.instance.transcribeToCues(path, model,
        modelDir: modelDir);
    if (cues == null) {
      debugPrint('[AsrReconstructor] transcribe failed, placeholder: $path');
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    // 字幕落盘失败只记日志，不影响 human_md（占位不卡死的字幕侧口径）。
    try {
      await SubtitleStore.save(input.itemId, cues);
    } catch (e) {
      debugPrint('[AsrReconstructor] subtitle save failed (ignored): $e');
    }
    return ReconstructResult(
        humanMd: cues.map((c) => c.text.trim()).join('\n'));
  }
}
