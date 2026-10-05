// DEPRECATED（2026-10-03 编辑器统一）：详情页编辑态已切换到统一作曲编辑器
// （lib/ui/note_composer_editor.dart + noteMdToDraftRows），本块模型不再被 UI 消费，
// 仅 MCP/机器态的历史契约与单测保留。清偿待办见 context/todos.md。
import 'rich_text.dart';

// ---------- 块 ↔ 编辑文本 映射（纯函数，可单测） ----------
//
// 2026-10-02 自 `lib/ui/block_editor_dialog.dart` 下沉至本层：这三个函数是
// **纯 Dart、零 Flutter 依赖**，却原先定义在 dialog 文件里，导致任何 UI 无关的
// 编辑状态（就地编辑的 EditSession）要么倒挂 import UI 层、要么形成循环依赖。
// 下沉后由块编辑器与就地编辑**共用同一份**映射，杜绝两套口径。

/// 块 → 编辑文本（预填）。
///
/// 一律走 serializeInline/serializeBlock（含字面转义）而非 blockToPlain：
/// 含行内样式的块若预填纯文本，保存经 serialize 会把 **粗体** 等样式静默压平
/// ——违反「数据无损防线」。serialize→parse 往返逐节点相等（往返单测保证），
/// 无样式的文本两者本就一致。列表多项预填含 `-`/`1.`/`[x]` 标记（列表符号
/// 是自然语言的一部分）。
String blockEditText(RichBlock block) => switch (block) {
      ParagraphBlock(:final inline) => serializeInline(inline),
      HeadingBlock(:final inline) => serializeInline(inline),
      QuoteBlock(:final children) => serializeBlocks(children),
      CodeBlock(:final code) => code,
      ListBlock() when block.items.length == 1 =>
        serializeInline(block.items.first.inline),
      ListBlock() => serializeBlock(block),
      DividerBlock() => '',
      // 媒体块编辑的是 alt/label（url 不可改），rich-text-media.md §4
      ImageBlock(:final alt) => alt,
      AudioBlock(:final label) => label,
      VideoBlock(:final label) => label,
      TableBlock() => serializeBlock(block),
    };

/// 编辑文本 → 新块（保存回写）。
///
/// 返回 null 表示块被清空应删除；行内结构经 parseInline 重解析——
/// 用户编辑期间打的 `**` 会成为粗体，原文里被转义的字面标记保持字面。
RichBlock? rebuildBlock(
  RichBlock original,
  String editedText, {
  bool? todoDone,
  RichTextParser parser = const MarkdownSubsetParser(),
}) {
  switch (original) {
    case ParagraphBlock():
      if (editedText.trim().isEmpty) return null;
      return ParagraphBlock(parser.parseInline(editedText));
    case HeadingBlock(:final level):
      if (editedText.trim().isEmpty) return null;
      return HeadingBlock(level: level, inline: parser.parseInline(editedText));
    case QuoteBlock():
      final inner = parser.parse(editedText);
      if (inner.isEmpty) return null;
      return QuoteBlock(inner);
    case CodeBlock(:final language):
      return CodeBlock(code: editedText, language: language);
    case ListBlock() when original.items.length == 1:
      final wasTodo = original.items.first.done != null;
      if (editedText.trim().isEmpty) return null;
      return ListBlock(
        ordered: original.ordered,
        items: [
          ListItem(
            parser.parseInline(editedText),
            done: wasTodo ? (todoDone ?? false) : null,
          ),
        ],
      );
    case ListBlock():
      return reparseList(editedText, original, parser);
    case DividerBlock():
      return original;
    // 媒体块：只改 alt/label，url 是内容本体——清空文本不删块（url 仍在）
    case ImageBlock(:final url):
      return ImageBlock(url: url, alt: editedText);
    case AudioBlock(:final url):
      return AudioBlock(url: url, label: editedText);
    case VideoBlock(:final url):
      return VideoBlock(url: url, label: editedText);
    case TableBlock():
      if (editedText.trim().isEmpty) return null;
      final parsed = parser.parse(editedText);
      return parsed.length == 1 && parsed.first is TableBlock
          ? parsed.first
          : ParagraphBlock(parser.parseInline(editedText));
  }
}

