import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/share/note_seg.dart' show NoteTextSeg;
import 'package:goodshare/share/quick_note_text_actions.dart'
    show LineKindTarget, setLineKindAction;
import 'package:goodshare/ui/composer_doc.dart' show ComposerDoc;

// 段类型直设（问题#1 引导层·浮层选块）回归：setLineKindAction 纯函数 +
// ComposerDoc.setLineKind（单步撤销 + op-log + #2 IME 组合态守卫）。
void main() {
  // 确保活跃文本段 plain 已初始化为 [text]。
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

  group('setLineKindAction（纯函数）', () {
    test('正文→H1：行首写入 `# `', () {
      final r = setLineKindAction('灵感', 2, LineKindTarget.h1)!;
      expect(r.text, '# 灵感');
      expect(r.caret, 4);
    });

    test('H1→正文：剥离 `# ` 回正文', () {
      final r = setLineKindAction('# 灵感', 4, LineKindTarget.plain)!;
      expect(r.text, '灵感');
    });

    test('无序→H2：`- ` 替换为 `## `', () {
      final r = setLineKindAction('- 苹果', 4, LineKindTarget.h2)!;
      expect(r.text, '## 苹果');
    });

    test('已为 H1→H1：无变化返回 null（不搅动 undo）', () {
      expect(setLineKindAction('# 灵感', 4, LineKindTarget.h1), isNull);
    });

    test('正文→引用：行首写入 `> `', () {
      final r = setLineKindAction('金句', 2, LineKindTarget.quote)!;
      expect(r.text, '> 金句');
    });
  });

  group('ComposerDoc.setLineKind（引擎 + 守卫）', () {
    test('正文→H1：前缀写入 + 单步撤销可还原', () {
      final doc = _seed('灵感');
      final seg = doc.activeText!;
      doc.setLineKind(seg, LineKindTarget.h1);
      doc.consumeOutcome();
      expect(seg.spans.plain, '# 灵感');
      expect(doc.canUndo, isTrue);
      doc.undo();
      doc.consumeOutcome();
      expect(doc.activeText!.spans.plain, '灵感');
      doc.disposeAll();
    });

    test('无序→H2：类型转换生效', () {
      final doc = _seed('- 苹果');
      final seg = doc.activeText!;
      doc.setLineKind(seg, LineKindTarget.h2);
      doc.consumeOutcome();
      expect(seg.spans.plain, '## 苹果');
      doc.disposeAll();
    });

    test('已为目标类型：纯函数返回 null → 引擎不记撤销步', () {
      final doc = _seed('# 灵感');
      final seg = doc.activeText!;
      doc.setLineKind(seg, LineKindTarget.h1); // 无变化
      doc.consumeOutcome();
      expect(seg.spans.plain, '# 灵感');
      expect(doc.canUndo, isFalse); // 不应凭空多一步撤销
      doc.disposeAll();
    });

    test('#2 IME 组合态点击选块：强制落地不吞字不崩', () {
      final doc = _seed('nihao');
      final seg = doc.activeText!;
      // 模拟拼音组合态：text 已是 'nihao'，composing 覆盖整段（下划线未上屏）
      seg.ctrl.value = const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      doc.setLineKind(seg, LineKindTarget.h1);
      doc.consumeOutcome();
      // 组合区字符保留、前缀写入、composing 已清（不再有下划线/崩溃）
      expect(seg.spans.plain, '# nihao');
      expect(seg.ctrl.value.composing, TextRange.empty);
      doc.disposeAll();
    });

    test('#2 守卫对普通打字链路零干扰（非组合态空操作）', () {
      final doc = _seed('hello');
      final seg = doc.activeText!;
      // 非组合态：选区塌缩、composing 空
      seg.ctrl.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 5),
      );
      doc.setLineKind(seg, LineKindTarget.bullet);
      doc.consumeOutcome();
      expect(seg.spans.plain, '- hello');
      expect(seg.ctrl.value.composing, TextRange.empty);
      doc.disposeAll();
    });
  });
}
