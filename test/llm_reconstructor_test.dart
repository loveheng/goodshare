import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/llm.dart';
import 'package:goodshare/ai/llm_reconstructor.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/data/repository.dart';

/// LlmReconstructor 契约单测：不可用时 note 必须携带**异步真值原因**（R1）——
/// 同步 unavailableReason 是桥层兜底文案（llm.dart:62），曾把「引擎初始化失败」
/// 误报成「未下载模型」（2026-10-02 实测：qwen 模型在机仍报未下载）。
void main() {

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

  // ─── R1 摄入自动重构（2026-10-09 收敛拍板：仅 URL 摘要+打标，chatlog 已砍 §1.1a） ───

  test('R1 chatlog 收敛：parse_chatlog 不再被认领（回归占位消化）', () async {
    final r = await LlmReconstructor(engine: _FakeLlmEngine(available: true, output: '不该被调用'))
        .reconstruct(input(Repository.taskParseChatlog));
    expect(r.humanMd, '正文内容', reason: '收敛后 chatlog 降噪砍除，LlmReconstructor 不认领（由占位兜底）');
  });

  test('R1 串联收敛：summarize_url 不再被认领（摘要走 summarizeHead 串联步）', () async {
    final r = await LlmReconstructor(engine: _FakeLlmEngine(available: true, output: '不该被调用'))
        .reconstruct(input(Repository.taskSummarizeUrl, humanMd: '抓取的正文'));
    expect(r.humanMd, '抓取的正文', reason: '不认领即占位复制');
    expect(r.summaryMd, isNull);
  });

  test('R1 summarizeUrlHead：头部 1500 截断直出 + TAGS 解析（替代 D3 一刀切）', () async {
    final step = LlmReconstructor(engine: _FakeLlmEngine(
      available: true,
      output: 'TL;DR：这篇文章讲 X。\n\nTAGS: 前端、性能',
    ));
    // 短文
    final short = await step.summarizeUrlHead('正文');
    expect(short, isNotNull);
    expect(short!.summary, 'TL;DR：这篇文章讲 X。');
    expect(short.tags, ['前端', '性能']);
    // 长文：5000 字符仍出摘要（不哑火）
    final long = await step.summarizeUrlHead('x' * 5000);
    expect(long, isNotNull, reason: '头部截断直出，真实长文不回退');
  });

  test('R1 引擎不可用：note 带真值原因、human_md 原样', () async {
    final r = await LlmReconstructor(engine: _FakeLlmEngine(
      available: false,
      asyncReason: '模型未下载',
    )).reconstruct(input(Repository.taskSummarizeUrl, humanMd: '正文'));
    expect(r.note, contains('模型未下载'));
    expect(r.humanMd, '正文');
    expect(r.summaryMd, isNull);
  });
}

/// [_FakeLlmEngine] 的 input 辅助（可选 humanMd/humanTags/rawContent）。
ReconstructInput input(String action,
        {String? humanMd, List<String> humanTags = const [], String? rawContent}) =>
    ReconstructInput(
      itemId: 'it-1',
      itemType: 'note',
      rawContent: rawContent ?? '正文内容',
      humanMd: humanMd,
      humanTags: humanTags,
      taskAction: action,
    );

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