/// 多项列表回写：逐行剥 `-`/`N.`/`[x]` 标记重建条目；剥不掉的行按普通条目
/// 兜底（列表性质不因编辑丢失）。出现待办标记时列表归为无序。
///
/// 原为 dialog 私有 `_reparseList`，下沉后改公开（EditSession 与单测共用）。
ListBlock? reparseList(
  String editedText,
  ListBlock original,
  RichTextParser parser,
) {
  final items = <ListItem>[];
  var sawTodo = false;
  for (final line in editedText.split('\n')) {
    final l = line.trimRight();
    if (l.trim().isEmpty) continue;
    // 待办标记可在行首，也可在 `- `/`N.` 之后（serializeBlock 的待办行形式）
    final todo =
        RegExp(r'^\s*(?:[-*+]\s+|\d+[.)]\s+)?\[([ xX])\]\s+(.*)$').firstMatch(l);
    if (todo != null) {
      sawTodo = true;
      items.add(
          ListItem(parser.parseInline(todo.group(2)!), done: todo.group(1) != ' '));
      continue;
    }
    final bullet = RegExp(r'^\s*[-*+]\s+(.*)$').firstMatch(l);
    if (bullet != null) {
      items.add(ListItem(parser.parseInline(bullet.group(1)!)));
      continue;
    }
    final ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$').firstMatch(l);
    if (ordered != null) {
      items.add(ListItem(parser.parseInline(ordered.group(1)!)));
      continue;
    }
    items.add(ListItem(parser.parseInline(l)));
  }
  if (items.isEmpty) return null;
  return ListBlock(ordered: sawTodo ? false : original.ordered, items: items);
}

// ---------- 编辑会话（就地编辑与块编辑器的共同脊柱） ----------

/// 编辑态块稳定身份生成器（模块级自增，跨会话唯一）。
int _blockIdSeq = 0;
String _genBlockId() => 'eb${_blockIdSeq++}';

/// 编辑态块：[RichBlock] + 单项待办的可变勾选态。
///
/// 勾选态不进 md 序列化往返（`- [x]` 由 [rebuildBlock] 按 todoDone 重建），
/// 故单独挂在块外。
class EditBlock {
  EditBlock(this.block, {this.todoDone}) : id = _genBlockId();

  /// 编辑态稳定身份：ListView/Column 中 TextField/媒体组件的 [ValueKey]，
  /// 防结构变更（增删/移动/拆分）后 Element 错位复用；经文本改写/移动保持不变，
  /// 仅新建块（插入/拆分/追加）获新身份。
  final String id;

  RichBlock block;

  /// 仅当块是「单项待办」时非 null（true=已完成）。
  bool? todoDone;

  /// 样式化编辑层（block-format-input §4 slice-2）：段落/标题块的纯文本与
  /// 纯文本坐标 run（非 null = 该块走 span 编辑）。与 [block] 的 inline 树
  /// 恒同步（applySpanInput 同步重建），[markdown] 序列化出口不受影响。
  String? inlinePlain;
  List<InlineRun>? inlineRuns;
}

/// 编辑事务（undo 地基）：**所有块变更的唯一入口**，可记录、可回放。
///
/// 本期只落「可记录」的地基（事务日志），撤销/重做的 UI 入口延后——
/// 但变更必须已经全部走事务，否则将来补 undo 就是到处打补丁。
sealed class EditOp {
  const EditOp();
}

/// 移动块（delta 为 -1 上移 / +1 下移）。
final class MoveOp extends EditOp {
  const MoveOp(this.index, this.delta);

  final int index;
  final int delta;
}

/// 删除块。
final class DeleteOp extends EditOp {
  const DeleteOp(this.index);

  final int index;
}

/// 在 [index] 之后插入空段落块。
final class InsertAfterOp extends EditOp {
  const InsertAfterOp(this.index);

  final int index;
}

/// 末尾追加空段落块。
final class AppendOp extends EditOp {
  const AppendOp();
}

