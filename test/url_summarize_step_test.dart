import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/llm.dart';
import 'package:goodshare/ai/llm_reconstructor.dart';
import 'package:goodshare/ai/ocr_reconstructor.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/data/repository.dart';

/// R1 串联式摘要步契约（2026-10-09 二次收敛）：
/// 抓取与摘要在同一任务内顺序执行（OcrReconstructor.summarizeHead 回调
/// LlmReconstructor.summarizeUrlHead），无跨任务链、无开关、无防环闸。
void main() {
  ReconstructInput urlInput() => const ReconstructInput(
        itemId: 'it-1',
        itemType: 'url',
        rawContent: 'https://example.com/a',
        taskAction: Repository.taskSummarizeUrl,
      );

  test('串联收敛：summarize_url 队列任务不再被 LlmReconstructor 认领（占位消化）', () async {
    final r = await LlmReconstructor(engine: _FakeLlmEngine(available: true, output: '不该被调用'))
        .reconstruct(urlInput());
    expect(r.humanMd, 'https://example.com/a');
    expect(r.summaryMd, isNull);
  });

  test('summarizeUrlHead：短文直出摘要+TAGS 解析', () async {
    final step = LlmReconstructor(engine: _FakeLlmEngine(
      available: true,
      output: '这篇文章讲 X。\n\nTAGS: 前端、性能',
    ));
    final r = await step.summarizeUrlHead('正文内容');
    expect(r, isNotNull);
    expect(r!.summary, '这篇文章讲 X。');
    expect(r.tags, ['前端', '性能']);
  });

  test('summarizeUrlHead：超 1500 字符头部截断直出（不哑火）', () async {
    String? captured;
    final engine = _CaptureEngine(output: '摘要', onPrompt: (p) => captured = p);
    final step = LlmReconstructor(engine: engine);
    final r = await step.summarizeUrlHead('x' * 5000);
    expect(r, isNotNull, reason: '头部截断直出，不一刀切回退（真实长文 3000-8000 字不哑火）');
    expect(captured!.length, lessThan(1600), reason: '只送头部 1500 字符');
    expect(captured, contains('…'));
  });

  test('summarizeUrlHead：模型不在位 → null 静默跳过（不占 note）', () async {
    final step = LlmReconstructor(engine: _FakeLlmEngine(available: false));
    expect(await step.summarizeUrlHead('正文'), isNull);
  });

  test('summarizeUrlHead：引擎抛异常 → null 降级（不拖垮抓取任务）', () async {
    final step = LlmReconstructor(engine: _ThrowingEngine());
    expect(await step.summarizeUrlHead('正文'), isNull);
  });

  test('OcrReconstructor.summarizeHead 回调不在位 → 摘要步整体跳过', () async {
    // 直接验证 _summarize 的 null 语义：summarizeHead=null 时无需引擎
    // （端到端抓取依赖网络，此处只钉回调契约：null 回调 = 无摘要产出路径）
    const r1 = OcrReconstructor(); // summarizeHead 未注入
    expect(r1.summarizeHead, isNull);
  });
}

class _FakeLlmEngine implements OnDeviceLlmEngine {
  const _FakeLlmEngine({required this.available, this.output});
  final bool available;
  final String? output;
  @override
  String get name => '假引擎';
  @override
  Future<String?> unavailableReasonAsync() async => null;
  @override
  Future<bool> get isAvailable async => available;
  @override
  String? get unavailableReason => null;
  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async => output;
}

class _CaptureEngine implements OnDeviceLlmEngine {
  @override
  Future<String?> unavailableReasonAsync() async => null;
  const _CaptureEngine({required this.output, this.onPrompt});
  final String output;
  final void Function(String prompt)? onPrompt;
  @override
  String get name => '捕获引擎';
  @override
  Future<bool> get isAvailable async => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async {
    onPrompt?.call(prompt);
    return output;
  }
}

class _ThrowingEngine implements OnDeviceLlmEngine {
  @override
  Future<String?> unavailableReasonAsync() async => null;
  const _ThrowingEngine();
  @override
  String get name => '抛错引擎';
  @override
  Future<bool> get isAvailable async => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async =>
      throw StateError('模拟推理失败');
}
