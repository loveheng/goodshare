import 'dart:io';

import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

import '../data/repository.dart';
import 'reconstructor.dart';
import 'image_labels_zh.dart';

/// 图片分类（ML Kit Image Labeling，2026-09-29）：端侧、免费、base 模型 **bundled**，
/// 离线可用——与 translation 不同，不依赖 Google Play 动态下发语言包，国内无 GMS 也能跑。
///
/// 仅**手动触发**（`task_action=classify_image`，与 OCR / 转写同口径：摄入不自动跑模型），
/// 产出写入 `facets['分类']`（多视角聚类，AI 分类页消费）。英文标签经 [imageLabelZh]
/// 离线转中文，未命中保留英文。
///
/// 错误 / 空产出按 R1/R3 必须可观测：失败原因进 `note`，经队列落 `ai_task_queue.last_note`，
/// 最终出现在任务队列页 / 详情页状态条 / MCP `get_item`（人和 AI 读同一句）。
class ImageLabelReconstructor implements AiReconstructor {
  const ImageLabelReconstructor();

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == 'image' && input.taskAction == Repository.taskClassifyImage;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final path = input.rawFilePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '图片文件缺失，无法分类',
      );
    }
    final labeler = ImageLabeler(options: ImageLabelerOptions());
    try {
      final inputImage = InputImage.fromFilePath(path);
      // 模型推理通常毫秒级；极端机型 / 超大图可能挂起，超时兜底避免占住队列（与 OCR 同口径）。
      final labels = await labeler.processImage(inputImage)
          .timeout(const Duration(seconds: 20));
      final tags = <String>[];
      for (final l in labels) {
        if (l.confidence < 0.5) continue; // 低置信过滤（与 ImageLabelerOptions 默认阈值一致）
        final zh = imageLabelZh(l.label);
        tags.add(zh ?? l.label);
      }
      final unique = tags.toSet().toList();
      if (unique.isEmpty) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          note: '未识别出已知分类（图片可能过于抽象，或模型置信度均不足 0.5）',
        );
      }
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        facets: {'分类': unique},
        note: '已识别 ${unique.length} 个分类标签',
      );
    } catch (e) {
      // 失败也归占位完成（不置死信），但必须明说原因（R1/R3）。
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '图片分类失败：$e',
      );
    } finally {
      await labeler.close();
    }
  }
}
