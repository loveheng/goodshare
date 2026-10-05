import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/doc/rich_text.dart';
import 'package:goodshare/share/quick_note_span_codec.dart';

/// 速记所见即所得 codec 单测（纯 Dart，无 widget）：播种 / 随动 / 切换 /
/// 序列化 / 拆段合并。同源红线：serializeQuickNoteSpans 产物必须能被
/// MarkdownSubsetParser 解析回等价态（plain ≡ inlineToPlain(parse)）。
/// 注：InlineRun/SpanLevelRun 未定义 ==，断言一律按字段。
void main() {
  group('seedQuickNote 播种', () {
    test('旧 md 草稿剥行内标记 + 行首标题前缀 → 无标记态', () {
      final s = seedQuickNote('# 大标题\n**粗体**与*斜体*\n<u>下划</u>');
      expect(s.plain, '大标题\n粗体与斜体\n下划');
      expect(s.levelRuns.length, 1);
      expect(s.levelRuns.single.start, 0);
      expect(s.levelRuns.single.end, 3);
      expect(s.levelRuns.single.level, 1);
      final marks = [
        for (final r in s.runs) '${r.mark}:[${r.start},${r.end})',
      ];
      expect(marks, [
        'InlineMark.bold:[4,6)',
        'InlineMark.italic:[7,9)',
        'InlineMark.underline:[10,12)',
      ]);
    });

    test('标题档位 = # 个数（## → 2，### → 3 保留原档）', () {
      final s = seedQuickNote('## 二级\n### 三级');
      expect(s.plain, '二级\n三级');
      expect(s.levelRuns.map((r) => r.level).toList(), [2, 3]);
    });

    test('未闭合标记降级为字面（无标记态永不显示 md 残壳）', () {
      final s = seedQuickNote('abc**def');
      expect(s.plain, 'abc**def');
      expect(s.runs, isEmpty);
    });

    test('空串播种 = 空态', () {
      final s = seedQuickNote('');
      expect(s.plain, '');
      expect(s.runs, isEmpty);
      expect(s.levelRuns, isEmpty);
    });
  });

  group('标题档位', () {
    test('光标行档位读取（跨行不串扰）', () {
      final s = seedQuickNote('正文行\n## 标题行');
      expect(quickNoteLevelAt(s, 0), 0);
      expect(quickNoteLevelAt(s, 2), 0);
      expect(quickNoteLevelAt(s, 5), 2);
    });

    test('直设：1/2 挂档、0 回正文（非 toggle）', () {
      final s = seedQuickNote('你好\n世界');
      setQuickNoteLevel(s, 1, caret: 1);
      expect(s.levelRuns.length, 1);
      expect(s.levelRuns.single.start, 0);
      expect(s.levelRuns.single.end, 2);
      expect(s.levelRuns.single.level, 1);
      setQuickNoteLevel(s, 0, caret: 1);
      expect(s.levelRuns, isEmpty);
      setQuickNoteLevel(s, 2, caret: 5);
      expect(s.levelRuns.single.start, 3);
      expect(s.levelRuns.single.end, 5);
      expect(s.levelRuns.single.level, 2);
    });
  });

  group('输入随动 applyQuickNoteSpansInput', () {
    test('run 前纯插入：run 整体位移', () {
      final s = seedQuickNote('**CD**'); // bold[0,2)
      applyQuickNoteSpansInput(s, 'ABCD', active: {});
      expect(s.plain, 'ABCD');
      expect(s.runs.single.start, 2);
      expect(s.runs.single.end, 4);
    });

    test('run 内插入：run 延展（字级替换不打断样式连续性）', () {
      final s = seedQuickNote('**CD**');
      applyQuickNoteSpansInput(s, 'CXD', active: {});
      expect(s.plain, 'CXD');
      expect(s.runs.single.start, 0);
      expect(s.runs.single.end, 3);
    });

    test('激活 mark 落插入段（先选后打）', () {
      final s = seedQuickNote('');
      applyQuickNoteSpansInput(s, '加粗中', active: {InlineMark.bold});
      expect(s.runs.length, 1);
      expect(s.runs.single.start, 0);
      expect(s.runs.single.end, 3);
      expect(s.runs.single.mark, InlineMark.bold);
    });

    test('run 部分删除：run 收缩；整段删空：runs 清空', () {
      final s = seedQuickNote('**粗体**');
      applyQuickNoteSpansInput(s, '粗', active: {});
      expect(s.plain, '粗');
      expect(s.runs.single.start, 0);
      expect(s.runs.single.end, 1);

      final s2 = seedQuickNote('**粗体**');
      applyQuickNoteSpansInput(s2, '', active: {});
      expect(s2.plain, '');
      expect(s2.runs, isEmpty);
    });

    test('标题行中间回车：档位留前半行，新行回正文', () {
      final s = seedQuickNote('## 标题文字');
      applyQuickNoteSpansInput(s, '标题\n文字', active: {});
      expect(s.plain, '标题\n文字');
      expect(s.levelRuns.length, 1);
      expect(s.levelRuns.single.start, 0);
      expect(s.levelRuns.single.end, 2);
      expect(s.levelRuns.single.level, 2);
    });

    test('标题行行首回车：档位随原行下移', () {
      final s = seedQuickNote('## 标题');
      applyQuickNoteSpansInput(s, '\n标题', active: {});
      expect(s.plain, '\n标题');
      expect(s.levelRuns.length, 1);
      expect(s.levelRuns.single.start, 1);
      expect(s.levelRuns.single.end, 3);
      expect(s.levelRuns.single.level, 2);
    });

    test('前插文字：后续行档位随行位移', () {
      final s = seedQuickNote('第一行\n## 标题');
      applyQuickNoteSpansInput(s, 'X第一行\n标题', active: {});
      expect(s.plain, 'X第一行\n标题');
      expect(s.levelRuns.single.start, 5);
      expect(s.levelRuns.single.end, 7);
      expect(s.levelRuns.single.level, 2);
    });
  });

  group('serializeQuickNoteSpans 序列化', () {
    test('行首标题前缀 + 行内标记 → 标准 human_md', () {
      final s = seedQuickNote('# 大标题\n**粗体**与*斜体*\n普通行');
      expect(
        serializeQuickNoteSpans(s),
        '# 大标题\n**粗体**与*斜体*\n普通行',
      );
    });

    test('挂档空行不输出前缀（避免 `# ` 空壳）', () {
      final s = QuickNoteSpans(
        plain: '',
        levelRuns: const [SpanLevelRun(0, 0, 1)],
      );
      expect(serializeQuickNoteSpans(s), '');
    });

    test('字面语法字符序列化转义（往返不变形）', () {
      final s = seedQuickNote(r'a*b_c[d`e\f');
      expect(inlineSpansOf(serializeQuickNoteSpans(s)).plain, s.plain);
    });

    test('*** 按解析器同源语义 = 粗体+斜体双激活（bold+italic），往返 plain 守恒', () {
      final s = seedQuickNote('***粗斜***');
      // GFM 拍板（§3.3-3 / §5.2）：***x*** 处置为 bold+italic 双激活，非字面残壳；
      // 解析器同源——粗斜体分支插在粗体前（最长匹配优先）。plain 剥离定界符。
      expect(s.plain, '粗斜');
      // 粗+斜 双激活：同区间各一段 run（bold / italic）
      final marks = s.runs.map((r) => r.mark).toSet();
      expect(marks, {InlineMark.bold, InlineMark.italic});
      expect(inlineSpansOf(serializeQuickNoteSpans(s)).plain, s.plain);
    });
  });

  group('splitQuickNoteSpansAt / mergeQuickNoteSpansInto 拆段合并', () {
    test('媒体插入拆段：runs 截断两侧，档位留上侧', () {
      final s = seedQuickNote('## 前面**粗**面\n后面');
      // seed 后 plain = `前面粗面\n后面`（前0面1粗2面3换行4后5面6），在 3 拆
      final (left, right) = splitQuickNoteSpansAt(s, 3);
      expect(left.plain, '前面粗');
      expect(right.plain, '面\n后面');
      expect(left.runs.single.start, 2);
      expect(left.runs.single.end, 3);
      expect(right.runs, isEmpty);
      expect(left.levelRuns.single.start, 0);
      expect(left.levelRuns.single.end, 3);
      expect(left.levelRuns.single.level, 2);
      expect(right.levelRuns, isEmpty);
    });

    test('拆段 + 合并 = 无损往返', () {
      final s = seedQuickNote('**AB**CD\n## 标题');
      final (left, right) = splitQuickNoteSpansAt(s, 3);
      mergeQuickNoteSpansInto(left, right);
      expect(left.plain, s.plain);
      expect(left.runs.length, s.runs.length);
      expect(left.runs.single.start, 0);
      expect(left.runs.single.end, 2);
      expect(left.levelRuns.single.start, 5);
      expect(left.levelRuns.single.end, 7);
      expect(serializeQuickNoteSpans(left), serializeQuickNoteSpans(s));
    });
  });
}
