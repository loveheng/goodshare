/// AI 双态重构输入：待处理的脏数据（V2 需求 §3.8 接口契约）。
class ReconstructInput {
  const ReconstructInput({
    required this.itemId,
    required this.itemType,
    this.sourceType,
    this.rawContent,
    this.rawFilePath,
  });

  final String itemId;
  final String itemType;
  final String? sourceType;
  final String? rawContent;
  final String? rawFilePath; // 附件路径（图片 OCR / 音频处理用）
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
  });

  final String humanMd;
  final Map<String, Object?>? machineJson;
  final List<String> tags;
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
    return ReconstructResult(humanMd: input.rawContent ?? '');
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
