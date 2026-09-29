import 'dart:io';

import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

import '../data/repository.dart';
import 'reconstructor.dart';
import 'image_labels_zh.dart';
import 'ml_capability.dart';

/// 图片分类（ML Kit Image Labeling，2026-09-29）：端侧、免费、base 模型 **bundled**，
/// 离线可用——与 translation 不同，不依赖 Google Play 动态下发语言包，国内无 GMS 也能跑。
///
/// 仅**手动触发**（`task_action=classify_image`，与 OCR / 转写同口径：摄入不自动跑模型），
/// 产出写入 `facets['分类']`（多视角聚类，AI 分类页消费）。英文标签经 [imageLabelZh]
/// 离线转中文，未命中保留英文。
///
/// 错误 / 空产出按 R1/R3 必须可观测：失败原因进 `note`，经队列落 `ai_task_queue.last_note`，
/// 最终出现在任务队列页 / 详情页状态条 / MCP `get_item`（人和 AI 读同一句）。
class ImageLabelCapability extends MlCapability {
  ImageLabelCapability();

  @override
  String get id => Repository.taskClassifyImage;

  @override
  ExecutionMode get mode => ExecutionMode.backgroundQueue;

  @override
  Future<CapabilityReadiness> ensureReady() async => CapabilityReadiness.ready;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == 'image' && input.taskAction == Repository.taskClassifyImage;

  /// 执行：创建 base 模型 labeler，对图片推理，返回已映射 + 已过滤的标签
  ///（文件缺失时标记 [ImageLabelRaw.fileMissing]，由归一化给出可观测原因）。
  @override
  Future<ImageLabelRaw> run(ReconstructInput input) async {
    final path = input.rawFilePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return ImageLabelRaw(const [], fileMissing: true);
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
      return ImageLabelRaw(tags.toSet().toList());
    } finally {
      await labeler.close();
    }
  }

  /// 后置归一化：原始标签 → 统一 [ReconstructResult]（facets / note 同口径，
  /// humanMd 基线取自 [input.rawContent]，与原 [AiReconstructor] 实现完全一致）。
  @override
  ReconstructResult normalize(Object? raw, ReconstructInput input) {
    final r = raw as ImageLabelRaw;
    final humanMd = input.rawContent ?? '';
    if (r.fileMissing) {
      return ReconstructResult(
        humanMd: humanMd,
        note: '图片文件缺失，无法分类',
      );
    }
    if (r.tags.isEmpty) {
      return ReconstructResult(
        humanMd: humanMd,
        note: '未识别出已知分类（图片可能过于抽象，或模型置信度均不足 0.5）',
      );
    }
    return ReconstructResult(
      humanMd: humanMd,
      facets: {'分类': r.tags},
      note: '已识别 ${r.tags.length} 个分类标签',
    );
  }
}

/// [run] 的原始输出：已映射 + 已过滤标签（或标记文件缺失）。
class ImageLabelRaw {
  const ImageLabelRaw(this.tags, {this.fileMissing = false});

  final List<String> tags;
  final bool fileMissing;
}
