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

  test('R1 头部准备清洗：链接只留 text、代码围栏剥离、段落边界收束（2026-10-10 保真修正）', () async {
    // 链接密集型头部：URL 不占预算——清洗后 5000 字符输入的头部含第 N 段正文
    final linky = [for (var i = 0; i < 40; i++) '[条目$i](https://example.com/very/long/path/$i)\n\n段落${'内容' * 30}'].join('\n\n');
    final r1 = await LlmReconstructor(engine: _CaptureEngine(available: true)).summarizeUrlHead(linky);
    expect(r1, isNotNull);
    expect(_CaptureEngine.lastPrompt, isNot(contains('https://example.com')), reason: 'URL 不计入摘要预算');
    expect(_CaptureEngine.lastPrompt, contains('条目0'), reason: '链接 text 保留');
    // 代码围栏剥离
    final fenced = '开头\n\n```dart\n${'code' * 600}\n```\n\n结尾正文';
    await LlmReconstructor(engine: _CaptureEngine(available: true)).summarizeUrlHead(fenced);
    expect(_CaptureEngine.lastPrompt, isNot(contains('codecode')), reason: '围栏内容不进头部');
    expect(_CaptureEngine.lastPrompt, contains('结尾正文'), reason: '围栏剥离后预算让给正文');
    // 段落边界：超 1500 时整段收录、不在段中间硬切
    final paras = [for (var i = 0; i < 10; i++) '第${'甲' * 400}段$i'].join('\n\n');
    await LlmReconstructor(engine: _CaptureEngine(available: true)).summarizeUrlHead(paras);
    expect(_CaptureEngine.lastPrompt!.length, lessThan(1600), reason: '预算 ~1500 上限');
    expect(_CaptureEngine.lastPrompt!.endsWith('…'), isTrue, reason: '截断以省略号标记');
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

/// 捕获 prompt 的假引擎（验证头部清洗产物用）。
class _CaptureEngine implements OnDeviceLlmEngine {
  const _CaptureEngine({required this.available});

  final bool available;
  static String? lastPrompt;

  @override
  String get name => '捕获引擎';

  @override
  Future<bool> get isAvailable async => available;

  @override
  String? get unavailableReason => null;

  @override
  Future<String?> unavailableReasonAsync() async => null;

  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async {
    lastPrompt = prompt;
    return 'TL;DR：摘要。\n\nTAGS: 测试';
  }
}