/// 把编辑文本写回块（[rebuildBlock] 返回 null 即删块）；[todoDone] 供单项待办。
final class CommitTextOp extends EditOp {
  const CommitTextOp(this.index, this.text, {this.todoDone});

  final int index;
  final String text;
  final bool? todoDone;
}

/// 粘贴拆块：把块 [index] 的整段编辑文本按空行（`\n\n`）切成多块。
///
/// - 段落/引用块：首段写回原块，其余段依次插入其后；
/// - 其它块（标题/媒体/列表）：不拆，原样提交整段文本（避免粘贴被吞）；
/// - 无空行则不拆。空段按 [rebuildBlock] 自然丢弃。
///
/// 经统一事务入口，记入 [EditSession.log]，与其它 EditOp 同源。
final class SplitOp extends EditOp {
  const SplitOp(this.index, this.fullText);

  final int index;
  final String fullText;
}

/// 替换媒体块源文件：仅改 [RichBlock] 的 url，保留 alt/label 与编辑态身份
/// （[EditBlock.id] 不变），使「替换媒体」与文字修改同属一份 [EditSession] 草稿、
/// 同走 [apply] 事务——取消即整体回滚（对应「独立 Command 绕过 Session」方案
/// 被否：会造成脏状态分裂，文字未保存而媒体已落库）。
final class ReplaceMediaOp extends EditOp {
  const ReplaceMediaOp(this.index, this.newUrl);

  final int index;
  final String newUrl;
}

/// 样式化输入提交（block-format-input §4 slice-2）：纯文本 + run 随动结果
/// 一次性落会话（[EditSession.applySpanInput] 组装），log 记账同源。
final class CommitSpansOp extends EditOp {
  const CommitSpansOp(this.index, this.text, this.runs);

  final int index;
  final String text;
  final List<InlineRun> runs;
}

/// 块级格式切换（block-format-input.md §2 拍板「先选后打」的块级部分）：
/// 段落 ↔ 标题互转，保留行内结构；[level] 0=正文、1/2=标题档。
/// 仅段落/标题可互转——媒体/列表/代码块不是格式目标（UI 层按钮对它们不触发）。
final class SetHeadingOp extends EditOp {
  const SetHeadingOp(this.index, this.level);

  final int index;
  final int level;
}

/// 编辑会话：持有可变块树，所有变更经 [apply] 事务入口，产出统一序列化出口。
///
/// **设计红线（就地编辑重构的地基）**：
/// - **不依赖任何 Flutter 控件**——无 TextEditingController / FocusNode /
///   GlobalKey，故可纯 Dart 单测，且能被块编辑器 dialog 与就地宿主同时消费；
/// - 焦点、IME 避让、TextEditingController 一律留在 UI 宿主侧，本类只管数据与事务；
/// - 变更**只能**经 [apply]——自动存草稿、脏标记、undo 全部挂在这一个点上，
///   避免「每种改动各补一次」的补丁式蔓延。
class EditSession {
  EditSession(String markdown)
      : _parser = const MarkdownSubsetParser(),
        blocks = const MarkdownSubsetParser()
            .parse(markdown)
            .map((b) => EditBlock(b, todoDone: _singleTodoDone(b)))
            .toList();

  final RichTextParser _parser;

  final List<EditBlock> blocks;

  /// 当前激活（正在编辑）的块下标；null = 无激活块。
  int? activeIndex;

  /// 事务日志（undo 地基）。
  final List<EditOp> log = [];

  /// 有未落库的变更（本期即「有过事务」；接草稿后由宿主导出）。
  bool get isDirty => log.isNotEmpty;

  /// 统一序列化出口（回写 humanMd 的唯一出口）。
  String get markdown => serializeBlocks(blocks.map((e) => e.block).toList());

  /// 单项待办的初始勾选态（仅「无序列表且恰好一项」才是可勾选待办）。
  static bool? _singleTodoDone(RichBlock b) => switch (b) {
        ListBlock(ordered: false, items: [ListItem(done: true)]) => true,
        ListBlock(ordered: false, items: [ListItem(done: false)]) => false,
        _ => null,
      };

