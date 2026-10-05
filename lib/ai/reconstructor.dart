import '../data/block_artifacts.dart' show BlockArtifactInput;
import 'video_clips.dart';

/// AI 双态重构输入：待处理的脏数据（V2 需求 §3.8 接口契约）。
class ReconstructInput {
  const ReconstructInput({
    required this.itemId,
    required this.itemType,
    this.sourceType,
    this.rawContent,
    this.humanMd,
    this.rawFilePath,
    this.taskAction,
    this.humanTags = const [],
    this.blockKey,
    this.blockFilePath,
    this.blockSourceText,
  });

  final String itemId;
  final String itemType;
  final String? sourceType;
  final String? rawContent;

  /// 已有人类态（翻译层需要：译文基于人类态产出，且不得回写覆盖它）。
  final String? humanMd;
  final String? rawFilePath; // 附件路径（图片 OCR / 音频处理用）

  /// 队列任务动作（`ai_task_queue.task_action`）。用于区分「摄入后的通用重构」与
  /// 「用户手动触发的专项处理」——音频转写仅手动（2026-09-28 用户拍板），
  /// 只有本值为 [Repository.taskTranscribeAudio] 时才走转写实现。
  final String? taskAction;

  /// 条目既有标签（LLM 关键词提取需并入既有标签，不覆盖用户手动打的）。
  final List<String> humanTags;

  /// 块附件通道（2026-10-05 v21，block-artifact-workflow.md §2.5 输入源分叉）：
  /// [blockKey] 非空 = 块任务（动作串 `block_*`），输入源为块媒体文件与块产物，
  /// **不是**条目级 rawFilePath / humanMd。
  final String? blockKey;

  /// 块媒体文件的沙箱绝对路径（queue_consumer 按 blockKey 解析后传入；
  /// 重建器不感知 local:// 标记与 documents 基路径）。null = 解析失败（文件缺失）。
  final String? blockFilePath;

  /// 块翻译/摘要的源产物文本（queue_consumer 从 block_artifacts 读出后传入；
  /// 无源产物时为 null，重建器按失败 + note 处理）。
  final String? blockSourceText;
}

/// AI 双态重构产出：人类态 / 机器态 / 标签 / 重分类 / 多视角聚类。
class ReconstructResult {
  const ReconstructResult({
    required this.humanMd,
    this.machineJson,
    this.tags = const [],
    this.masked = false,
    this.itemType,
    this.facets,
    this.translatedMd,
    this.translateLang,
    this.summaryMd,
    this.note,
    this.clip,
    this.docMetaJson,
    this.blockKey,
    this.blockArtifacts,
  });

  final String humanMd;
  final Map<String, Object?>? machineJson;

  /// 文档归一化元信息 JSON（2026-09-30）：覆盖率 + 降级 + 用户确认状态。
  /// 由归一化转换器产出，落 `inbox_items.doc_meta_json`（content-pipeline §7）。
  final String? docMetaJson;
  final List<String> tags;

  /// 译文（翻译层产出；与 humanMd 并列存储，不覆盖原文）。null = 无译文。
  final String? translatedMd;

  /// 译文语言码（BCP-47）；与 [translatedMd] 成对出现。
  final String? translateLang;

  /// 端侧 LLM 摘要（与 humanMd 并列存储，不覆盖原文；2026-09-28 v8）。null = 无摘要。
  final String? summaryMd;

  /// **原因说明**（2026-09-28）：降级 / 空产出 / 缺前置条件时写清"为什么"，
  /// 由消费者落进 `ai_task_queue.last_note`，最终出现在任务队列页、详情页状态条
  /// 与 MCP `get_item` 里——**人和 AI 读到的是同一句**。
  ///
  /// 非空不代表失败（降级仍可能产出结果），只是把"静默成功"变成"明说"。
  final String? note;

  /// 视频切片区间产出（2026-09-29，设计 docs/design/video-clips.md）。
  /// 非空时 handler 只把本段合并进条目的 `clips_json`（派生附属记录），
  /// **不触碰** human_md / summary_md 等条目级字段——区间结果不得覆盖整片产物。
  final ClipSegment? clip;

  /// 块附件通道产出（2026-10-05 v21，docs/design/block-artifact-workflow.md §2.5）：
  /// [blockKey] 非空 = 本次是块任务，[blockArtifacts] 为该块产物载荷——handler
  /// 据此单事务 upsert 进 block_artifacts（转写 transcript+subtitle 双产物原子落库），
  /// **human_md / translated_md / summary_md 等条目级字段零触碰**。
  /// 此时 humanMd 应为 input.rawContent（走 ApplyAiResult 的 rawEcho 保护保留现正文）。
  final String? blockKey;
  final List<BlockArtifactInput>? blockArtifacts;

  final bool masked; // 是否已执行隐私打码（V2 §3.4；占位实现恒 false）
  final String? itemType; // AI 重分类（如 image→chatlog）；null = 不改
  final Map<String, List<String>>? facets; // 多视角聚类：视角→标签（V2 AI 分类页消费）
}

/// AI 双态重构能力接口（V2 §3.8）：以接口定义能力，实现可插拔替换；
/// 队列 / UI / MCP 层不耦合任何单一后端。新增一种 AI 后端 = 实现接口 + 注册。
abstract class AiReconstructor {
  /// 设备是否具备运行该实现的能力（供运行期门控路由）。
  Future<bool> get isAvailable;

  /// 是否处理该输入类型（按条目类型路由，防止先注册的实现截胡其他类型的任务）。
  Future<bool> handles(ReconstructInput input);

  /// 执行双态重构：输入脏数据，产出人类态 / 机器态 / 标签。
  Future<ReconstructResult> reconstruct(ReconstructInput input);
}

/// V1 占位实现：raw_content 原样入 human_md、machine_json 留空、is_processed=1，
/// 保证端到端不卡死（PRD 模块二 v1 行为）；V2 由 SystemModelReconstructor 等替换。
class PlaceholderReconstructor implements AiReconstructor {
  const PlaceholderReconstructor();

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async => true;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    // 兜底占位：无具体实现处理该类型时落此。按 R3「降级须可观测」明说原因，
    // 否则用户/AI 看到内容原样、分不清「没跑 AI」还是「跑完零产出」。
    return ReconstructResult(
      humanMd: input.rawContent ?? '',
      note: '未执行 AI 重构（占位实现兜底：当前无对应处理模块），内容保留原始态',
    );
  }
}

/// 运行期路由（V2 §3.7/§3.8）：按输入类型取首个 handles 且 isAvailable 的实现；
/// 占位实现 handles 恒真、isAvailable 恒真，兜底不卡死。
/// 档位持久化与手动覆盖（强制 V1 / 尝试 V2）随 V2 §3.7 落地。
class ReconstructorRegistry {
  ReconstructorRegistry(this._impls) : assert(_impls.isNotEmpty, 'Registry 至少包含一个实现');

  final List<AiReconstructor> _impls;

  /// MVP 默认注册表：仅占位实现。
  static ReconstructorRegistry defaultRegistry() =>
      ReconstructorRegistry([const PlaceholderReconstructor()]);

  Future<AiReconstructor> resolve(ReconstructInput input) async {
    for (final impl in _impls) {
      if (await impl.handles(input) && await impl.isAvailable) return impl;
    }
    // 正常不可达：占位实现 handles/isAvailable 恒真
    throw StateError('Registry 中没有可用实现（应始终包含 PlaceholderReconstructor 兜底）');
  }
}
