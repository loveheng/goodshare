import 'package:flutter/foundation.dart';

import 'asr.dart';
import 'model_manager.dart';
import 'reconstructor.dart';

/// 音频离线转写重构器（2026-09-28，与 OcrReconstructor 同构）：
/// - 音频条目：按设置选中的 Sherpa 模型转写，文本写入人类态；
/// - 门控：开关关闭 / 模型未下载 / 转写失败 → 占位行为（raw_content 原样入 human_md），
///   不置死信（与 OCR 降级策略一致）；
/// - 其余类型：占位行为（图片/链接仍由 OcrReconstructor 处理）。
/// 无模型下载能力（如测试环境）时 [models] 传 null，恒走占位。
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

  /// 仅处理音频（离线转写）；图片/链接由 OcrReconstructor 处理。
  @override
  Future<bool> handles(ReconstructInput input) async => input.itemType == 'audio';

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    if (input.itemType != 'audio') {
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
    final text = await AsrEngine.instance.transcribe(path, model, modelDir: modelDir);
    if (text == null) {
      debugPrint('[AsrReconstructor] transcribe failed, placeholder: $path');
      return ReconstructResult(humanMd: input.rawContent ?? '');
    }
    return ReconstructResult(humanMd: text);
  }
}
