import 'package:flutter_test/flutter_test.dart';
import 'package:rich_text/markdown_subset.dart';
import 'package:goodshare/share/quick_note_span_codec.dart';
import 'package:goodshare/share/quick_note_text_actions.dart'
    show deriveLineRuns, seedTextTruth, serializeTextTruthSpans;

/// 速记 codec 单测（纯 Dart，无 widget）：**只覆盖仍在服役的 codec 能力**
/// ——拆段合并 / 片段插入。
///
/// 旧模型已随 S3（2026-10-07）收口删除，测试同步下线：
/// | 旧 | 文本真相承接者 |
/// |---|---|
/// | `seedQuickNote`（剥线级标记） | `seedTextTruth`（线级标记留文本） |
/// | `serializeQuickNoteSpans` | `serializeTextTruthSpans` |
/// | `setQuickNoteLevel`（换坐标 run） | `setLineLevel`（行首写 `# ` 前缀） |
/// | `convertQuickNoteLineMarker`（打字落定） | `deriveLineRuns` 派生 |
/// | `extendQuickNoteContinuation`（续行归并） | `deriveLineRuns` 续行吞并 |
/// | `applyQuickNoteSpansInput`（坐标随动） | 编辑器 `_syncSegFromCtrl`（adjustRuns + 派生） |
///
/// 承接者的测试见 quick_note_text_actions_test.dart；派生视图的续行语义在
/// 那里补齐（本文件删掉的旧续行用例覆盖的是旧函数，不是派生逻辑）。
/// 注：InlineRun/SpanLevelRun 未定义 ==，断言一律按字段。
void main() {
  group('splitQuickNoteSpansAt / mergeQuickNoteSpansInto 拆段合并', () {
    test('媒体插入拆段：runs 截断两侧', () {
      final s = seedTextTruth('前面**粗**面\n后面');
      // seed 后 plain = `前面粗面\n后面`（前0面1粗2面3换行4后5面6），在 3 拆
      final (left, right) = splitQuickNoteSpansAt(s, 3);
      expect(left.plain, '前面粗');
      expect(right.plain, '面\n后面');
      expect(left.runs.single.start, 2);
      expect(left.runs.single.end, 3);
      expect(right.runs, isEmpty);
    });

    test('拆段 + 合并 = 无损往返（序列化字节相同）', () {
      final s = seedTextTruth('**AB**CD\n后面');
      final (left, right) = splitQuickNoteSpansAt(s, 3);
      mergeQuickNoteSpansInto(left, right);
      expect(left.plain, s.plain);
      expect(left.runs.length, s.runs.length);
      expect(left.runs.single.start, 0);
      expect(left.runs.single.end, 2);
      expect(serializeTextTruthSpans(left), serializeTextTruthSpans(s));
    });
  });

  group('insertSeededSpans 片段插入', () {
    test('片段插入光标处：线级标记随片段进文本，派生视图后出列表', () {
      final target = seedTextTruth('开头\n');
      final frag = seedTextTruth('- 甲\n- [ ] 乙');
      insertSeededSpans(target, frag, target.plain.length); // 文末插入
      expect(target.plain, '开头\n- 甲\n- [ ] 乙');
      // 行级身份由派生视图重算——调用方插入后必须 deriveLineRuns（编辑器
      // _insertSeededFragment 已接），insertSeededSpans 内的 adjust* 只挪不建。
      deriveLineRuns(target);
      expect(target.listRuns.length, 2);
      expect(target.listRuns[0].kind, SpanListKind.bullet);
      expect(target.listRuns[1].kind, SpanListKind.todo);
    });
  });
}
