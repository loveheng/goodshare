import 'package:flutter/foundation.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import 'llm.dart';
import 'reconstructor.dart';

/// 端侧 LLM 重构器（2026-09-28）：处理 `task_action=llm_summarize` / `llm_tags`
/// 两类显式入队任务（SummarizeCommand / ExtractTagsCommand，均手动触发）。
///
/// 与 TranslationReconstructor 同构：**不改写 human_md**——摘要写入
/// `summary_md`（并列不覆盖，schema v8）；关键词产出并入既有标签（tags）。
/// 引擎不可用 / 空产出 → 占位完成 + note 明说原因（「降级不卡死 + 结果可观测」）。
class LlmReconstructor implements AiReconstructor {
  const LlmReconstructor({required this.engine});

  final OnDeviceLlmEngine engine;

  @override
  Future<bool> get isAvailable async => true; // 恒 true：失败只是无产出，不能死信

  @override
  Future<bool> handles(ReconstructInput input) async {
    // 块任务认领（block-artifact-workflow.md §2.5）：仅 block_summarize。
    final block = Repository.parseBlockAction(input.taskAction);
    if (block != null) return block.$1 == 'block_summarize';
    return input.taskAction == Repository.taskLlmSummarize ||
        input.taskAction == Repository.taskLlmTags;
  }

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    // 块分支（§2.5）：源 = 块产物文本（transcript/ocr_text，动作层已校验非空），
    // 摘要落 block_artifacts（summary），条目级 summary_md 零触碰。
    final blockKey = input.blockKey;
    if (blockKey != null) {
      final text = input.blockSourceText?.trim() ?? '';
      if (text.isEmpty) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: '源产物不存在或为空，无法摘要',
        );
      }
      if (!await engine.isAvailable) {
        // R1：同步 unavailableReason 会把「引擎初始化失败」误报成「未下载模型」，取异步真值
        final reason = (await engine.unavailableReasonAsync()) ??
            engine.unavailableReason ??
            '端侧大模型引擎不可用';
        debugPrint('[Llm] block summarize unavailable (item=${input.itemId}): $reason');
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: '未生成：$reason',
        );
      }
      final prompt =
          '请为以下收集内容写一段简明摘要（3-5 句，忠实原文，不要编造）：\n\n$text';
      try {
        final out = await engine.generate(prompt, maxTokens: 512);
        if (out == null || out.trim().isEmpty) {
          return ReconstructResult(
            humanMd: input.rawContent ?? '',
            blockKey: blockKey,
            blockArtifacts: const [],
            note: '端侧大模型未产出结果（模型未就绪或生成失败），可重试',
          );
        }
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: [BlockArtifactInput(BlockArtifactKind.summary, text: out.trim())],
        );
      } catch (e) {
        debugPrint('[Llm] block generate failed (item=${input.itemId}): $e');
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: '端侧大模型生成异常：$e（可重试）',
        );
      }
    }
    final base = input.humanMd ?? input.rawContent ?? '';
    final text = base.trim();
    if (text.isEmpty) {
      return ReconstructResult(humanMd: base, note: '条目没有可供大模型处理的正文');
    }
    if (!await engine.isAvailable) {
      // R1：任务 note 必须带真值原因——同步 unavailableReason 是桥层兜底文案，
      // 会把「引擎初始化失败」误报成「未下载模型」（实测 qwen 模型在机仍误报）。
      final reason = (await engine.unavailableReasonAsync()) ??
          engine.unavailableReason ??
          '端侧大模型引擎不可用';
      debugPrint('[Llm] unavailable (item=${input.itemId}): $reason');
      return ReconstructResult(humanMd: base, note: '未生成：$reason');
    }

    final isSummary = input.taskAction == Repository.taskLlmSummarize;
    final prompt = isSummary
        ? '请为以下收集内容写一段简明摘要（3-5 句，忠实原文，不要编造）：\n\n$text'
        : '请从以下收集内容中提取 3-8 个关键词，只输出关键词本身，用顿号（、）分隔，不要任何其他文字：\n\n$text';
    try {
      final out = await engine.generate(prompt, maxTokens: isSummary ? 512 : 128);
      if (out == null || out.trim().isEmpty) {
        return ReconstructResult(humanMd: base, note: '端侧大模型未产出结果（模型未就绪或生成失败），可重试');
      }
      if (isSummary) {
        return ReconstructResult(humanMd: base, summaryMd: out.trim());
      }
      // 关键词：顿号/逗号切分，去重后并入既有标签（不覆盖用户手动打的标签）
      final tags = out
          .split(RegExp(r'[、,，;；\n]'))
          .map((s) => s.trim().replaceAll(RegExp(r'^[-•\d\.\s]+'), ''))
          .where((s) => s.isNotEmpty && s.length <= 24)
          .toSet();
      final merged = (<String>{...input.humanTags, ...tags}).toList();
      if (merged.isEmpty) {
        return ReconstructResult(humanMd: base, note: '端侧大模型未产出关键词，可重试');
      }
      return ReconstructResult(humanMd: base, tags: merged);
    } catch (e) {
      // DEGRADE: 引擎异常按「占位完成 + 明说原因」处理，不置死信不重入队。
      debugPrint('[Llm] generate failed (item=${input.itemId}): $e');
      return ReconstructResult(humanMd: base, note: '端侧大模型生成异常：$e（可重试）');
    }
  }
}
