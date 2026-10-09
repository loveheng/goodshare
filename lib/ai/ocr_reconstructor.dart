import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import '../doc/html_to_md.dart';
import 'reconstructor.dart';
import 'url_extract.dart';

/// v1 消费者实现（2026-09-27 分期调整：OCR 从 V2 提前）：
/// - 图片条目：ML Kit 端侧文字识别（中文脚本），OCR 文本写入人类态；
/// - 其余类型：占位行为（raw_content 原样入 human_md）。
/// 受设置页「图片 OCR」开关门控（AiCapabilities），关闭或无能力时走占位。
/// 音频转写不做（2026-09-27 用户拍板去掉边录边转），录音仅存音频文件。
/// 无 GMS 设备的 bundled OCR 变体适配为后续项（先支持标准设备）。
class OcrReconstructor implements AiReconstructor {
  const OcrReconstructor({
    this.isOcrEnabled,
    this.isUrlFetchEnabled,
    this.summarizeHead,
  });

  /// 是否允许 OCR（设置开关门控）；null = 恒允许。
  final bool Function()? isOcrEnabled;

  /// 是否允许链接离线抓取网页正文（设置开关门控）；null = 恒允许。
  final bool Function()? isUrlFetchEnabled;

  /// R1 URL 摘要（2026-10-09 二次收敛：**串联式单任务** Composite Pipeline）——
  /// 抓取正文后**原地**调端侧 LLM 产 TL;DR+标签，**同一任务、一次落库**：
  /// 不拆两个 Task、无跨任务链、无防环闸（链式+双闸版本经评估属分布式调度
  /// 重型思维，本地 SQLite 队列串联执行物理归零死循环）。
  /// 回调 null / 返回 null = 模型不在位或未产出，正文照常落库（静默跳过摘要，
  /// 不占 note——「模型没下」不是本任务的失败）。
  final Future<({String summary, List<String> tags})?> Function(String body)? summarizeHead;

  @override
  Future<bool> get isAvailable async => true;

  /// 处理图片（OCR）与链接（离线抓取）；音频/文本由其他实现或占位兜底。
  @override
  Future<bool> handles(ReconstructInput input) async {
    // 块任务认领（block-artifact-workflow.md §2.5）：仅 block_ocr——note 条目
    // 不挡块通道，块合法性（human_md 确有该图片媒体行）由动作层校验。
    final block = Repository.parseBlockAction(input.taskAction);
    if (block != null) return block.$1 == 'block_ocr';
    // 链接离线抓取保持自动（用户未要求手动化）。
    if (input.itemType == 'url') return true;
    if (input.itemType != 'image') return false;
    // 图片 OCR **仅手动触发**（2026-09-28 用户拍板：与音频一致，分享摄入不自动 OCR，
    // 只存文件）。仅 task_action=ocr_and_extract 的任务走 OCR；摄入后的通用重构
    // 落占位实现，不跑模型。
    return input.taskAction == Repository.taskOcrAndExtract;
  }

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final ocrOn = isOcrEnabled?.call() ?? true;
    // 块分支（§2.5）：源为块图片文件（queue_consumer 解析的 blockFilePath），
    // 产出落 block_artifacts（ocr_text），条目字段零触碰。
    final blockKey = input.blockKey;
    if (blockKey != null) {
      final path = input.blockFilePath;
      if (!ocrOn) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: 'OCR 已关闭（设置 → AI 模式），未执行识别',
        );
      }
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          blockKey: blockKey,
          blockArtifacts: const [],
          note: '块图片文件缺失，无法识别（媒体行可能已被移除）',
        );
      }
      final text = await _ocr(path);
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        blockKey: blockKey,
        // OCR 无产出（识别失败 / 图片无文字）也须明说，否则用户以为图片被正常解析
        blockArtifacts:
            text == null ? const [] : [BlockArtifactInput(BlockArtifactKind.ocrText, text: text)],
        note: text == null ? '图片块 OCR 未产出文字（识别失败或无文字内容）' : null,
      );
    }
    if (ocrOn && input.itemType == 'image' && (input.rawFilePath?.isNotEmpty ?? false)) {
      final text = await _ocr(input.rawFilePath!);
      // OCR 无产出（识别失败 / 图片无文字）也须明说，否则用户以为图片被正常解析
      return ReconstructResult(
        humanMd: text ?? input.rawContent ?? '',
        note: text == null
            ? '图片 OCR 未产出文字（识别失败或无文字内容），已保留图片'
            : null,
      );
    }
    // 链接离线成内容（2026-09-27 决策）：抓取网页正文写入人类态；失败回退占位。
    // 无论「关闭」还是「抓取失败」都要带原因，否则原始链接被默默保留、用户无感（R1）。
    final fetchOn = isUrlFetchEnabled?.call() ?? true;
    if (input.itemType == 'url') {
      if (!fetchOn) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          note: '链接抓取已关闭（设置 → AI 模式），已保留原始链接',
        );
      }
      final url = firstUrl(input.rawContent ?? '');
      if (url != null) {
        // 保结构路径（2026-09-30）：取原始 HTML 走 htmlToMarkdown，
        // 保留标题层级 / 列表 / 引用 / 代码块——旧 `fetchReadable` 会把结构全剥掉，
        // 富文本渲染器无米下锅。抓取失败再回退旧的纯文本路径。
        final html = await fetchHtml(url);
        if (html != null) {
          final doc = htmlToMarkdown(html);
          if (!doc.isEmpty) {
            // OG 元数据富化（rich-text-component.md §6.1 V2）：复用同一份 HTML
            // 顺带解析 og:*，url 条目从「一坨正文」变卡片；无 OG 标签则不写。
            final step = await _summarize(doc.markdown);
            return ReconstructResult(
              humanMd: doc.markdown,
              docMetaJson: jsonEncode(doc.meta.toJson()),
              machineJson: ogMachineJson(html),
              summaryMd: step?.summary,
              tags: step?.tags ?? const [],
            );
          }
        }
        final content = await fetchReadable(url);
        if (content != null) {
          final step = await _summarize(content);
          return ReconstructResult(
            humanMd: content,
            summaryMd: step?.summary,
            tags: step?.tags ?? const [],
          );
        }
      }
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '链接正文抓取未产出（网络不可达或页面无正文），已保留原始链接',
      );
    }
    return ReconstructResult(humanMd: input.rawContent ?? '');
  }

  /// R1 串联摘要步：回调不在位（模型未接/未下）即返回 null 静默跳过；
  /// 回调内部异常也按「无摘要」降级（DEGRADE），绝不卡抓取任务本身。
  Future<({String summary, List<String> tags})?> _summarize(String body) async {
    final step = summarizeHead;
    if (step == null) return null;
    try {
      return await step(body);
    } catch (e) {
      // DEGRADE: 摘要步失败不拖垮抓取产物，正文照常落库
      debugPrint('[DEGRADE] [OcrR1] summarize step failed: $e');
      return null;
    }
  }

  Future<String?> _ocr(String path) async {
    if (!File(path).existsSync()) {
      debugPrint('[OcrReconstructor] file missing: $path');
      return null;
    }
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final inputImage = InputImage.fromFilePath(path);
      // 超时兜底：ML Kit 在部分机型 / release 构建下可能挂起，若无超时将永久
      // 占住 _busy 与任务心跳，导致整个队列堵死、后续重新处理全部静默失效。
      final result = await recognizer.processImage(inputImage).timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException('processImage timeout 20s'),
          );
      final text = result.text.trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      debugPrint('[OcrReconstructor] OCR failed, fallback to placeholder: $e');
      return null;
    } finally {
      await recognizer.close();
    }
  }
}
