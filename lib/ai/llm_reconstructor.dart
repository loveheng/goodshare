import 'package:flutter/foundation.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import 'llm.dart';
import 'reconstructor.dart';

/// 端侧 LLM 重构器（2026-09-28）：处理 `task_action=llm_summarize` / `llm_tags`
/// 两类显式入队任务（SummarizeCommand / ExtractTagsCommand，均手动触发）。
///
/// **R1 摄入自动重构（2026-10-09 落码；同日收敛拍板收窄，v2-requirements §1.1a）**：
/// 增认领 `summarize_url`——URL 摄入抓取正文后自动跑 TL;DR 摘要 + 2–3 标签
/// （D4 拍板收窄：叠加层，**不改写** OcrReconstructor 抓取的正文——那是事实源，
/// 摘要写 summary_md + 自动标签）。~~chatlog 议题整理~~已砍除：1.5B 理不清
/// 长 OCR 碎片的逻辑，整理产出不可信，重活归桌面 MCP。
///
/// D3 超长口径保留（同时服务 URL 摘要）：输入超 `_maxPromptChars`（≈4096 token 档）
/// 回退占位 + note 明示，不截断照跑（防失真产出）。
///
/// 与 TranslationReconstructor 同构：URL 摘要写入 `summary_md`（并列不覆盖）；
/// 引擎不可用 / 空产出 → 占位完成 + note 明说原因（「降级不卡死 + 结果可观测」）。
class LlmReconstructor implements AiReconstructor {
  const LlmReconstructor({required this.engine});

  final OnDeviceLlmEngine engine;

  /// 输入上限（D3 拍板）：超出即回退占位。Qwen 档 4096 token ≈ 2-4k 汉字，
  /// 中文按 1 字 ≈ 1 token 计取保守值 3000 字符（含指令开销余量）。
  static const int _maxPromptChars = 3000;

  @override
  Future<bool> get isAvailable async => true; // 恒 true：失败只是无产出，不能死信

  @override
  Future<bool> handles(ReconstructInput input) async {
    // 块任务认领（block-artifact-workflow.md §2.5）：仅 block_summarize。
    final block = Repository.parseBlockAction(input.taskAction);
    if (block != null) return block.$1 == 'block_summarize';
    return input.taskAction == Repository.taskLlmSummarize ||
        input.taskAction == Repository.taskLlmTags ||
        // R1 摄入自动重构（2026-10-09 收敛后仅 URL）
        input.taskAction == Repository.taskSummarizeUrl;
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

    // ─── R1 摄入自动重构（2026-10-09 收敛拍板：仅 URL 摘要+打标，chatlog 已砍）───
    final isUrlSummary = input.taskAction == Repository.taskSummarizeUrl;
    if (isUrlSummary) {
      // D3 超长口径：回退占位 + note 明示，不截断照跑（防失真产出）。
      if (text.length > _maxPromptChars) {
        return ReconstructResult(
          humanMd: base,
          note: '内容超长（${text.length} 字符 > $_maxPromptChars），'
              '本次未执行 AI 摘要（不截断照跑防失真）',
        );
      }
      if (!await engine.isAvailable) {
        final reason = (await engine.unavailableReasonAsync()) ??
            engine.unavailableReason ??
            '端侧大模型引擎不可用';
        debugPrint('[Llm] r1 unavailable (item=${input.itemId}): $reason');
        return ReconstructResult(humanMd: base, note: '未生成：$reason');
      }
      try {
        // 叠加层——不改写抓取正文（事实源），摘要 + 自动标签。
        // 正文为空（抓取失败已由 OcrReconstructor 落占位）时无从摘要，直接明说。
        if (text.isEmpty) {
          return ReconstructResult(humanMd: base, note: '链接正文为空（抓取未产出），无法生成摘要');
        }
        final out = await engine.generate(
          '请为以下网页正文写一段简明摘要（3-5 句，忠实原文，不要编造）。'
          '摘要完成后，另起一行输出「TAGS:」加 2-3 个标签（顿号分隔，优先用常见短词）：\n\n$text',
          maxTokens: 512,
        );
        if (out == null || out.trim().isEmpty) {
          return ReconstructResult(humanMd: base, note: '端侧大模型未产出结果（模型未就绪或生成失败），可重试');
        }
        final parsed = _splitTagsSuffix(out.trim());
        return ReconstructResult(
          humanMd: base,
          summaryMd: parsed.text,
          tags: <String>{...input.humanTags, ...parsed.tags}.toList(),
        );
      } catch (e) {
        // DEGRADE: 引擎异常按「占位完成 + 明说原因」处理，不置死信不重入队。
        debugPrint('[Llm] r1 generate failed (item=${input.itemId}): $e');
        return ReconstructResult(humanMd: base, note: '端侧大模型生成异常：$e（可重试）');
      }
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
