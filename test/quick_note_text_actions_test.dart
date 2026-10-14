import 'package:flutter_test/flutter_test.dart';

import 'package:rich_text/markdown_subset.dart'
    show MarkdownSubsetParser, SpanListKind;
import 'package:goodshare/share/quick_note_reveal.dart' show revealAt;
import 'package:goodshare/share/quick_note_span_codec.dart'
    show quickNoteLineRangeAt, quickNoteListRunAt;
import 'package:goodshare/share/quick_note_text_actions.dart';

/// S2 文本真相动作与序列化单测（note-editor-source-of-truth.md §6 S2）。
///
/// 核心验收：往返恒等（md → seedTextTruth → 序列化 = 原文，有序组落盘规整）
/// + 行级动作纯函数（回车续标记 / 行首退格出列 / 勾选翻转）+ 派生视图语义。
void main() {
  group('enterWithMarker（回车续标记）', () {
    test('普通列表项行尾回车：新行同类型标记', () {
      final r = enterWithMarker('- 甲\n- 乙', 7)!;
      expect(r.text, '- 甲\n- 乙\n- ');
      expect(r.caret, r.text.length);
    });

    test('待办项回车：新项 `- [ ] `，勾选不继承', () {
      final r = enterWithMarker('- [x] 甲', 7)!;
      expect(r.text, '- [x] 甲\n- [ ] ');
    });

    test('有序项回车：新行字面序号 = 当前行 + 1', () {
      final r = enterWithMarker('3. 甲', 4)!;
      expect(r.text, '3. 甲\n4. ');
    });

    test('空列表项回车：退出列表（标记换成换行，新行正文）', () {
      final r = enterWithMarker('- \n- 乙', 2)!;
      expect(r.text, '\n\n- 乙');
      expect(r.caret, 0);
    });

    test('光标在标记区内回车：只插换行不续标记', () {
      final r = enterWithMarker('- 甲', 1)!;
      expect(r.text, '-\n 甲');
    });

    test('标题行回车：新行回正文（档位止于本行）', () {
      final r = enterWithMarker('# 甲', 3)!;
      expect(r.text, '# 甲\n');
    });

    test('纯文本行回车：只插换行', () {
      final r = enterWithMarker('甲乙', 2)!;
      expect(r.text, '甲乙\n');
    });
  });

  group('backspaceOutdent（行首退格出列）', () {
    test('列表行行首退格：删标记出列', () {
      // 行首 = '\n' 之后（index 2），非首字符处
      final r = backspaceOutdent('甲\n- 乙', 2)!;
      expect(r.text, '甲\n乙');
      expect(r.caret, 2);
    });

    test('标题行行首退格：删档位标记', () {
      final r = backspaceOutdent('x\n# 甲', 2)!;
      expect(r.text, 'x\n甲');
    });

    test('非行首退格：null（归既有路径）', () {
      expect(backspaceOutdent('- 甲', 3), isNull);
    });

    test('纯文本行行首退格：null', () {
      expect(backspaceOutdent('甲\n乙', 2), isNull);
    });

    test('文本首行行首退格（caret==0）：删标记出列', () {
      final r = backspaceOutdent('- 甲', 0)!;
      expect(r.text, '甲');
      expect(r.caret, 0);
    });

    test('caret==0 但首行是纯文本：null（首行无列可出）', () {
      expect(backspaceOutdent('甲\n- 乙', 0), isNull);
    });
  });

  group('toggleTodo（勾选翻转）', () {
    test('[ ] → [x]', () {
      final r = toggleTodo('- [ ] 甲', 0)!;
      expect(r.text, '- [x] 甲');
    });

    test('[x] → [ ]（大小写均归 [x] 翻转）', () {
      expect(toggleTodo('- [x] 甲', 0)!.text, '- [ ] 甲');
      expect(toggleTodo('- [X] 甲', 0)!.text, '- [ ] 甲');
    });

    test('裸勾选框行翻转', () {
      final r = toggleTodo('[ ] 甲', 0)!;
      expect(r.text, '[x] 甲');
    });

    test('非待办行：null', () {
      expect(toggleTodo('- 甲', 0), isNull);
      expect(toggleTodo('# 甲', 0), isNull);
    });
  });

  group('往返恒等（文本真相出口：seed → serialize 恒等 + 有序规整）', () {
    /// 往返：md → seedTextTruth → serializeTextTruthSpans。
    String roundTrip(String md) => serializeTextTruthSpans(seedTextTruth(md));

    test('恒等样本：播种后立即序列化 = 原文（新模型下恒等）', () {
      const samples = [
        '# 甲\n',
        '- 甲\n- 乙\n',
        '- [ ] 待办\n- [x] 已办\n',
        '1. 甲\n2. 乙\n',
        '正文行\n',
        '- 甲\n  续行\n',
      ];
      for (final md in samples) {
        expect(roundTrip(md), md, reason: 'seed→serialize 应恒等：$md');
      }
    });

    test('有序规整：出口按连续组重排字面序号', () {
      const md = '2. 甲\n3. 乙\n- 丙\n5. 丁\n';
      expect(roundTrip(md), '1. 甲\n2. 乙\n- 丙\n1. 丁\n');
      expect(
        normalizeOrderedNumbers(md),
        '1. 甲\n2. 乙\n- 丙\n1. 丁\n',
      );
    });

    test('动作产出经往返无损（落盘口径）', () {
      final acted = enterWithMarker('- 甲\n- 乙', 7)!.text;
      expect(roundTrip('$acted丙'), '- 甲\n- 乙\n- 丙');

      final todo = enterWithMarker('- [x] 甲', 7)!.text;
      expect(roundTrip('$todo丙'), '- [x] 甲\n- [ ] 丙');
      final outdent = backspaceOutdent('x\n- 乙', 2)!.text;
      expect(roundTrip(outdent), 'x\n乙');

      final toggled = toggleTodo('- [ ] 甲', 0)!.text;
      expect(roundTrip(toggled), '- [x] 甲');
    });
  });

  group('S3 文本真相三件套（seedTextTruth/deriveLineRuns/serializeTextTruthSpans）', () {
    group('派生视图（deriveLineRuns 语义与几何）', () {
      test('语义序列与行边界贴合', () {
        final s = seedTextTruth('# 甲\n正文\n- 乙\n  续\n- [x] 丙\n2. 丁\n');
        expect(s.levelRuns.map((r) => r.level), [1]);
        expect(s.listRuns.map((r) => (r.kind, r.done)), [
          (SpanListKind.bullet, false),
          (SpanListKind.todo, true),
          (SpanListKind.ordered, false),
        ]);
        // 几何：每个派生 run 贴合含标记 plain 的某一行边界（start = 行首）
        final starts = <int>{};
        var pos = 0;
        for (final l in s.plain.split('\n')) {
          starts.add(pos);
          pos += l.length + 1;
        }
        for (final r in s.levelRuns) {
          expect(starts.contains(r.start), isTrue, reason: 'level ${r.level}');
        }
        for (final r in s.listRuns) {
          expect(starts.contains(r.start), isTrue, reason: 'list ${r.kind}');
        }
      });

      test('续行吞并：多行项的续行并入宿主 run 的 end（不新建 run）', () {
        // 续行（≥2 空格缩进）绝不能新建 run——凹槽按 run 计数并在 run 首行
        // 绘制，新建会让续行重复出圆点/勾选框。旧 extendQuickNoteContinuation
        // 的职责由派生视图承接，本例即其回归（旧用例随旧函数一并下线）。
        final s = seedTextTruth('- 甲\n  续\n- 乙\n');
        expect(s.listRuns.length, 2, reason: '续行不新建 run');
        expect(s.listRuns[0].kind, SpanListKind.bullet);
        expect(s.listRuns[0].end, 7, reason: 'bullet end 吞入续行行尾');
        expect(s.listRuns[1].start, 8, reason: '第二项独立成 run');
      });

      test('seed 后 plain = 原文剥行内标记、保留线级标记', () {
        expect(seedTextTruth('- **甲**\n# 乙').plain, '- 甲\n# 乙');
      });
    });

    group('序列化出口（恒等 + 有序规整）', () {
      test('存量草稿样本：线级标记原样保留，有序组落盘规整', () {
        const cases = [
          ('# 甲\n正文 **粗**\n', '# 甲\n正文 **粗**\n'),
          ('- 甲\n- 乙\n', '- 甲\n- 乙\n'),
          ('- [ ] 待办\n- [x] 已办\n', '- [ ] 待办\n- [x] 已办\n'),
          ('1. 甲\n2. 乙\n- 丙\n5. 丁\n', '1. 甲\n2. 乙\n- 丙\n1. 丁\n'),
          ('- 甲\n  续行\n2. 乙\n', '- 甲\n  续行\n1. 乙\n'),
          ('普通行\n', '普通行\n'),
        ];
        for (final (md, expected) in cases) {
          expect(
            serializeTextTruthSpans(seedTextTruth(md)),
            expected,
            reason: md,
          );
        }
      });

      test('行内样式：粗体 run 在含标记文本上往返不变形', () {
        final s = seedTextTruth('- **甲乙**\n');
        expect(serializeTextTruthSpans(s), '- **甲乙**\n');
      });
    });
  });

  group('S4 引用/围栏（parseLine kind + deriveLineRuns 围栏状态机）', () {
    group('deriveLineRuns 围栏区域', () {
      test('开栏到合栏：整段区域含两道围栏行', () {
        final s = seedTextTruth('正文\n```dart\nint x = 1;\n```\n尾行');
        expect(s.codeRuns.length, 1);
        // 区域 = 开栏行首（3）到合栏行尾（不含最后换行）
        expect(s.codeRuns.single.start, 3);
        expect(s.codeRuns.single.end, '正文\n```dart\nint x = 1;\n```'.length);
      });

      test('未合栏：区域延伸到文本末（与解析器同口径）', () {
        final s = seedTextTruth('```\ncode line');
        expect(s.codeRuns.single.start, 0);
        expect(s.codeRuns.single.end, '```\ncode line'.length);
      });

      test('栏内标题/列表标记不再认（代码语义优先）', () {
        final s = seedTextTruth('```\n# 不是标题\n- 不是列表\n```');
        expect(s.levelRuns, isEmpty);
        expect(s.listRuns, isEmpty);
        expect(s.codeRuns.length, 1);
      });

      test('多组围栏独立成区', () {
        final s = seedTextTruth('```\na\n```\n中\n```\nb\n```');
        expect(s.codeRuns.length, 2);
      });
    });

    group('与 MarkdownSubsetParser 往返一致（S4 验收 §6）', () {
      test('围栏样本：seedTextTruth→serializeTextTruthSpans→parse 结构等价', () {
        const samples = [
          '```\ncode\n```',
          '```dart\nint x;\n```',
          '正文\n> 引用行\n',
          '> 引用\n> 第二行\n',
        ];
        for (final md in samples) {
          final s = seedTextTruth(md);
          final out = serializeTextTruthSpans(s);
          // 恒等（文本真相：无行内标记时序列化=原文）
          expect(out, md, reason: '往返恒等失败：$md');
          // 与详情页 parser 结构一致：围栏/引用行数不丢
          final blocks = const MarkdownSubsetParser().parse(out);
          expect(blocks, isNotEmpty, reason: md);
        }
      });

      test('围栏内行内标记按字面保留（代码不解析行内——与解析器同语义）', () {
        final s = seedTextTruth('```\n**不是粗体**\n```');
        // runs 不应命中围栏内文本（inlineSpansOf 只作用于正文行——但围栏行
        // 的正文 `**不是粗体**` 仍会走 inlineSpansOf；S4 口径：派生 code 区域
        // 优先于行内样式渲染，序列化按字面往返）
        expect(s.codeRuns.length, 1);
        expect(serializeTextTruthSpans(s), '```\n**不是粗体**\n```');
      });
    });

    group('S4 显隐场景（revealAt 消费新 kind）', () {
      test('引用行光标在标记区：显 `> `，正文区不显', () {
        expect(revealAt('> 甲', 0, frozen: false, heldValue: false), isTrue);
        expect(revealAt('> 甲', 2, frozen: false, heldValue: false), isTrue);
        expect(revealAt('> 甲', 3, frozen: false, heldValue: false), isFalse);
      });

      test('围栏行（```）标记区判据：caret ≤ markerEnd 显', () {
        expect(revealAt('```dart', 0, frozen: false, heldValue: false), isTrue);
        expect(revealAt('```dart', 7, frozen: false, heldValue: false), isTrue);
        // 围栏行长度=7，行内无正文区
      });

      test('空引用行（> 后无正文）恒显（防不可见陷阱）', () {
        expect(revealAt('>', 1, frozen: false, heldValue: false), isTrue);
        expect(revealAt('> ', 2, frozen: false, heldValue: false), isTrue);
      });
    });
  });

  group('planTextEdit 判据矩阵（_onSegChanged 路径分流）', () {
    /// 与编辑器 `_isListLineAt` 同口径：变更窗起点所在行是否为**列表首行**
    ///（续行被吞入既有 run，行首查不到 run 故返回 false）。
    bool isListLineAt(String plain, int caret) {
      final s = seedTextTruth(plain);
      final line = quickNoteLineRangeAt(s, caret);
      return line != null && quickNoteListRunAt(s, line.$1) != null;
    }

    TextEditKind kindOf(String old, String neu, {bool composing = false}) =>
        planTextEdit(
          oldPlain: old,
          newText: neu,
          composing: composing,
          isListLineAt: (at) => isListLineAt(old, at),
        ).kind;

    test('表驱动：old→new × 组合期 → 处置类别', () {
      const cases = [
        // (old, new, composing, kind, 说明)
        ('甲', '甲乙', false, TextEditKind.inline, '普通输入'),
        ('甲', '甲', false, TextEditKind.inline, '无变更'),
        ('甲乙', '甲', false, TextEditKind.inline, '删除'),
        ('甲', '甲\n', false, TextEditKind.splitLines, '非列表行回车→拆段物化'),
        ('甲', '甲\n乙\n丙', false, TextEditKind.splitLines, '多行粘贴'),
        ('- 甲', '- 甲\n', false, TextEditKind.listEnter, '列表行回车→就地起新项'),
        ('- 甲', '- 甲\n', true, TextEditKind.splitLines, '组合期不打断 IME'),
        ('- 甲', '- 甲\n乙', false, TextEditKind.splitLines, '插入不止单个 \\n'),
      ];
      for (final (old, neu, composing, kind, why) in cases) {
        expect(
          kindOf(old, neu, composing: composing),
          kind,
          reason: '$why（${old.replaceAll('\n', r'\n')} → '
              '${neu.replaceAll('\n', r'\n')}）',
        );
      }
    });

    test('有序 / 待办行同样走列表回车（不只 bullet）', () {
      for (final md in ['1. 甲', '- [ ] 甲', '- [x] 甲']) {
        expect(kindOf(md, '$md\n'), TextEditKind.listEnter, reason: md);
      }
    });

    test('续行（缩进）不是列表首行 → 回车走拆段', () {
      const old = '- 甲\n  续';
      expect(kindOf(old, '$old\n'), TextEditKind.splitLines);
    });

    test('plan 携带变更窗起点与插入文本（拆段定位用）', () {
      final plan = planTextEdit(
        oldPlain: '甲',
        newText: '甲\n乙',
        composing: false,
        isListLineAt: (_) => false,
      );
      expect(plan.start, 1);
      expect(plan.inserted, '\n乙');
    });
  });

  group('normalizeOrderedNumbers 细节', () {
    test('断组归零：非列表行隔开两组各自从 1 起', () {
      expect(
        normalizeOrderedNumbers('3. 甲\n\n4. 乙'),
        '1. 甲\n\n1. 乙',
      );
    });

    test('缩进续行不断组', () {
      expect(
        normalizeOrderedNumbers('1. 甲\n  续\n2. 乙'),
        '1. 甲\n  续\n2. 乙',
      );
    });

    test('`)` 分隔统一为 `.`（旧序列化恒输出 `N. `）', () {
      expect(normalizeOrderedNumbers('1) 甲'), '1. 甲');
    });
  });

  group('renumberOrderedGroup（B 专项·编辑期空洞序号）', () {
    /// 模拟 composer_doc 离散动作点：退格出列后立即重编号（与 _commitEnter /
    /// backspaceOutdentAt 的挂接点同口径）。
    (String, int) outdentThenRenumber(String text, int caret) {
      final r = backspaceOutdent(text, caret)!;
      return renumberOrderedGroup(r.text, r.caret);
    }

    test('删中间项：组内后续项重编号（与落盘断组语义一致）', () {
      final (t, _) = outdentThenRenumber('1. 甲\n2. 乙\n3. 丙', 5);
      expect(t, '1. 甲\n乙\n1. 丙');
    });

    test('删首项：后续整组重编号', () {
      final (t, _) = outdentThenRenumber('1. 甲\n2. 乙\n3. 丙', 0);
      expect(t, '甲\n1. 乙\n2. 丙');
    });

    test('删末项：前组已正确，不误改', () {
      final (t, c) = outdentThenRenumber('1. 甲\n2. 乙\n3. 丙', 10);
      expect(t, '1. 甲\n2. 乙\n丙');
      expect(c, 10); // 光标保持行首
    });

    test('顺序列表删除：重编号为恒等，光标不漂', () {
      final (t, c) = outdentThenRenumber('1. 甲\n2. 乙', 5);
      expect(t, '1. 甲\n乙');
      expect(c, 5);
    });

    test('bullet 列表出列不触发重编号（无有序组）', () {
      final (t, _) = outdentThenRenumber('- 甲\n- 乙', 0);
      expect(t, '甲\n- 乙');
    });

    test('跨位边界 9→10：删项后前缀变窄，组前光标不漂', () {
      // 删 "9. 乙" → 出列为纯文本 "乙"，后续 "10/11" 成新组重编 1/2
      // （与 normalizeOrderedNumbers 断组语义一致；非 9/10）
      const before = '8. 甲\n9. 乙\n10. 丙\n11. 丁';
      final (t, c) = outdentThenRenumber(before, 5);
      expect(t, '8. 甲\n乙\n1. 丙\n2. 丁');
      expect(c, 5);
    });

    test('嵌套组隔离：仅同缩进组重编号', () {
      final (t, _) = outdentThenRenumber('1. 甲\n  2. 乙\n  3. 丙', 5);
      expect(t, '1. 甲\n乙\n  1. 丙');
    });

    test('直接重编号：相邻空洞项愈合', () {
      final (t, _) = renumberOrderedGroup('1. 甲\n3. 丙', 0);
      expect(t, '1. 甲\n2. 丙');
    });
  });
}
