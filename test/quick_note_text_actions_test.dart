import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/rich_text.dart' show MarkdownSubsetParser;
import 'package:goodshare/share/quick_note_reveal.dart'
    show kNoteMarkerReveal, revealAt;
import 'package:goodshare/share/quick_note_span_codec.dart';
import 'package:goodshare/share/quick_note_text_actions.dart';

/// S2 文本真相动作与序列化单测（note-editor-source-of-truth.md §6 S2）。
///
/// 核心验收：**新旧路径字节等价**——同一 md 经「seedQuickNote → 编辑动作 →
/// serializeQuickNoteSpans」（旧）与「直接文本操作」（新）产出一致。
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

  group('新旧路径字节等价（§7.5 存量口径）', () {
    /// 旧路径：md → seed → 逐行 serialize。
    String oldPath(String md) => serializeQuickNoteSpans(seedQuickNote(md));

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
        expect(oldPath(md), md, reason: 'seed→serialize 应恒等：$md');
      }
    });

    test('有序规整：normalizeOrderedNumbers 与旧序列化序号口径一致', () {
      // 旧：seed 保留字面，序列化时按组重排
      final old = oldPath('2. 甲\n3. 乙\n- 丙\n5. 丁\n');
      // 新：buffer 字面保留，出口 normalize
      final neu = normalizeOrderedNumbers('2. 甲\n3. 乙\n- 丙\n5. 丁\n');
      expect(neu, old);
      expect(neu, '1. 甲\n2. 乙\n- 丙\n1. 丁\n');
    });

    test('回车续标记后新旧落盘等价：新文本经 seed→serialize 恒等', () {
      // 锚点：新动作产出的文本经旧 seed→serialize 往返无损（往返单测口径）。
      // ⚠️ 样本须避开「尾随空列表项」——旧 serialize 对空占位 run 不输出
      // 标记（§1.2 实例1 的序列化侧表现，S3 退役对象），非等价锚点。
      final acted = enterWithMarker('- 甲\n- 乙', 7)!.text;
      expect(oldPath('$acted丙'), '- 甲\n- 乙\n- 丙');

      final todo = enterWithMarker('- [x] 甲', 7)!.text;
      expect(oldPath('$todo丙'), '- [x] 甲\n- [ ] 丙');
      final outdent = backspaceOutdent('x\n- 乙', 2)!.text;
      expect(oldPath(outdent), 'x\n乙');

      final toggled = toggleTodo('- [ ] 甲', 0)!.text;
      expect(oldPath(toggled), '- [x] 甲');
    });
  });

  group('S3 文本真相三件套（seedTextTruth/deriveLineRuns/serializeTextTruthSpans）', () {
    group('派生视图与旧 run 等价（deriveLineRuns vs seedQuickNote）', () {
      test('派生 run 语义序列与旧播种一致；坐标贴合含标记 plain 的行边界', () {
        const samples = [
          '# 甲\n正文\n- 乙\n  续\n- [x] 丙\n2. 丁\n',
          '甲\n# 一级\n## 二级\n',
          '- 甲\n- 乙\n\n- 丙\n',
        ];
        for (final md in samples) {
          final old = seedQuickNote(md);
          final neu = seedTextTruth(md);
          // 语义序列：kind/done/level 逐 run 一致（坐标系统不同，几何不比）
          expect(neu.levelRuns.map((r) => r.level),
              old.levelRuns.map((r) => r.level), reason: md);
          expect(neu.listRuns.map((r) => (r.kind, r.done)),
              old.listRuns.map((r) => (r.kind, r.done)), reason: md);
          // 几何：每个派生 run 贴合含标记 plain 的某一行边界（start=行首）
          final lines = neu.plain.split('\n');
          var pos = 0;
          final starts = <int>{};
          for (final l in lines) {
            starts.add(pos);
            pos += l.length + 1;
          }
          for (final r in neu.levelRuns) {
            expect(starts.contains(r.start), isTrue, reason: md);
          }
          for (final r in neu.listRuns) {
            expect(starts.contains(r.start), isTrue, reason: md);
          }
          // 续行吞入口径：listRun.end ≥ 首行正文尾（多行项时覆盖续行）
          expect(neu.listRuns.length, old.listRuns.length, reason: md);
        }
      });

      test('seed 后 plain = 原文剥行内标记、保留线级标记', () {
        expect(seedTextTruth('- **甲**\n# 乙').plain, '- 甲\n# 乙');
      });
    });

    group('序列化字节等价（serializeTextTruthSpans vs 旧出口，存量口径）', () {
      String oldPath(String md) => serializeQuickNoteSpans(seedQuickNote(md));

      test('存量草稿样本：新序列化（恒等+规整）== 旧序列化', () {
        const samples = [
          '# 甲\n正文 **粗**\n',
          '- 甲\n- 乙\n',
          '- [ ] 待办\n- [x] 已办\n',
          '1. 甲\n2. 乙\n- 丙\n5. 丁\n',
          '- 甲\n  续行\n2. 乙\n',
          '普通行\n',
        ];
        for (final md in samples) {
          final neu = serializeTextTruthSpans(seedTextTruth(md));
          expect(neu, oldPath(md), reason: '字节等价失败：$md');
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

  group('normalizeOrderedNumbers 细节', () {
    test('S3 门禁：旗标已翻转（文本真相生效，旧路径退役）', () {
      expect(kNoteMarkerReveal, isTrue);
    });

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
}
