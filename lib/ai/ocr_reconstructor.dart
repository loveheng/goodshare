import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../data/repository.dart';
import 'reconstructor.dart';
import 'url_extract.dart';

/// v1 消费者实现（2026-09-27 分期调整：OCR 从 V2 提前）：
/// - 图片条目：ML Kit 端侧文字识别（中文脚本），OCR 文本写入人类态；
/// - 其余类型：占位行为（raw_content 原样入 human_md）。
/// 受设置页「图片 OCR」开关门控（AiCapabilities），关闭或无能力时走占位。
/// 音频转写不做（2026-09-27 用户拍板去掉边录边转），录音仅存音频文件。
/// 无 GMS 设备的 bundled OCR 变体适配为后续项（先支持标准设备）。
class OcrReconstructor implements AiReconstructor {
  const OcrReconstructor({this.isOcrEnabled, this.isUrlFetchEnabled});

  /// 是否允许 OCR（设置开关门控）；null = 恒允许。
  final bool Function()? isOcrEnabled;

  /// 是否允许链接离线抓取网页正文（设置开关门控）；null = 恒允许。
  final bool Function()? isUrlFetchEnabled;

  @override
  Future<bool> get isAvailable async => true;

  /// 处理图片（OCR）与链接（离线抓取）；音频/文本由其他实现或占位兜底。
  @override
  Future<bool> handles(ReconstructInput input) async {
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
    if (ocrOn && input.itemType == 'image' && (input.rawFilePath?.isNotEmpty ?? false)) {
      final text = await _ocr(input.rawFilePath!);
      return ReconstructResult(humanMd: text ?? input.rawContent ?? '');
    }
    // 链接离线成内容（2026-09-27 决策）：抓取网页正文写入人类态；失败回退占位
    final fetchOn = isUrlFetchEnabled?.call() ?? true;
    if (fetchOn && input.itemType == 'url') {
      final url = firstUrl(input.rawContent ?? '');
      if (url != null) {
        final content = await fetchReadable(url);
        if (content != null) return ReconstructResult(humanMd: content);
      }
    }
    return ReconstructResult(humanMd: input.rawContent ?? '');
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
