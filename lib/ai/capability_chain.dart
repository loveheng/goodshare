import 'capability.dart';

/// 链步骤产出（detail-two-zone.md §5.3 预警补丁：raw/edited 双字段）。
///
/// 「修订不覆盖原 OCR 段」的结构化落地：AI 原始输出永久保留（零算力
/// 回退 + 可对比），人工修订写 edited；消费方取 [effective]（edited 优先）。
class StepOutput {
  StepOutput({required this.raw, this.edited});

  /// AI 原始输出（落库即定，Reset 前不消失）。
  final String raw;

  /// 人工修订（null = 未改过）。
  String? edited;

  /// 消费方视角的有效文本：修订优先。
  String get effective => (edited != null && edited!.trim().isNotEmpty)
      ? edited!
      : raw;

  bool get isEdited => edited != null && edited != raw;
}

/// 链步骤的运行时状态。
enum StepState { pending, running, done, failed }

/// 任务链状态机（detail-two-zone.md §5.3）：纯模型零 UI（可测试、可被
/// AI 复用）——能力卡/三级页只是它的视图。
///
/// 边界语义（11 条预警打磨定稿）：
/// - **完成即落库**：步骤成功 → [outputs] 记产出，调用方负责持久化到块附件；
/// - **中断续跑**：指针不持久化——重建链时 [resumeFrom] 按「哪些步已有
///   产出」反推续点（比存步号更抗中断）；
/// - **失败停步**：步骤报错 → 该步 [failed]，指针**停在失败步不推进**，
///   已落库的前步产出完好（[retry] 只重跑失败步）；
/// - **Reset**：清全部产出归零（配合危险确认由 UI 层负责），重新触发。
class CapabilityChain {
  CapabilityChain(List<ContentCapability> steps)
      : steps = List.unmodifiable(steps);

  /// 预编排步骤（如 [Ocr, Translate]）。
  final List<ContentCapability> steps;

  /// 当前指针：指向待执行/失败步。
  int current = 0;

  /// 各步状态（与 [steps] 对齐）。
  final List<StepState> states = [];

  /// 各步产出（与 [steps] 对齐，pending 步为 null）。
  final List<StepOutput?> outputs = [];

  bool get isFinished => current >= steps.length;

  /// 当前步能力；链已走完返回 null。
  ContentCapability? get currentStep =>
      isFinished ? null : steps[current];

  /// 初始化状态数组（构造后调用一次；重建续跑场景由 [restore] 代替）。
  void init() {
    states
      ..clear()
      ..addAll(List.filled(steps.length, StepState.pending));
    outputs
      ..clear()
      ..addAll(List<StepOutput?>.filled(steps.length, null));
    current = 0;
  }

  /// 从已落库产出重建（中断续跑）：`persisted` 为各步已落库文本（无则
  /// null）——首个缺产出的步即续点，无需持久化指针。
  void restore(List<String?> persisted) {
    init();
    for (var i = 0; i < steps.length && i < persisted.length; i++) {
      final text = persisted[i];
      if (text == null || text.trim().isEmpty) break;
      outputs[i] = StepOutput(raw: text);
      states[i] = StepState.done;
      current = i + 1;
    }
  }

  /// 标记当前步开始执行（UI 层在调 capture 前置 running 态）。
  void beginStep() {
    if (isFinished) return;
    _ensureLen(current + 1);
    states[current] = StepState.running;
  }

  /// 当前步成功：记产出（raw），指针推进。
  void completeStep(String rawOutput) {
    if (isFinished) return;
    outputs[current] = StepOutput(raw: rawOutput);
    states[current] = StepState.done;
    current += 1;
  }

  /// 人工修订当前步（已完成步的）产出：写 edited 不动 raw，指针不变。
  void editOutput(int stepIndex, String edited) {
    if (stepIndex < 0 || stepIndex >= outputs.length) return;
    final out = outputs[stepIndex];
    if (out == null) return;
    out.edited = edited;
  }

  /// 当前步失败：停步不推进（产出区不写）。
  void failStep() {
    if (isFinished) return;
    states[current] = StepState.failed;
  }

  /// 重试失败步：状态回 pending，指针不动（仍指失败步）。
  void retry() {
    if (isFinished) return;
    if (states[current] == StepState.failed) {
      states[current] = StepState.pending;
    }
  }

  /// Reset：清全部产出与状态归零（UI 层负责二次确认 + 持久层同步清除）。
  void reset() {
    init();
  }

  /// 供视图渲染的只读快照。
  List<StepState> get statesView => List.unmodifiable(states);

  List<StepOutput?> get outputsView => List.unmodifiable(outputs);

  void _ensureLen(int len) {
    while (states.length < len) {
      states.add(StepState.pending);
    }
    while (outputs.length < len) {
      outputs.add(null);
    }
  }
}
