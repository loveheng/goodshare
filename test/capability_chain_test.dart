import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/capability.dart';
import 'package:goodshare/ai/capability_chain.dart';

void main() {
  test('链推进：完成→指针前移，产出 raw 记录', () {
    final chain = CapabilityChain(capabilitiesFor(BlockKind.image))..init();
    expect(chain.currentStep!.id, 'ocr');
    chain.beginStep();
    chain.completeStep('识别出的文字');
    expect(chain.states[0], StepState.done);
    expect(chain.current, 1);
    expect(chain.currentStep!.id, 'translate');
    expect(chain.outputs[0]!.effective, '识别出的文字');
  });

  test('失败停步：指针不推进，retry 后只重跑失败步，前步产出完好', () {
    final chain = CapabilityChain(capabilitiesFor(BlockKind.image))..init();
    chain.beginStep();
    chain.completeStep('OCR 文本');
    chain.beginStep();
    chain.failStep();
    expect(chain.states[1], StepState.failed);
    expect(chain.current, 1); // 停在失败步
    chain.retry();
    expect(chain.states[1], StepState.pending);
    expect(chain.outputs[0]!.raw, 'OCR 文本'); // 前步完好
  });

  test('中断续跑：restore 按已落库产出反推进点', () {
    final chain = CapabilityChain(capabilitiesFor(BlockKind.image))..init();
    chain.restore(['已落库的 OCR 文本', null]);
    expect(chain.current, 1);
    expect(chain.currentStep!.id, 'translate');
    expect(chain.outputs[0]!.raw, '已落库的 OCR 文本');
  });

  test('人工修订：写 edited 不动 raw，effective 取修订', () {
    final chain = CapabilityChain(capabilitiesFor(BlockKind.image))..init();
    chain.beginStep();
    chain.completeStep('AI 原文');
    chain.editOutput(0, '人工改过');
    expect(chain.outputs[0]!.raw, 'AI 原文');
    expect(chain.outputs[0]!.effective, '人工改过');
    expect(chain.outputs[0]!.isEdited, true);
  });

  test('Reset：清全部产出归零', () {
    final chain = CapabilityChain(capabilitiesFor(BlockKind.image))..init();
    chain.beginStep();
    chain.completeStep('x');
    chain.reset();
    expect(chain.current, 0);
    expect(chain.outputs[0], isNull);
    expect(chain.currentStep!.id, 'ocr');
  });

  test('图片链=全部适用能力（改版拍板：链=capabilitiesFor 全量，无预编排子链）', () {
    expect(capabilitiesFor(BlockKind.image).map((c) => c.id).toList(),
        ['ocr', 'translate', 'summarize']);
    expect(capabilitiesFor(BlockKind.video).map((c) => c.id).toList(),
        ['transcribe', 'translate', 'summarize']);
    expect(capabilitiesFor(BlockKind.text).map((c) => c.id).toList(),
        ['translate', 'summarize']);
    expect(
        capabilitiesFor(BlockKind.image).map((c) => c.id), isNot(contains('transcribe')));
  });

  test('独立能力按类型分发（二级页内容能力 chips 拆入三级页）', () {
    expect(standaloneFor(BlockKind.image).map((c) => c.id).toList(),
        ['annotate', 'classify', 'scan_barcode']);
    expect(standaloneFor(BlockKind.video).map((c) => c.id).toList(),
        ['clip', 'whole_mark']);
    expect(standaloneFor(BlockKind.text).map((c) => c.id).toList(),
        ['analyze_text']);
    expect(standaloneFor(BlockKind.audio), isEmpty);
  });
}