  /// 事务入口：**所有块变更必经此处**。
  ///
  /// 越界操作静默忽略（防呆下沉在会话层，宿主不必各写一遍边界判断）。
  void apply(EditOp op) {
    switch (op) {
      case MoveOp(:final index, :final delta):
        final j = index + delta;
        if (index < 0 || index >= blocks.length || j < 0 || j >= blocks.length) {
          return;
        }
        final b = blocks.removeAt(index);
        blocks.insert(j, b);
      case DeleteOp(:final index):
        if (index < 0 || index >= blocks.length) return;
        blocks.removeAt(index);
      case InsertAfterOp(:final index):
        if (index < 0 || index >= blocks.length) return;
        blocks.insert(index + 1, EditBlock(const ParagraphBlock([])));
      case AppendOp():
        blocks.add(EditBlock(const ParagraphBlock([])));
      case CommitTextOp(:final index, :final text, :final todoDone):
        if (index < 0 || index >= blocks.length) return;
        final rebuilt =
            rebuildBlock(blocks[index].block, text, todoDone: todoDone);
        if (rebuilt == null) {
          blocks.removeAt(index);
        } else {
          blocks[index].block = rebuilt;
        }
      case SplitOp(:final index, :final fullText):
        if (index < 0 || index >= blocks.length) return;
        final original = blocks[index];
        final block = original.block;
        final normalized = fullText.replaceAll('\r\n', '\n');
        final segs = normalized.split(RegExp(r'\n[ \t]*\n'));
        final splittable = block is ParagraphBlock || block is QuoteBlock;
        if (!splittable || segs.length <= 1) {
          // 不拆：原样提交整段文本（标题/媒体/列表，或粘贴无空行）。
          final rebuilt =
              rebuildBlock(block, normalized, todoDone: original.todoDone);
          if (rebuilt != null) {
            final result = List<EditBlock>.from(blocks);
            result[index] = EditBlock(rebuilt, todoDone: original.todoDone);
            blocks
              ..clear()
              ..addAll(result);
          }
        } else {
          final result = List<EditBlock>.from(blocks);
          final firstRebuilt = rebuildBlock(block, segs.first.trim(),
              todoDone: original.todoDone);
          if (firstRebuilt != null) {
            result[index] = EditBlock(firstRebuilt, todoDone: original.todoDone);
          }
          for (var k = segs.length - 1; k >= 1; k--) {
            final rebuilt = rebuildBlock(block, segs[k].trim());
            if (rebuilt != null) result.insert(index + 1, EditBlock(rebuilt));
          }
          blocks
            ..clear()
            ..addAll(result);
        }
      case ReplaceMediaOp(:final index, :final newUrl):
        if (index < 0 || index >= blocks.length) return;
        final original = blocks[index];
        final block = original.block;
        final replaced = switch (block) {
          ImageBlock(:final alt) => ImageBlock(url: newUrl, alt: alt),
          AudioBlock(:final label) => AudioBlock(url: newUrl, label: label),
          VideoBlock(:final label) => VideoBlock(url: newUrl, label: label),
          _ => null,
        };
        if (replaced != null) blocks[index].block = replaced;
      case CommitSpansOp(:final index, :final text, :final runs):
        // 随动结果已由 applySpanInput 算好，这里只落块（事务记账在 apply 尾部）
        if (index < 0 || index >= blocks.length) return;
        final b = blocks[index];
        b.inlinePlain = text;
        b.inlineRuns = runs;
        final inline = inlineNodesOf(text, runs);
        final block = b.block;
        if (block is HeadingBlock) {
          b.block = HeadingBlock(level: block.level, inline: inline);
        } else if (block is ParagraphBlock) {
          b.block = ParagraphBlock(inline);
        }
      case SetHeadingOp(:final index, :final level):
        if (index < 0 || index >= blocks.length) return;
        final inline = switch (blocks[index].block) {
          ParagraphBlock(:final inline) => inline,
          HeadingBlock(:final inline) => inline,
          _ => null,
        };
        if (inline == null) return;
        blocks[index].block = level <= 0
            ? ParagraphBlock(inline)
            : HeadingBlock(level: level, inline: inline);
    }
    log.add(op);
  }

