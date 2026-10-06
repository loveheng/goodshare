/// 工作流模型（2026-10-05 v21，SSOT：docs/design/block-artifact-workflow.md §3）。
///
/// 把「有什么能力、什么顺序」从页面游离的 if 升格为**按块类型的声明式 spec**：
/// 页面/Host 零类型判断，只问 spec。步骤是**产物 DAG** 而非线性链——
/// `consumes` 为「任一满足即可执行」的备选源集合（翻译可选 transcript 或
/// subtitle），`produces` 可多产物（转写一步双产物）。
///
/// 与既有抽象的关系（§3.1 实现参考边界）：
/// - **能力对象不废**：[WorkflowStep.command] 出口构造的仍是既有 ItemCommand
///   （TranscribeCommand / OcrCommand / …）——与 MCP 工具同源（R2 红线），
///   spec 只是编排视图，不复制实现；
/// - **执行不经 spec**：spec 只声明「点按钮产生什么命令」；入队 → 队列 FIFO →
///   重建器 → block_artifacts 落库走既有管线（§3.1 边界 1：禁止页内直跑）；
/// - **状态判定的唯一事实源是 block_artifacts**（§3.1 边界 5）：步骤的
///   done/ready/locked 由已有产物集合推导（[availabilityOf]），不持久化指针。
library;

import '../action/commands.dart';
import '../data/block_artifacts.dart' show BlockArtifactKind;
import 'capability.dart' show BlockKind;

/// 工作流步骤：消费产物 → 产出产物。
class WorkflowStep {
  const WorkflowStep({
    required this.id,
    required this.label,
    required this.consumes,
    required this.produces,
    this.extraKinds = const {},
    required this.command,
  });

  /// 步骤标识（'ocr' / 'transcribe' / 'translate' / 'summarize' / 'extract_audio'）。
  final String id;

  /// 轨上展示文案。
  final String label;

  /// 依赖的源产物 kind 集合——**任一存在即满足**（翻译可选文本或字幕）。
  /// 空 = 以块本体为源（转写/OCR/提取音轨直接读块媒体文件）。
  final Set<String> consumes;

  /// 产出的产物 kind 集合（转写 = transcript + subtitle 双产物）。
  /// 空 = 无块产物（textSpec 的条目级回注步骤，产物走条目级字段）。
  final Set<String> produces;

  /// 随生但不计入 `done` 判定的产物（拍板 16 补齐方案Ⅰ）：视频转写顺带落
  /// `audio_file` 音轨，但它不是「转写完成」的硬指标——音轨抽取失败
  /// 不应把已完成的文字产物卡成未完成。渲染时与 [produces] 一并出卡。
  final Set<String> extraKinds;

  /// 命令化出口（R2）：组装既有 ItemCommand 入队。[sourceKind] 仅翻译类步骤
  /// 需要（块产物翻译必须显式选源，动作层校验）；其余步骤忽略。
  final ItemCommand Function(String itemId, String blockKey, {String? sourceKind}) command;
}

/// 按块类型的工作流定义（编译期封闭，出现第五种块再升级注册表）。
class WorkflowSpec {
  const WorkflowSpec({required this.kind, required this.steps});

  final BlockKind kind;

  /// 展示顺序 = 推荐执行顺序（工作流轨自上而下渲染）。
  final List<WorkflowStep> steps;
}

/// 步骤可用性（由已有产物集合推导，§3.3 正式语义）。
enum WorkflowStepAvailability {
  /// 消费源不满足（灰显，标明缺什么）。
  locked,

  /// 消费源满足，可执行（含已完成步骤的**重跑**——重算即覆盖是既有拍板）。
  ready,

  /// 全部产物已存在（仍可重跑覆盖）。
  done,
}

/// 步骤可用性判定：done = produces 全部存在；ready = consumes 任一存在；
/// locked = 消费源缺失。produces 为空的条目级步骤（textSpec）恒 ready。
WorkflowStepAvailability availabilityOf(WorkflowStep step, Set<String> existingKinds) {
  if (step.produces.isNotEmpty && step.produces.every(existingKinds.contains)) {
    return WorkflowStepAvailability.done;
  }
  if (step.consumes.isEmpty || step.consumes.any(existingKinds.contains)) {
    return WorkflowStepAvailability.ready;
  }
  return WorkflowStepAvailability.locked;
}

/// 翻译类步骤的可选源（消费源 ∩ 已有产物）——三级页 segmented control 的选项集。
List<String> availableSources(WorkflowStep step, Set<String> existingKinds) => [
      for (final k in step.consumes)
        if (existingKinds.contains(k)) k,
    ];

// ───────────────────────────── 命令出口（R2：与 MCP 工具同源） ─────────────────────────────

ItemCommand _ocrCommand(String itemId, String blockKey, {String? sourceKind}) =>
    OcrCommand(itemId, blockKey: blockKey);

ItemCommand _transcribeCommand(String itemId, String blockKey, {String? sourceKind}) =>
    TranscribeCommand(itemId, blockKey: blockKey);

/// 块产物翻译：sourceKind 必带（动作层校验源产物存在非空）。
ItemCommand _translateCommand(String itemId, String blockKey, {String? sourceKind}) =>
    TranslateCommand(itemId, blockKey: blockKey, sourceKind: sourceKind);

