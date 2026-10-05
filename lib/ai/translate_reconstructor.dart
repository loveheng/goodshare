import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import 'reconstructor.dart';
import 'translation.dart';

/// 文本条目翻译重构器（2026-09-28）：处理 `task_action=translate` 的队列任务，
/// 把条目正文译成设置项目标语言，译文**另列存储**（`translated_md`）——
/// 不改写 `human_md`：原文与译文是一对并列的产物，译文丢了可以再翻，
/// 原文被覆盖则不可逆。
///
/// 与 OCR / 转写同构：恒 `isAvailable`（翻译失败只是没有译文，不能让任务变死信），
/// `handles` 只认手动入队的 translate 任务（摄入不自动翻译，避免每条文本都跑一遍）。
class TranslationReconstructor implements AiReconstructor {
  const TranslationReconstructor({required this.service});

  final TranslationService service;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async {
    // 块任务认领（block-artifact-workflow.md §2.5）：仅 block_translate。
    final block = Repository.parseBlockAction(input.taskAction);
    if (block != null) return block.$1 == 'block_translate';
    return Repository.isTranslateAction(input.taskAction);
  }

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    // 块分支（§2.5）：源文本 = 源产物（queue_consumer 从 block_artifacts 读出传入），
    // 译文落 block_artifacts（translation），条目级 translated_md 零触碰。
    final blockKey = input.blockKey;
    if (blockKey != null) {
      final base = input.blockSourceText?.trim() ?? '';
      if (base.isEmpty) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: '源产物不存在或为空，无法翻译（可能已被清除，先重跑转写/识别文字）',
        );
      }
      final target = Repository.blockTranslateLangOf(input.taskAction) ?? service.targetLang();
      final translated = await service.translateText(base, target: target);
      if (translated == null) {
        debugPrint('[Translation] no block translation produced (item=${input.itemId})');
        // 明说为什么没有译文：源语等于目标语 / 无可用引擎，处置方式不同（R1）
        final reason = detectSourceLanguage(base) == target
            ? '源文本已是${languageLabel(target)}，无需翻译'
            : '无可用翻译引擎（语言包未就绪时保留原文，设置 → 翻译 可下载）';
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: reason,
        );
      }
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        blockKey: blockKey,
        blockArtifacts: [
          BlockArtifactInput(
            BlockArtifactKind.translation,
            text: translated,
            metaJson: jsonEncode({
              'source_kind': Repository.blockTranslateSourceKindOf(input.taskAction),
              'lang': target,
            }),
          ),
        ],
      );
    }
    // 人类态优先（与详情页 bodyText 同口径），缺省回退原文
    final base = input.humanMd ?? input.rawContent ?? '';
    // 任务串可携带单次目标语言（MCP translate_item 指定），否则用设置项语言
    final target = Repository.translateTargetOf(input.taskAction) ?? service.targetLang();
    final translated = await service.translateText(base, target: target);
    if (translated == null) {
      debugPrint('[Translation] no translation produced (item=${input.itemId})');
      // 明说为什么没有译文：引擎不可达 / 源语等于目标语 / 无正文，三者处置方式完全不同
      final reason = base.trim().isEmpty
          ? '条目没有可翻译的正文'
          : (detectSourceLanguage(base) == target
              ? '正文已是${languageLabel(target)}，无需翻译'
              : '无可用翻译引擎（语言包未就绪时保留原文，设置 → 翻译 可下载）');
      return ReconstructResult(humanMd: base, note: reason);
    }
    return ReconstructResult(
      humanMd: base,
      translatedMd: translated,
      translateLang: target,
    );
  }
}
