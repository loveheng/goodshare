import 'package:flutter_test/flutter_test.dart';

import 'package:rich_text/markdown_subset.dart' show SpanListKind;
import 'package:goodshare/share/quick_note_line_shape.dart';
import 'package:goodshare/share/quick_note_reveal.dart';

/// S1 显隐机制单测（note-editor-source-of-truth.md §3.3 场景表逐条覆盖）。
///
/// 判据（§3.1）：光标在行内 ∧（标记区后无正文 ∨ 光标 ≤ 标记区末端）∧ 非冻结。
void main() {
  group('§3.1 判据单元（revealLine）', () {
    test('行尾正常打字：不显（全文 WYSIWYG）', () {
      final shape = parseLine('- 甲');
      expect(
        revealLine(
          shape: shape, lineLength: 3, lineLocalCaret: 3, frozen: false,
        ),
        isFalse,
        reason: '光标在正文末尾（> markerEnd=2）→ 隐藏',
      );
    });

    test('光标走到行首/标记区内：显', () {
      final shape = parseLine('- 甲');
      for (final c in [0, 1, 2]) {
        expect(
          revealLine(
            shape: shape, lineLength: 3, lineLocalCaret: c, frozen: false,
          ),
          isTrue,
          reason: 'caret=$c ≤ markerEnd=2 → 显',
        );
      }
    });

    test('空列表项行：恒显（防不可见陷阱）', () {
      final shape = parseLine('- ');
      expect(
        revealLine(
          shape: shape, lineLength: 2, lineLocalCaret: 2, frozen: false,
        ),
        isTrue,
        reason: '标记区后无正文 → 恒显',
      );
    });

    test('纯文本行：恒不显（无标记可显，无变化即无闪烁）', () {
      final shape = parseLine('甲乙丙');
      expect(
        revealLine(
          shape: shape, lineLength: 3, lineLocalCaret: 0, frozen: false,
        ),
        isFalse,
      );
    });

    test('标题行同口径：行首/标记区内显、正文不显', () {
      final shape = parseLine('# 甲');
      expect(
        revealLine(
          shape: shape, lineLength: 3, lineLocalCaret: 0, frozen: false,
        ),
        isTrue,
      );
      expect(
        revealLine(
          shape: shape, lineLength: 3, lineLocalCaret: 3, frozen: false,
        ),
        isFalse,
      );
    });

    test('越界 caret 防御：false', () {
      final shape = parseLine('- 甲');
      expect(
        revealLine(
          shape: shape, lineLength: 3, lineLocalCaret: 9, frozen: false,
        ),
        isFalse,
      );
    });
  });

  group('§3.3 场景表（revealAt 全文本口径）', () {
    const text = '- 甲\n- 乙\n- 丙\n'; // 三行列表 + 尾换行
    // 行偏移：第0行[0,3) 第1行[4,7) 第2行[8,11)，'\n' 在 3/7/11。

    test('场景：光标在第 N 行行尾打字 → 全程不显', () {
      for (final caret in [3, 7, 11]) {
        expect(
          revealAt(text, caret, frozen: false, heldValue: false),
          isFalse,
          reason: 'caret=$caret 行尾 → 不显',
        );
      }
    });

    test('场景：光标走到行首/标记区 → 显', () {
      for (final caret in [0, 1, 2, 4, 5, 6, 8, 9, 10]) {
        expect(
          revealAt(text, caret, frozen: false, heldValue: false),
          isTrue,
          reason: 'caret=$caret 在行首/标记区（含正文首字符处 ≤markerEnd）→ 显',
        );
      }
    });

    test('场景：回删并入上一行（光标落上一行正文末尾）→ 上一行不显', () {
      // 删掉第 0 行尾 '\n' 后光标在 3（第 0 行正文末尾）
      expect(
        revealAt('- 甲\n- 丙\n', 3, frozen: false, heldValue: false),
        isFalse,
        reason: '光标在第 0 行正文末尾 → 第 0 行不显（回删不露）',
      );
    });

    test('场景：一直退到上一行标记区 → 显（此时用户正要动它）', () {
      expect(
        revealAt('- 甲\n- 丙\n', 1, frozen: false, heldValue: false),
        isTrue,
      );
    });

    test('场景：空列表项行光标进入 → 显', () {
      expect(
        revealAt('- \n- 丙\n', 2, frozen: false, heldValue: false),
        isTrue,
      );
    });

    test('场景：连按退格穿越数行（冻结期）→ 沿用进入前状态，不闪', () {
      // 拖动/长按退格期间 freeze=true：谓词不求值，返回 heldValue。
      expect(
        revealAt(text, 1, frozen: true, heldValue: false),
        isFalse,
        reason: '冻结沿用进入前（隐藏）状态',
      );
      expect(
        revealAt(text, 1, frozen: true, heldValue: true),
        isTrue,
        reason: '冻结沿用进入前（显示）状态',
      );
    });

    test('场景：拖选跨行选中 → 冻结，抬手 settle 后按判据结算', () {
      final latch = RevealLatch();
      latch.freeze();
      expect(latch.frozen, isTrue);
      // 冻结期 heldValue 不变；抬手结算：光标在行尾 → false
      expect(latch.settle(revealAt(text, 3, frozen: false, heldValue: latch.heldValue)), isFalse);
      expect(latch.frozen, isFalse);
      // 再冻结 → 抬手结算：光标在行首 → true
      latch.freeze();
      expect(latch.settle(revealAt(text, 4, frozen: false, heldValue: latch.heldValue)), isTrue);
    });

    test('稳定态结算幂等：settle 复位后连续结算无残留', () {
      final latch = RevealLatch()..settle(true);
      expect(latch.heldValue, isTrue);
      expect(latch.settle(false), isFalse);
      expect(latch.heldValue, isFalse);
    });
  });

  group('纯函数性（契约 5）', () {
    test('同一 (文本, 光标) 两次求值一致', () {
      const t = '- 甲\n';
      final a = revealAt(t, 0, frozen: false, heldValue: false);
      final b = revealAt(t, 0, frozen: false, heldValue: false);
      expect(a, b);
    });

    test('markerEnd 与 LineShape 同源（判据消费单次解析）', () {
      // 判据的「标记区末端」必须来自 parseLine 原语（§4.6 禁第二条路径）。
      const line = '- [x] 甲';
      final shape = parseLine(line);
      expect(shape.listKind, SpanListKind.todo);
      // caret 在标记区内（≤ markerEnd）显、正文区不显
      expect(revealAt(line, shape.markerEnd, frozen: false, heldValue: false), isTrue);
      expect(revealAt(line, line.length, frozen: false, heldValue: false), isFalse);
    });
  });
}