ItemCommand _summarizeCommand(String itemId, String blockKey, {String? sourceKind}) =>
    SummarizeCommand(itemId, blockKey: blockKey);

/// 块提取音频（视频块）：源为块视频文件，产 `audio_file` 产物（内联播放/导出/锚点切换）。
ItemCommand _extractAudioCommand(String itemId, String blockKey, {String? sourceKind}) =>
    ExtractAudioCommand(itemId, blockKey: blockKey);

/// 条目级命令（textSpec：划词文本是选区不是持久块，走现行条目级回注，无块产物）。
ItemCommand _entryTranslate(String itemId, String blockKey, {String? sourceKind}) =>
    TranslateCommand(itemId);

ItemCommand _entrySummarize(String itemId, String blockKey, {String? sourceKind}) =>
    SummarizeCommand(itemId);

// ───────────────────────────── 四类块 spec（§3.2 用户设想定稿） ─────────────────────────────

const WorkflowSpec _imageSpec = WorkflowSpec(kind: BlockKind.image, steps: [
  WorkflowStep(
    id: 'ocr',
    label: '识别文字',
    consumes: {},
    produces: {BlockArtifactKind.ocrText},
    command: _ocrCommand,
  ),
  WorkflowStep(
    id: 'translate',
    label: '翻译',
    consumes: {BlockArtifactKind.ocrText},
    produces: {BlockArtifactKind.translation},
    command: _translateCommand,
  ),
  WorkflowStep(
    id: 'summarize',
    label: '摘要',
    // 摘要源=识别文字（2026-10-06 拍板：识别文字最准，译文不作源）——
    // 消费源收窄后执行侧遍历（queue_consumer 先 transcript 后 ocr_text）不变。
    consumes: {BlockArtifactKind.ocrText},
    produces: {BlockArtifactKind.summary},
    command: _summarizeCommand,
  ),
]);

const WorkflowSpec _audioSpec = WorkflowSpec(kind: BlockKind.audio, steps: [
  WorkflowStep(
    id: 'transcribe',
    label: '转写',
    consumes: {},
    produces: {BlockArtifactKind.transcript, BlockArtifactKind.subtitle},
    command: _transcribeCommand,
  ),
  WorkflowStep(
    id: 'translate',
    label: '翻译',
    consumes: {BlockArtifactKind.transcript, BlockArtifactKind.subtitle},
    produces: {BlockArtifactKind.translation},
    command: _translateCommand,
  ),
  WorkflowStep(
    id: 'summarize',
    label: '摘要',
    consumes: {BlockArtifactKind.transcript},
    produces: {BlockArtifactKind.summary},
    command: _summarizeCommand,
  ),
]);

/// 视频 = **提取音频（独立步骤）→ 转写（transcript + subtitle）→ 翻译 → 摘要**
/// （2026-10-05 按用户草图重排）：抽音轨**升回为轨内独立首步骤**「提取音频」
/// （拍板 16 曾降为转写内部实现，现恢复为显式用户动词——产 `audio_file` 产物，
/// 卡即「音轨」，承载内联播放/导出/锚点切换）。audio_file 由该步骤独占产出，
/// 转写不再顺带抽音轨；转写可经 `blockAudioFileOf` 复用已提取音轨省一次解码（§3.6）。
const WorkflowSpec _videoSpec = WorkflowSpec(kind: BlockKind.video, steps: [
  WorkflowStep(
    id: 'extract_audio',
    label: '提取音频',
    consumes: {},
    produces: {BlockArtifactKind.audioFile},
    command: _extractAudioCommand,
  ),
  WorkflowStep(
    id: 'transcribe',
    label: '转写',
    consumes: {},
    produces: {BlockArtifactKind.transcript, BlockArtifactKind.subtitle},
    command: _transcribeCommand,
  ),
  WorkflowStep(
    id: 'translate',
    label: '翻译',
    consumes: {BlockArtifactKind.transcript, BlockArtifactKind.subtitle},
    produces: {BlockArtifactKind.translation},
    command: _translateCommand,
  ),
  WorkflowStep(
    id: 'summarize',
    label: '摘要',
    consumes: {BlockArtifactKind.transcript},
    produces: {BlockArtifactKind.summary},
    command: _summarizeCommand,
  ),
]);

/// 文本块：无块产物（选区非持久块），走现行条目级回注；produces 空 = 纯视图态。
const WorkflowSpec _textSpec = WorkflowSpec(kind: BlockKind.text, steps: [
  WorkflowStep(id: 'translate', label: '翻译', consumes: {}, produces: {}, command: _entryTranslate),
  WorkflowStep(
    id: 'summarize',
    label: '摘要',
    consumes: {},
    produces: {},
    command: _entrySummarize,
  ),
]);

const List<WorkflowSpec> kWorkflowSpecs = [_imageSpec, _audioSpec, _videoSpec, _textSpec];

/// 按块类型取工作流（查表；BlockKind 封闭集合内恒命中）。
WorkflowSpec workflowFor(BlockKind kind) => kWorkflowSpecs.firstWhere((s) => s.kind == kind);
