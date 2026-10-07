import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/share/note_seg.dart' show NoteTextSeg;
import 'package:goodshare/ui/composer_doc.dart' show ComposerDoc;

// 有序列表编辑期实时重排（治 #3「删整项留空洞序号」）回归：
// B+ 收口——删除型结构性变更经 applyTextEdit 门禁1(IME 绝热)+门禁2(删行特征)
// 通过后，在内存中一次性合成重排文本，与本次编辑原子落盘、记单步撤销。
void main() {
  // 确保活跃文本段 plain 已初始化为 [text]（构造若未解析则补同步）。
  ComposerDoc _seed(String text) {
    final doc = ComposerDoc([
      ['t', text]
    ]);
    final seg = doc.activeText!;
    if (seg.spans.plain != text) {
      seg.ctrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      doc.syncSegFromCtrl(seg);
      doc.consumeOutcome();
    }
    return doc;
  }

  test('选区删中间项：编辑期即重排（治 #3）', () {
    final doc = _seed('1. a\n2. b\n3. c');
    final seg = doc.activeText!;
    // 选区删「2. b\n」(offset 5..11)，光标落删区后端
    seg.ctrl.value = const TextEditingValue(
      text: '1. a\n3. c',
      selection: TextSelection.collapsed(offset: 5),
    );
    doc.applyTextEdit(seg, seg.ctrl.value);
    doc.consumeOutcome();
    expect(seg.spans.plain, '1. a\n2. c'); // 不再是空洞的「3. c」
    doc.disposeAll();
  });

  test('IME 组合态删中间项：绝热不重排（门禁1）', () {
    final doc = _seed('1. a\n2. b\n3. c');
    final seg = doc.activeText!;
    seg.ctrl.value = TextEditingValue(
      text: '1. a\n3. c',
      selection: const TextSelection.collapsed(offset: 5),
      composing: const TextRange(start: 0, end: 7), // 组合态
    );
    doc.applyTextEdit(seg, seg.ctrl.value);
    doc.consumeOutcome();
    expect(seg.spans.plain, '1. a\n3. c'); // 组合态绝不重写，留空洞待落地
    doc.disposeAll();
  });

  test('跨多组删：全文本重排（闭环断组跨删边界）', () {
    final doc = _seed('1. a\n2. b\n\n3. c\n4. d');
    final seg = doc.activeText!;
    // 删「2. b\n\n3. c」(跨两个有序组)，剩「1. a\n4. d」→ 4 应重排为 2
    seg.ctrl.value = const TextEditingValue(
      text: '1. a\n4. d',
      selection: TextSelection.collapsed(offset: 5),
    );
    doc.applyTextEdit(seg, seg.ctrl.value);
    doc.consumeOutcome();
    expect(seg.spans.plain, '1. a\n2. d');
    doc.disposeAll();
  });

  test('选区删中间项：单步撤销还原（含原空洞序号）', () {
    final doc = _seed('1. a\n2. b\n3. c');
    final seg = doc.activeText!;
    seg.ctrl.value = const TextEditingValue(
      text: '1. a\n3. c',
      selection: TextSelection.collapsed(offset: 5),
    );
    doc.applyTextEdit(seg, seg.ctrl.value);
    doc.consumeOutcome();
    expect(seg.spans.plain, '1. a\n2. c'); // 重排后
    doc.undo();
    doc.consumeOutcome();
    // 撤销重建 segs（旧 seg 实例失效），取活跃段断言：一步还原删前整行 + 原空洞
    expect(doc.activeText!.spans.plain, '1. a\n2. b\n3. c');
    doc.disposeAll();
  });

  test('纯中段删字：不触发重排（O(1) 放行，门禁2 充要）', () {
    final doc = _seed('1. apple\n2. banana');
    final seg = doc.activeText!;
    // 删「pple」(offset 2..7)，不跨行、不含 marker
    seg.ctrl.value = const TextEditingValue(
      text: '1. a\n2. banana',
      selection: TextSelection.collapsed(offset: 2),
    );
    doc.applyTextEdit(seg, seg.ctrl.value);
    doc.consumeOutcome();
    expect(seg.spans.plain, '1. a\n2. banana'); // 序号未被动
    doc.disposeAll();
  });
}
