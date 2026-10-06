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
    // 2026-10-05：视频独立能力 = 切片一项——提取音轨升为「提取音频」首步骤，
    // 字幕导出由字幕产物卡「导出」承载，不再双入口。
    expect(standaloneFor(BlockKind.video).map((c) => c.id).toList(), ['clip']);
    // 分析文本无人类 chip（2026-10-05 拍板）：facets 为机器维度（MCP/V2 聚类），
    // 与标签展示重复——文本块无独立能力，「独立能力」区整段不渲染。
    expect(standaloneFor(BlockKind.text).map((c) => c.id).toList(), isEmpty);
    // 音频（2026-10-05 扩展）：切片共享——转写即出字幕产物卡（含导出）。
    expect(standaloneFor(BlockKind.audio).map((c) => c.id).toList(), ['clip']);
  });
}
