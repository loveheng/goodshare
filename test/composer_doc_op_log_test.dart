// ops 日志化蓄力（阶段二）：验证 ComposerDoc 把编辑动作显式化为 EditOp 序列
//（InsertText / Delete / FormatRange / StructureOp），且 opLog 独立于撤销栈、
// 零行为变更。引擎纯逻辑、不依赖 widget，直接驱动 ComposerDoc。
//
// 注意：真实流程中 TextField 先改 ctrl.text，onChanged 才带 next 调 applyTextEdit；
// syncSegFromCtrl 读的是 ctrl.text，故 _type 需先同步 ctrl.text/selection。
import 'package:flutter/services.dart' show TextEditingValue, TextSelection;
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/composer_doc.dart'
    show ComposerDoc, DeleteOp, EditOp, FormatRangeOp, InsertTextOp, StructureOp;
import 'package:goodshare/doc/rich_text.dart'
    show InlineMark, SpanListKind, SpanListRun;
import 'package:goodshare/share/note_seg.dart' show NoteTextSeg;

NoteTextSeg _lastText(ComposerDoc doc) =>
    doc.segs.whereType<NoteTextSeg>().last;

/// 模拟真实输入：TextField 已接受文本（ctrl.text/selection 更新），再交 applyTextEdit。
void _type(ComposerDoc doc, NoteTextSeg seg, String s) {
  final v = TextEditingValue(
      text: s, selection: TextSelection.collapsed(offset: s.length));
  seg.ctrl.text = s;
  seg.ctrl.selection = v.selection;
  doc.applyTextEdit(seg, v);
}

void main() {
  test('打字插入记 InsertTextOp（pos/text/segId 准确）', () {
    final doc = ComposerDoc([
      ['t', '']
    ]);
    final seg = _lastText(doc);
    doc.activeSegId = seg.id;
    _type(doc, seg, 'a');
    expect(doc.opLog, hasLength(1));
    final op = doc.opLog.single as InsertTextOp;
    expect(op.segId, seg.id);
    expect(op.pos, 0);
    expect(op.text, 'a');
  });

  test('连打后删：InsertText + Delete 序列与区间正确', () {
    final doc = ComposerDoc([
      ['t', '']
    ]);
    final seg = _lastText(doc);
    doc.activeSegId = seg.id;
    _type(doc, seg, 'a');
    _type(doc, seg, 'ab');
    _type(doc, seg, 'a');
    expect(doc.opLog, hasLength(3));
    expect(doc.opLog[0], isA<InsertTextOp>());
    expect(doc.opLog[1], isA<InsertTextOp>());
    final del = doc.opLog[2];
    expect(del, isA<DeleteOp>());
    expect((del as DeleteOp).start, 1);
    expect(del.end, 2);
    expect(del.segId, seg.id);
  });

  test('选区加粗记 FormatRangeOp（start/end/mark）', () {
    final doc = ComposerDoc([
      ['t', 'ab']
    ]);
    final seg = _lastText(doc);
    doc.activeSegId = seg.id;
    seg.ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    doc.applyMarkToSelection(seg, InlineMark.bold);
    final op = doc.opLog.whereType<FormatRangeOp>().single;
    expect(op.segId, seg.id);
    expect(op.start, 0);
    expect(op.end, 2);
    expect(op.mark, InlineMark.bold);
  });

  test('待办勾选记 StructureOp(kind=toggleTodo)', () {
    final doc = ComposerDoc([
      ['t', '- [ ] 买菜']
    ]);
    final seg = _lastText(doc);
    doc.activeSegId = seg.id;
    final target = SpanListRun(0, seg.spans.plain.length, SpanListKind.todo);
    doc.toggleTodo(seg, target);
    final op = doc.opLog.whereType<StructureOp>().single;
    expect(op.segId, seg.id);
    expect(op.kind, 'toggleTodo');
    // 文本真相：勾选改写 [ ]→[x]
    expect(seg.spans.plain, '- [x] 买菜');
  });

  test('opLog 独立于撤销栈：undo 不清除已记录 op', () {
    final doc = ComposerDoc([
      ['t', '']
    ]);
    final seg = _lastText(doc);
    doc.activeSegId = seg.id;
    _type(doc, seg, 'hi');
    expect(doc.opLog.whereType<InsertTextOp>().single.text, 'hi');
    doc.undo();
    // 撤销只回滚文本/光标，opLog 审计流保留（为未来 CRDT/OT 重放）
    expect(doc.opLog, isNotEmpty);
    expect(doc.opLog.whereType<InsertTextOp>().single.text, 'hi');
  });

  test('环形缓冲：超 kOpLogCap 后裁剪最旧', () {
    final doc = ComposerDoc([
      ['t', '']
    ]);
    final seg = _lastText(doc);
    doc.activeSegId = seg.id;
    for (var i = 0; i < ComposerDoc.kOpLogCap + 5; i++) {
      _type(doc, seg, 'x$i');
    }
    expect(doc.opLog.length, ComposerDoc.kOpLogCap);
    // 最旧 op（首次输入的 'x0'）已被裁剪
    expect(doc.opLog.whereType<InsertTextOp>().any((o) => o.text == 'x0'),
        isFalse);
  });
}
