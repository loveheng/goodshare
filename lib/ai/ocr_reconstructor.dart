import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'reconstructor.dart';

/// v1 消费者实现（2026-09-27 分期调整：OCR 从 V2 提前）：
/// - 图片条目：ML Kit 端侧文字识别（中文脚本），OCR 文本写入人类态；
/// - 其余类型：占位行为（raw_content 原样入 human_md）。
/// 受设置页「图片 OCR」开关门控（AiCapabilities），关闭或无能力时走占位。
/// 音频转写不在消费者内完成——Android 系统语音识别仅支持实时流，
/// 转写在速记采集时同步完成（写 raw 层，消费者照常占位复制），见 QuickNoteSheet。
/// 无 GMS 设备的 bundled OCR 变体适配为后续项（先支持标准设备）。
class OcrReconstructor implements AiReconstructor {
  const OcrReconstructor({this.isOcrEnabled});

  /// 是否允许 OCR（设置开关门控）；null = 恒允许。
  final bool Function()? isOcrEnabled;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final ocrOn = isOcrEnabled?.call() ?? true;
    if (ocrOn && input.itemType == 'image' && (input.rawFilePath?.isNotEmpty ?? false)) {
      final text = await _ocr(input.rawFilePath!);
      // OCR 不可用（无 GMS/模型未就绪）时优雅降级为占位行为，不置死信
      return ReconstructResult(humanMd: text ?? (input.rawContent ?? ''));
    }
    return ReconstructResult(humanMd: input.rawContent ?? '');
  }

  Future<String?> _ocr(String path) async {
    if (!File(path).existsSync()) return null;
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final inputImage = InputImage.fromFilePath(path);
      final result = await recognizer.processImage(inputImage);
      final text = result.text.trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      debugPrint('[OcrReconstructor] OCR failed, fallback to placeholder: $e');
      return null;
    } finally {
      recognizer.close();
    }
  }
}
