/// ML 能力统一抽象（2026-09-29 决策）。
///
/// 背景：本机端侧 ML 能力快速增长（图片分类 / 条码 / 语言识别 / 实体提取 /
/// 文档扫描 / 人脸 / 物体 / 姿势），且 Android 与 iOS 均调用各自官方 ML Kit。
/// 为保证「官方效果一致」+「人 / AI / 双端同一份状态」，把所有能力收口到本抽象：
///
/// - **前置（ensureReady / handles）**：环境 / 能力检测（如 document_scanner 的
///   GMS 可用性）、任务路由。不可用时返回 [CapabilityReadiness.unavailable(reason)]，
///   reason 进 UI / MCP 提示（R1 可观测）。
/// - **执行（run）**：平台差异只活在这里（各自调官方插件），Android / iOS 同族。
/// - **后置（normalize）**：原始输出 → 统一 [ReconstructResult]（facets / note 同口径，
///   保证双端产出一致、人和 AI 读同一句）。
/// - **后置（dispose）**：释放常驻模型。
///
/// 与 [AiReconstructor] 的关系：[MlCapability] **直接 implements** [AiReconstructor]，
/// 不再需要独立适配器——[reconstruct] 已默认组合 前置(ensureReady) + 执行(run) +
/// 后置(normalize)，旧 / 新 ML 能力均以 [MlCapability] 实现统一接入
/// [ReconstructorRegistry]，[QueueConsumer] 零改动。

library;

import 'reconstructor.dart';

/// 能力执行形态。
enum ExecutionMode {
  /// 后台异步队列（条码 / 语言识别 / 实体提取 / 图片分类）。
  backgroundQueue,

  /// 前台调起系统 UI（文档扫描相机流程）；不经队列，UI 直接 ensureReady + run。
  foregroundUi,

  /// 预留占位（人脸 / 物体 / 姿势）：不引依赖、不实现，仅留接口不抢相册职责。
  placeholder,
}

/// 前置初始化结果：环境是否允许 + 不可用时原因（R1 可观测）。
class CapabilityReadiness {
  const CapabilityReadiness(this.available, [this.reason]);

  final bool available;

  /// 不可用时的人类可读原因（如「设备无 Google Play 服务，文档扫描不可用」）。
  final String? reason;

  static const ready = CapabilityReadiness(true);

  factory CapabilityReadiness.unavailable(String reason) =>
      CapabilityReadiness(false, reason);
}

/// 所有 ML 能力统一抽象，**直接实现** [AiReconstructor]（无需独立适配器）：[reconstruct]
/// 已默认组合 前置(ensureReady) + 执行(run) + 后置(normalize)，子类只需实现
/// ensureReady / handles / run / normalize。
abstract class MlCapability implements AiReconstructor {
  /// 能力标识，约定等于后台队列类的 task_action 常量值（如 'scan_barcode'），
  /// 用于路由与 UI / MCP 入口对齐。
  String get id;

  ExecutionMode get mode;

  /// 前置初始化器：环境允许？模型就绪？[document_scanner] 的 GMS 检测在此。
  /// 不可用时返回 [CapabilityReadiness.unavailable]，reason 进 UI / MCP 提示。
  Future<CapabilityReadiness> ensureReady();

  /// 前置路由：是否处理该输入（按 task_action / itemType）。
  @override
  Future<bool> handles(ReconstructInput input);

  /// 执行：平台差异只活在这里（各自调官方插件）。
  Future<Object?> run(ReconstructInput input);

  /// 后置归一化器：原始输出 → 统一 [ReconstructResult]（facets / note 同口径）。
  /// 入参 [input] 用于取 rawContent 基线等人 / AI 共享上下文。
  ReconstructResult normalize(Object? raw, ReconstructInput input);

  /// 后置释放：释放常驻模型（可选 override）。
  Future<void> dispose() async {}

  @override
  Future<bool> get isAvailable async => (await ensureReady()).available;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final ready = await ensureReady();
    if (!ready.available) {
      // 能力不可用（如环境不允许）：降级为占位完成并明说原因（R1 / R3）。
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: ready.reason ?? '能力当前不可用（已降级，未执行）',
      );
    }
    try {
      return normalize(await run(input), input);
    } catch (e) {
      // 执行异常也归占位完成，原因进 note（绝不静默）。
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '处理失败：$e',
      );
    }
  }
}
