import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/llm.dart';
import 'package:goodshare/ai/llm_reconstructor.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/data/repository.dart';

/// LlmReconstructor 契约单测：不可用时 note 必须携带**异步真值原因**（R1）——
/// 同步 unavailableReason 是桥层兜底文案（llm.dart:62），曾把「引擎初始化失败」
/// 误报成「未下载模型」（2026-10-02 实测：qwen 模型在机仍报未下载）。
void main() {
  ReconstructInput input(String action) => ReconstructInput(
        itemId: 'it-1',
        itemType: 'note',
        rawContent: '正文内容',
        taskAction: action,
      );

  test('引擎不可用：note 取 unavailableReasonAsync 真值而非同步兜底文案', () async {
    final engine = _FakeLlmEngine(
      available: false,
      syncReason: '端侧大模型引擎不可用（未下载模型或系统不支持）',
      asyncReason: '模型包初始化失败：qwen25-1.5b-q8 加载异常',
    );
    final r = await LlmReconstructor(engine: engine)
        .reconstruct(input(Repository.taskLlmSummarize));
    expect(r.note, contains('模型包初始化失败：qwen25-1.5b-q8 加载异常'));
    expect(r.note, isNot(contains('未下载模型或系统不支持')),
        reason: '兜底文案掩盖真因，AI/用户会被误导去重下模型');
    expect(r.humanMd, '正文内容', reason: '占位不卡死：human_md 原样保留');
  });

  test('引擎可用：摘要写 summary_md 不覆盖正文；关键词并入既有标签', () async {
    final engine = _FakeLlmEngine(
      available: true,
      output: '这是摘要。',
    );
    final r = await LlmReconstructor(engine: engine)
        .reconstruct(input(Repository.taskLlmSummarize));
    expect(r.summaryMd, '这是摘要。');
    expect(r.humanMd, '正文内容');

    final tags = await LlmReconstructor(engine: _FakeLlmEngine(
      available: true,
      output: '预算、 报销、机票',
    )).reconstruct(input(Repository.taskLlmTags));
    expect(tags.tags, containsAll(['预算', '报销', '机票']));
  });

  test('生成空产出：note 明示可重试（「完成但无产出」不静默成功）', () async {
    final r = await LlmReconstructor(engine: _FakeLlmEngine(available: true, output: ''))
        .reconstruct(input(Repository.taskLlmSummarize));
    expect(r.note, contains('可重试'));
    expect(r.summaryMd, isNull);
  });
}

class _FakeLlmEngine implements OnDeviceLlmEngine {
  const _FakeLlmEngine({
    required this.available,
    this.syncReason,
    this.asyncReason,
    this.output,
  });

  final bool available;
  final String? syncReason;
  final String? asyncReason;
  final String? output;

  @override
  String get name => '假引擎';

  @override
  Future<bool> get isAvailable async => available;

  @override
  String? get unavailableReason => syncReason;

  @override
  Future<String?> unavailableReasonAsync() async => asyncReason ?? syncReason;

  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async =>
      output;
}