  /// 块 → 可编辑文本（激活块时预填编辑框）。
  String editTextOf(int index) =>
      index >= 0 && index < blocks.length ? blockEditText(blocks[index].block) : '';

  /// 段落/标题块播种为 span 编辑态（样式化编辑层 slice-2）：控制器文本换
  /// 纯文本（标记剥除），runs 由源 md 投影。非文本块不动（回落 md 编辑路径）。
  /// 播种不改 [markdown]——plain ≡ inlineToPlain（同源护栏单测锁定）。
  void seedSpanBlock(int index) {
    if (index < 0 || index >= blocks.length) return;
    final b = blocks[index];
    if (b.inlinePlain != null) return;
    final inline = switch (b.block) {
      ParagraphBlock(:final inline) => inline,
      HeadingBlock(:final inline) => inline,
      _ => null,
    };
    if (inline == null) return;
    final spans = inlineSpansOf(serializeInline(inline));
    b.inlinePlain = spans.plain;
    b.inlineRuns = spans.runs;
  }

  bool isSpanBlock(int index) =>
      index >= 0 &&
      index < blocks.length &&
      blocks[index].inlinePlain != null;

  /// span 块的编辑文本（= 纯文本；控制器事实源）。
  String spanEditTextOf(int index) {
    if (!isSpanBlock(index)) return editTextOf(index);
    return blocks[index].inlinePlain ?? '';
  }

  /// span 块回车拆段（slice-3）：光标前留在原块（标题档保持），光标后落入
  /// 新正文段落，runs 按区间分配到两侧。经事务 op 序列（CommitSpans +
  /// InsertAfter + CommitSpans），取消即整体回滚。
  void splitSpanBlock(int index, int offset) {
    if (index < 0 || index >= blocks.length) return;
    final b = blocks[index];
    final plain = b.inlinePlain;
    if (plain == null) return;
    final runs = b.inlineRuns ?? const <InlineRun>[];
    final before = plain.substring(0, offset);
    final after = plain.substring(offset);
    final leftRuns = [
      for (final r in runs)
        if (r.start < offset)
          InlineRun(r.start, r.end < offset ? r.end : offset, r.mark, url: r.url),
    ];
    final rightRuns = [
      for (final r in runs)
        if (r.end > offset)
          InlineRun(
            r.start > offset ? r.start - offset : 0,
            r.end - offset,
            r.mark,
            url: r.url,
          ),
    ];
    apply(CommitSpansOp(index, before, leftRuns));
    apply(InsertAfterOp(index));
    apply(CommitSpansOp(index + 1, after, rightRuns));
  }

  /// 样式化输入入口：文字变更 → run 随动（[adjustRuns]）→ 激活样式落 run
  /// → 同步重建 inline 树（[markdown] 出口恒一致）。[active] 为工具条的
  /// 行内格式激活态（先选后打拍板；收口时机由 UI 宿主管理）。
  void applySpanInput(int index, String newText,
      {required Set<InlineMark> active}) {
    if (index < 0 || index >= blocks.length) return;
    final b = blocks[index];
    final old = b.inlinePlain;
    if (old == null) return;
    final (start, oldEnd) = spanChangeRange(old, newText);
    // 插入长度 = 总长差 + 被删长度
    final insertLen = newText.length - old.length + (oldEnd - start);
    var runs = adjustRuns(b.inlineRuns ?? const [], start, oldEnd, insertLen);
    // 纯插入且有激活样式 → 插入段逐 mark 落 run（重叠模型允许叠加）
    final inserted = insertLen > 0;
    if (inserted) {
      for (final m in active) {
        runs.add(InlineRun(start, start + insertLen, m));
      }
    }
    apply(CommitSpansOp(index, newText, runs));
  }

  /// 行内解析（粘贴拆块等场景复用会话的解析器，保证与解析阶段同口径）。
  List<InlineNode> parseInline(String text) => _parser.parseInline(text);
}
