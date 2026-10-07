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

  group('列表/待办（2026-10-06）', () {
    test('无序列表与待办：剥前缀 → 无标记 plain + listRuns', () {
      final s = seedQuickNote('- 项目一\n- [ ] 待办\n- [x] 已完成');
      expect(s.plain, '项目一\n待办\n已完成');
      expect(s.listRuns.length, 3);
      expect(s.listRuns[0].kind, SpanListKind.bullet);
      expect(s.listRuns[0].done, false);
      expect(s.listRuns[1].kind, SpanListKind.todo);
      expect(s.listRuns[1].done, false);
      expect(s.listRuns[2].kind, SpanListKind.todo);
      expect(s.listRuns[2].done, true);
    });

    test('列表序列化回写 - / - [ ] / - [x]（往返幂等）', () {
      final s = seedQuickNote('- 项目一\n- [ ] 待办\n- [x] 已完成');
      expect(
        serializeQuickNoteSpans(s),
        '- 项目一\n- [ ] 待办\n- [x] 已完成',
      );
      final s2 = seedQuickNote(serializeQuickNoteSpans(s));
      expect(s2.plain, s.plain);
      expect(s2.listRuns.length, s.listRuns.length);
    });

    test('标题与列表互斥：# 行不认列表', () {
      final s = seedQuickNote('# 标题\n- 列表项');
      expect(s.plain, '标题\n列表项');
      expect(s.levelRuns.length, 1);
      expect(s.levelRuns.single.level, 1);
      expect(s.listRuns.length, 1);
      expect(s.listRuns.single.kind, SpanListKind.bullet);
    });

    test('列表行内标记仍解析（列表 + 行内共存）', () {
      final s = seedQuickNote('- **粗**项');
      expect(s.plain, '粗项');
      expect(s.listRuns.single.kind, SpanListKind.bullet);
      expect(s.runs.single.mark, InlineMark.bold);
      expect(s.runs.single.start, 0);
      expect(s.runs.single.end, 1); // 粗 = 单字（**粗** 铺 Mark 覆盖 [0,1)）
    });

    test('编辑列表行内文字：listRuns 随行重 snap 不错位', () {
      final s = seedQuickNote('- 项目一\n- 项目二');
      // 行首插 X（plain 无标记，作用于去前缀后的文本）
      applyQuickNoteSpansInput(s, 'X项目一\n项目二', active: {});
      expect(s.plain, 'X项目一\n项目二');
      expect(s.listRuns.length, 2);
      expect(s.listRuns[0].start, 0);
      expect(s.listRuns[1].start, s.plain.indexOf('项目二'));
    });

    test('insertSeededSpans：片段插入光标处并合并全维度', () {
      final target = seedQuickNote('开头\n');
      final frag = seedQuickNote('- 甲\n- [ ] 乙');
      insertSeededSpans(target, frag, target.plain.length); // 文末插入
      expect(target.plain, '开头\n甲\n乙');
      expect(target.listRuns.length, 2);
      expect(target.listRuns[0].kind, SpanListKind.bullet);
      expect(target.listRuns[1].kind, SpanListKind.todo);
    });

    test('多行列表项：续行并入前序 run 的 end（凹槽仅首行一次）', () {
      final s = seedQuickNote('- 项目一\n  续行一\n  续行二\n- 项目二');
      expect(s.plain, '项目一\n  续行一\n  续行二\n项目二');
      // 两个列表项 → 仅两个 run：续行**不**新建 run（否则凹槽重复出标记）
      expect(s.listRuns.length, 2);
      expect(s.listRuns[0].start, 0);
      // end 吞入两条续行，覆盖到末条续行行尾
      expect(s.listRuns[0].end, s.plain.indexOf('续行二') + '续行二'.length);
      expect(s.listRuns[1].start, s.plain.indexOf('项目二'));
    });

    test('多行列表项序列化：续行不加标记且保留 2 空格缩进', () {
      final s = seedQuickNote('- 项目一\n  续行一\n- 项目二');
      expect(serializeQuickNoteSpans(s), '- 项目一\n  续行一\n- 项目二');
    });

    test('多行列表项往返：serialize 产物被解析器解析回等价多行项', () {
      final s = seedQuickNote('- 项目一\n  续行一\n- 项目二');
      final blocks =
          const MarkdownSubsetParser().parse(serializeQuickNoteSpans(s));
      final list = blocks.single as ListBlock;
      expect(list.items.length, 2);
      expect(list.items[0].lines.length, 2); // 首行 + 续行
    });
  });

  group('行首列表标记落定 convertQuickNoteLineMarker（2026-10-07）', () {
    test('逐字打 `- 甲`：剥标记为 bullet run，返回需回退的偏移', () {
      final s = QuickNoteSpans(plain: '- 甲');
      final moved = convertQuickNoteLineMarker(s, caret: 3);
      expect(moved, 2); // '- ' 两字被剥，光标须同步回退 2
      expect(s.plain, '甲');
      expect(s.listRuns.length, 1);
      expect(s.listRuns.single.kind, SpanListKind.bullet);
      expect(s.listRuns.single.start, 0);
      expect(s.listRuns.single.end, 1);
    });

    test('裸待办 `[ ] 甲` → todo run（用户输入即可出勾选框）', () {
      final s = QuickNoteSpans(plain: '[ ] 甲');
      expect(convertQuickNoteLineMarker(s, caret: 5), 4);
      expect(s.plain, '甲');
      expect(s.listRuns.single.kind, SpanListKind.todo);
      expect(s.listRuns.single.done, false);
    });

    test('`[x] 甲` → todo run 且已勾选', () {
      final s = QuickNoteSpans(plain: '[x] 甲');
      expect(convertQuickNoteLineMarker(s, caret: 5), 4);
      expect(s.plain, '甲');
      expect(s.listRuns.single.kind, SpanListKind.todo);
      expect(s.listRuns.single.done, true);
    });

    test('非列表行不转换；已转换行幂等不重复剥', () {
      final s = QuickNoteSpans(plain: '普通文字');
      expect(convertQuickNoteLineMarker(s, caret: 4), 0);
      expect(s.plain, '普通文字');
      expect(s.listRuns, isEmpty);

      final t = QuickNoteSpans(plain: '- 甲');
      expect(convertQuickNoteLineMarker(t, caret: 3), 2);
      expect(convertQuickNoteLineMarker(t, caret: 1), 0); // 二次调用无副作用
      expect(t.plain, '甲');
      expect(t.listRuns.length, 1);
    });

    test('只有标记无内容：`- ` 落定为空列表项', () {
      final s = QuickNoteSpans(plain: '- ');
      expect(convertQuickNoteLineMarker(s, caret: 2), 2);
      expect(s.plain, '');
      expect(s.listRuns.single.start, 0);
      expect(s.listRuns.single.end, 0);
    });

    test('回归：空列表项敲第一个字，run 存活并贴合整行（不蒸发）', () {
      final s = QuickNoteSpans(plain: '- ');
      convertQuickNoteLineMarker(s, caret: 2);
      applyQuickNoteSpansInput(s, '甲', active: {});
      expect(s.plain, '甲');
      expect(s.listRuns.length, 1);
      expect(s.listRuns.single.kind, SpanListKind.bullet);
      expect(s.listRuns.single.start, 0);
      expect(s.listRuns.single.end, 1);
    });

    test('真实打字序列模拟：`-` → `- `（落定）→ `甲`', () {
      final s = QuickNoteSpans(plain: '');
      // 1) 打 `-`：标记未完整，不落定（否则会剥掉用户本想写的短横）
      applyQuickNoteSpansInput(s, '-', active: {});
      expect(convertQuickNoteLineMarker(s, caret: 1), 0);
      expect(s.plain, '-');
      // 2) 补空格：`- ` 落定为空列表项，所见即所得不再见标记
      applyQuickNoteSpansInput(s, '- ', active: {});
      expect(convertQuickNoteLineMarker(s, caret: 2), 2);
      expect(s.plain, '');
      expect(s.listRuns.single.kind, SpanListKind.bullet);
      // 3) 打正文：run 随行生长
      applyQuickNoteSpansInput(s, '甲', active: {});
      expect(convertQuickNoteLineMarker(s, caret: 1), 0);
      expect(s.plain, '甲');
      expect(s.listRuns.single.start, 0);
      expect(s.listRuns.single.end, 1);
    });

    test('多行上下文中落定第二行：前序 run 坐标不被挤压', () {
      final s = seedQuickNote('- 甲');
      applyQuickNoteSpansInput(s, '甲\n- 乙', active: {});
      expect(convertQuickNoteLineMarker(s, caret: 5), 2);
      expect(s.plain, '甲\n乙');
      expect(s.listRuns.length, 2);
      expect(s.listRuns[0].start, 0);
      expect(s.listRuns[0].end, 1);
      expect(s.listRuns[1].start, 2);
      expect(s.listRuns[1].end, 3);
    });

    test('落定后序列化回写带标记（- / - [ ] / - [x]）', () {
      final s = QuickNoteSpans(plain: '- 甲\n[ ] 乙\n[x] 丙');
      convertQuickNoteLineMarker(s, caret: 3);
      convertQuickNoteLineMarker(s, caret: 7); // 第二行行尾
      convertQuickNoteLineMarker(s, caret: 9); // 第三行行尾
      expect(s.plain, '甲\n乙\n丙');
      expect(serializeQuickNoteSpans(s), '- 甲\n- [ ] 乙\n- [x] 丙');
    });

    test('落定产物被解析器解析回等价列表（读写入口一致）', () {
      final s = QuickNoteSpans(plain: '[ ] 甲\n- 乙');
      convertQuickNoteLineMarker(s, caret: 5);
      convertQuickNoteLineMarker(s, caret: 5); // 第二行（落定后坐标已左移）
      final blocks =
          const MarkdownSubsetParser().parse(serializeQuickNoteSpans(s));
      final list = blocks.single as ListBlock;
      expect(list.items.length, 2);
      expect(list.items[0].done, false);
      expect(list.items[1].done, isNull);
    });
  });

  group('续行归并 extendQuickNoteContinuation（2026-10-07）', () {
    test('软换行后缩进续写：并入前序 run 的 end（不新建 run）', () {
      final s = seedQuickNote('- 甲');
      applyQuickNoteSpansInput(s, '甲\n  续行', active: {});
      extendQuickNoteContinuation(s, caret: s.plain.length);
      expect(s.plain, '甲\n  续行');
      expect(s.listRuns.length, 1); // 凹槽只画一次——绝不新建 run
      expect(s.listRuns.single.start, 0);
      expect(s.listRuns.single.end, s.plain.length);
    });

    test('续行序列化：不加 - 标记且保留 2 空格缩进', () {
      final s = seedQuickNote('- 甲');
      applyQuickNoteSpansInput(s, '甲\n  续行', active: {});
      extendQuickNoteContinuation(s, caret: s.plain.length);
      expect(serializeQuickNoteSpans(s), '- 甲\n  续行');
    });

    test('续行链：第二条续行继续并入同一 run', () {
      final s = seedQuickNote('- 甲');
      applyQuickNoteSpansInput(s, '甲\n  续一', active: {});
      extendQuickNoteContinuation(s, caret: s.plain.length);
      applyQuickNoteSpansInput(s, '甲\n  续一\n  续二', active: {});
      extendQuickNoteContinuation(s, caret: s.plain.length);
      expect(s.listRuns.length, 1);
      expect(s.listRuns.single.end, s.plain.length);
      expect(serializeQuickNoteSpans(s), '- 甲\n  续一\n  续二');
    });

    test('真实序列：列表项软换行后逐字续写（含中间无效态）', () {
      final s = seedQuickNote('- 甲');
      applyQuickNoteSpansInput(s, '甲\n', active: {}); // Shift+Enter
      extendQuickNoteContinuation(s, caret: 2);
      expect(s.listRuns.single.end, 1); // 空新行：不并
      applyQuickNoteSpansInput(s, '甲\n ', active: {});
      extendQuickNoteContinuation(s, caret: 3);
      expect(s.listRuns.single.end, 1); // 单空格 < 2：不并
      applyQuickNoteSpansInput(s, '甲\n  ', active: {});
      extendQuickNoteContinuation(s, caret: 4);
      expect(s.listRuns.single.end, 1); // 仅空白无内容：不并
      applyQuickNoteSpansInput(s, '甲\n  续', active: {});
      extendQuickNoteContinuation(s, caret: 5);
      expect(s.listRuns.length, 1);
      expect(s.listRuns.single.end, 5);
      expect(serializeQuickNoteSpans(s), '- 甲\n  续');
    });

    test('上一行不属列表：缩进行保持普通文本（不误并）', () {
      final s = QuickNoteSpans(plain: '普通\n  缩进');
      extendQuickNoteContinuation(s, caret: 6);
      expect(s.listRuns, isEmpty);
    });

    test('自身已是独立列表项：不被并入前一项', () {
      final s = QuickNoteSpans(
        plain: '甲\n  乙',
        listRuns: [
          const SpanListRun(0, 1, SpanListKind.bullet),
          const SpanListRun(2, 5, SpanListKind.bullet),
        ],
      );
      extendQuickNoteContinuation(s, caret: 5);
      expect(s.listRuns.length, 2);
      expect(s.listRuns[1].start, 2);
    });

    test('续行产物被解析器解析回等价多行项（读写入口一致）', () {
      final s = seedQuickNote('- 甲');
      applyQuickNoteSpansInput(s, '甲\n  续行\n- 乙', active: {});
      extendQuickNoteContinuation(s, caret: s.plain.indexOf('续行') + 2);
      final blocks =
          const MarkdownSubsetParser().parse(serializeQuickNoteSpans(s));
      final list = blocks.single as ListBlock;
      expect(list.items.length, 2);
      expect(list.items[0].lines.length, 2); // 首行 + 续行
      expect(list.items[1].lines.length, 1);
    });
  });

  group('有序列表（2026-10-07）', () {
    test('播种 `N. ` 与 `N) `：两形态同源（与解析器 _ordered 同一 grammar）', () {
      final s = seedQuickNote('1. 甲\n2. 乙');
      expect(s.plain, '甲\n乙');
      expect(s.listRuns.length, 2);
      expect(s.listRuns[0].kind, SpanListKind.ordered);
      expect(s.listRuns[1].kind, SpanListKind.ordered);

      final p = seedQuickNote('1) 甲');
      expect(p.plain, '甲');
      expect(p.listRuns.single.kind, SpanListKind.ordered);
    });

    test('序号不落正文：原数字 3/7 一律按连续组重排为 1/2', () {
      final s = seedQuickNote('3. 甲\n7. 乙');
      expect(s.plain, '甲\n乙', reason: '所见即所得：正文不见数字');
      expect(serializeQuickNoteSpans(s), '1. 甲\n2. 乙');
    });

    test('逐字打 `1. 甲`：落定为有序项', () {
      final s = QuickNoteSpans(plain: '1. 甲');
      expect(convertQuickNoteLineMarker(s, caret: 4), 3);
      expect(s.plain, '甲');
      expect(s.listRuns.single.kind, SpanListKind.ordered);
      expect(serializeQuickNoteSpans(s), '1. 甲');
    });

    test('序号按 **run** 推算：多项的续行不打断后续编号', () {
      final s = seedQuickNote('1. 甲\n  续行\n2. 乙');
      // 续行不产生 run → 第二个有序项必须仍是 2（按行算会退化成 1）
      expect(s.listRuns.length, 2);
      expect(quickNoteOrderedOrdinals(s.listRuns),
          {0: 1, s.plain.indexOf('乙'): 2});
      expect(serializeQuickNoteSpans(s), '1. 甲\n  续行\n2. 乙');
    });

    test('中间插入无序项 → 断组，之后的有序项重新从 1 编起', () {
      final s = seedQuickNote('1. 甲\n- 乙\n2. 丙');
      expect(serializeQuickNoteSpans(s), '1. 甲\n- 乙\n1. 丙');
    });

    test('有序 + 续行往返：被解析回有序 ListBlock（读写入口一致）', () {
      final s = seedQuickNote('1. 甲\n  续行\n2. 乙');
      final blocks =
          const MarkdownSubsetParser().parse(serializeQuickNoteSpans(s));
      final list = blocks.single as ListBlock;
      expect(list.ordered, isTrue);
      expect(list.items.length, 2);
      expect(list.items[0].lines.length, 2);
    });

    test('混合写法 `1. [ ] 甲`：勾选框优先（与详情页同判为待办项）', () {
      final s = seedQuickNote('1. [ ] 甲');
      expect(s.listRuns.single.kind, SpanListKind.todo);
    });
  });

  group('空行挂档回归', () {
    test('空行先挂档再敲首字：档位不丢（与其注释声明的意图一致）', () {
      final s = QuickNoteSpans(plain: '');
      setQuickNoteLevel(s, 1, caret: 0);
      expect(s.levelRuns.single.level, 1);

      applyQuickNoteSpansInput(s, '甲', active: {});
      expect(s.plain, '甲');
      expect(s.levelRuns.length, 1, reason: '此前敲首字即丢档');
      expect(s.levelRuns.single.start, 0);
      expect(s.levelRuns.single.end, 1);
      expect(serializeQuickNoteSpans(s), '# 甲');
    });

    test('整行被替换删空：档位仍消亡（空行规则不干扰既有语义）', () {
      final s = seedQuickNote('# 标题');
      applyQuickNoteSpansInput(s, '', active: {});
      expect(s.plain, isEmpty);
      expect(s.levelRuns, isEmpty);
    });
  });
}
