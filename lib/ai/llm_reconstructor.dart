import 'package:flutter/foundation.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import 'llm.dart';
import 'reconstructor.dart';

/// 端侧 LLM 重构器（2026-09-28）：处理 `task_action=llm_summarize` / `llm_tags`
/// 两类显式入队任务（SummarizeCommand / ExtractTagsCommand，均手动触发）。
///
/// **R1 URL 摘要（2026-10-09 二次收敛：串联式单任务）**：不再认领
/// `summarize_url` 队列任务（抓取与摘要合并为 OcrReconstructor 内的单任务
/// 两步走，见 ocr_reconstructor.summarizeHead）——本类只提供 [summarizeUrlHead]
/// 纯函数供组装点回调：**头部 1500 字符截断直出**（真实长文 3000-8000 字，
/// 一刀切回退会让功能大面积哑火；网页核心论点集中在前 2-3 段，头部摘要
/// 以极低成本覆盖 80% 场景），模型不在位返回 null 静默跳过。
/// ~~chatlog 议题整理~~已砍除：1.5B 理不清长 OCR 碎片的逻辑，重活归桌面 MCP。
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

  /// R1：URL 抓取正文后产 TL;DR + 标签（串联步，组装点回调）。
  ///
  /// 头部 1500 字符截断直出（二次收敛拍板：不搞分块、不一刀切回退）；
  /// 模型不可用 / 空产出 → null（抓取方静默跳过摘要，正文照常落库）。
  /// 标签解析复用 [_splitTagsSuffix]（D2：并集由调用方合并，本函数只给增量）。
  Future<({String summary, List<String> tags})?> summarizeUrlHead(String body) async {
    final text = body.trim();
    if (text.isEmpty) return null;
    if (!await engine.isAvailable) return null;
    final head = text.length > _kHeadChars
        ? '${text.substring(0, _kHeadChars)}…'
        : text;
    try {
      final out = await engine.generate(
        '请根据以下文章开头概述要点（3-5 句 TL;DR，忠实原文，不要编造）。'
        '摘要完成后，另起一行输出「TAGS:」加 2-3 个标签（顿号分隔，优先用常见短词）：\n\n$head',
        maxTokens: 512,
      );
      if (out == null || out.trim().isEmpty) return null;
      final parsed = _splitTagsSuffix(out.trim());
      return (summary: parsed.text, tags: parsed.tags);
    } catch (e) {
      // DEGRADE: 摘要步失败静默降级，不拖垮抓取任务
      debugPrint('[DEGRADE] [Llm] summarizeUrlHead failed: $e');
      return null;
    }
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

    // ─── R1 URL 摘要已改串联式单任务（summarizeUrlHead，由 OcrReconstructor
    // 组装点原地调用）——summarize_url 队列任务落回占位消化（taskActionFor
    // 不再映射，历史遗留任务由占位兜底）───

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

  /// 头部截断长度（二次收敛拍板）：真实网页长文 3000-8000 字，核心论点集中
  /// 在开头——取 1500 字符（≈1500 汉字 / 3000 token 内）保证功能不哑火。
  static const int _kHeadChars = 1500;

  /// 解析 R1 产出尾部的「TAGS: a、b」标签行（D2：直接进 tags）。
  /// 无 TAGS 行 = 标签产出失败不造假，正文/摘要照常应用。
  static ({String text, List<String> tags}) _splitTagsSuffix(String out) {
    final m = RegExp(r'\n?TAGS[:：]\s*(.+)\s*$', caseSensitive: false).firstMatch(out);
    if (m == null) return (text: out, tags: const <String>[]);
    final text = out.substring(0, m.start).trim();
    final tags = m
        .group(1)!
        .split(RegExp(r'[、,，;；]'))
        .map((s) => s.trim().replaceAll(RegExp(r'^[-•\d\.\s]+'), ''))
        .where((s) => s.isNotEmpty && s.length <= 24)
        .take(3) // D2 拍板：prompt 限 2–3 个，解析侧兜底再截一次
        .toSet();
    return (text: text.isEmpty ? out : text, tags: tags.toList());
  }
}
