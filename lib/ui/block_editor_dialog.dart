import 'package:flutter/material.dart';

import '../doc/rich_text.dart';
import 'content_body.dart' show gapAfterBlock;
import 'rich_text_view.dart';
import 'tokens.dart';

/// 结构化块编辑器（fullscreen dialog）。
///
/// SSOT：docs/design/rich-text-component.md §4（批 B：替换源码编辑）。
/// 用户不写 Markdown 源码——块列表按块类型渲染编辑 widget（Tap-to-Edit：
/// 默认阅读态，点某块才激活为编辑态，全局同时至多一个），保存时经
/// [serializeBlocks] 回写 md 落库，AI 下游与 MCP 消费端零感知。
///
/// MVP 操作边界（§4 拍板）：Enter=块内换行不拆块；块首 Backspace 无事发生；
/// 排序走「上移/下移」按钮不做拖拽；新块只走「添加块」按钮。
///
/// 用法：
/// ```dart
/// final saved = await showBlockEditorDialog(context,
///     markdown: item.humanMd ?? '', onChanged: (md) { ... });
/// ```
Future<bool> showBlockEditorDialog(
  BuildContext context, {
  required String markdown,
  String title = '编辑内容',
  TextEditingController? titleField,
  TextEditingController? tldrField,
  ValueChanged<String>? onChanged,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    fullscreenDialog: true,
    builder: (_) => _BlockEditorPage(
      markdown: markdown,
      title: title,
      titleField: titleField,
      tldrField: tldrField,
      onChanged: onChanged,
    ),
  );
  return saved ?? false;
}

/// 编辑态条目（块 + 单项待办的可变勾选态）。
class _EdBlock {
  _EdBlock(this.block);

  RichBlock block;

  /// 单项待办的勾选态（仅 ListBlock 单条目且原 done 非 null 时使用）。
  bool? todoDone;
}

class _BlockEditorPage extends StatefulWidget {
  const _BlockEditorPage({
    required this.markdown,
    required this.title,
    this.titleField,
    this.tldrField,
    this.onChanged,
  });

  final String markdown;
  final String title;
  final TextEditingController? titleField;
  final TextEditingController? tldrField;

  /// 每次块变更（编辑/排序/增删/勾选）回传当前全量 md（过程草稿同步）。
  final ValueChanged<String>? onChanged;

  @override
  State<_BlockEditorPage> createState() => _BlockEditorPageState();
}

class _BlockEditorPageState extends State<_BlockEditorPage> {
  final _parser = const MarkdownSubsetParser();
  late final List<_EdBlock> _blocks;
  int? _active; // 当前激活（编辑态）块下标，null = 无
  TextEditingController? _ctrl; // 激活块的编辑控制器
  bool _focusNew = false; // 新增块首帧抢焦点

  @override
  void initState() {
    super.initState();
    _blocks = _parser
        .parse(widget.markdown)
        .map((b) => _EdBlock(b)..todoDone = _singleTodoDone(b))
        .toList();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  bool? _singleTodoDone(RichBlock b) => switch (b) {
        ListBlock(ordered: false, items: [ListItem(done: true)]) => true,
        ListBlock(ordered: false, items: [ListItem(done: false)]) => false,
        _ => null,
      };

  bool _isSingleTodo(_EdBlock e) => e.todoDone != null;

  /// 激活某块为编辑态（点击已激活块不重建控制器，防丢光标）。
  void _activate(int index) {
    if (_active == index) return;
    _commitActive();
    setState(() {
      _active = index;
      _ctrl = TextEditingController(text: blockEditText(_blocks[index].block));
    });
  }

  /// 失焦/切换/保存前：把编辑文本写回块。
  void _commitActive() {
    final i = _active;
    final ctrl = _ctrl;
    if (i == null || ctrl == null) return;
    final rebuilt = rebuildBlock(_blocks[i].block, ctrl.text, todoDone: _blocks[i].todoDone);
    setState(() {
      if (rebuilt == null) {
        _blocks.removeAt(i);
      } else {
        _blocks[i].block = rebuilt;
      }
      _active = null;
    });
    _ctrl?.dispose();
    _ctrl = null;
    _notify();
  }

  void _notify() =>
      widget.onChanged?.call(serializeBlocks(_blocks.map((e) => e.block).toList()));

  // ---------- 块操作 ----------

  void _move(int index, int delta) {
    final j = index + delta;
    if (j < 0 || j >= _blocks.length) return;
    _commitActive();
    setState(() {
      final b = _blocks.removeAt(index);
      _blocks.insert(j, b);
    });
    _notify();
  }

  void _delete(int index) {
    _commitActive();
    setState(() => _blocks.removeAt(index));
    _notify();
  }

  void _insertAfter(int index) {
    _commitActive();
    setState(() {
      _blocks.insert(index + 1, _EdBlock(const ParagraphBlock([])));
      _active = index + 1;
      _focusNew = true;
      _ctrl = TextEditingController();
    });
    _notify();
  }

  void _append() {
    _commitActive();
    setState(() {
      _blocks.add(_EdBlock(const ParagraphBlock([])));
      _active = _blocks.length - 1;
      _focusNew = true;
      _ctrl = TextEditingController();
    });
    _notify();
  }

  // ---------- 保存 ----------

  void _save() {
    _commitActive();
    Navigator.of(context).pop(true);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 新增块首帧抢焦点（弹软键盘）后复位，避免后续激活也抢焦点
    if (_focusNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _focusNew = false);
      });
    }
    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: () => Navigator.of(context).pop(false)),
        title: Text(widget.title),
        actions: [
          IconButton(icon: const Icon(Icons.check), tooltip: '保存', onPressed: _save),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(Insets.lg),
        itemCount: _blocks.length + 3, // 标题 + TL;DR + 块们 + 添加块
        itemBuilder: (context, i) {
          if (i == 0) {
            return TextField(
              controller: widget.titleField,
              decoration: const InputDecoration(labelText: '标题'),
            );
          }
          if (i == 1) {
            return Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: TextField(
                controller: widget.tldrField,
                decoration: const InputDecoration(labelText: 'TL;DR'),
              ),
            );
          }
          final bi = i - 2;
          if (bi == _blocks.length) {
            return Padding(
              padding: const EdgeInsets.only(top: Insets.md),
              child: OutlinedButton.icon(
                onPressed: _append,
                icon: const Icon(Icons.add),
                label: const Text('添加块'),
              ),
            );
          }
          return Padding(
            padding: EdgeInsets.only(top: bi == 0 ? Insets.md : 0, bottom: gapAfterBlock(_blocks[bi].block)),
            child: _blockItem(context, bi),
          );
        },
      ),
    );
  }

  Widget _blockItem(BuildContext context, int index) {
    final ed = _blocks[index];
    final active = _active == index;
    if (!active) {
      // 阅读态：与详情页同一呈现（buildRichBlock），点按激活编辑
      return InkWell(
        onTap: () => _activate(index),
        child: buildRichBlock(context, ed.block),
      );
    }
    return _editField(context, index, ed);
  }

  Widget _editField(BuildContext context, int index, _EdBlock ed) {
    final theme = Theme.of(context);
    final ctrl = _ctrl!;
    final block = ed.block;

    Widget field;
    InputDecoration decoration = const InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
    );

    switch (block) {
      case HeadingBlock(:final level):
        decoration = decoration.copyWith(labelText: '标题 $level');
        field = TextField(controller: ctrl, minLines: 1, maxLines: 8, decoration: decoration, autofocus: _focusNew);
      case CodeBlock(:final language):
        decoration = decoration.copyWith(labelText: language == null ? '代码' : '代码 · $language');
        field = TextField(
          controller: ctrl,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          minLines: 2,
          maxLines: 16,
          decoration: decoration,
          autofocus: _focusNew,
        );
      case QuoteBlock():
        // 引用块 = 左侧竖线 + TextField（§4 块类型映射）
        field = Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(width: 4, color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.only(left: Insets.md),
          child: TextField(controller: ctrl, minLines: 1, maxLines: 16, decoration: decoration, autofocus: _focusNew),
        );
      case ListBlock() when _isSingleTodo(ed):
        // 待办块 = Checkbox + TextField：改的是状态不是 `[ ]` 字符（§4）
        field = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Checkbox(
                value: ed.todoDone,
                onChanged: (v) => setState(() => ed.todoDone = v ?? false),
              ),
            ),
            Expanded(
              child: TextField(controller: ctrl, minLines: 1, maxLines: 8, decoration: decoration, autofocus: _focusNew),
            ),
          ],
        );
      case ListBlock():
        decoration = decoration.copyWith(
          labelText: block.ordered ? '列表（每行一项）' : '列表（每行一项，可用 - 开头）',
        );
        field = TextField(controller: ctrl, minLines: 2, maxLines: 16, decoration: decoration, autofocus: _focusNew);
      default: // ParagraphBlock / DividerBlock（分隔线无可编辑文本，仅可增删排序）
        field = TextField(controller: ctrl, minLines: 1, maxLines: 24, decoration: decoration, autofocus: _focusNew);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        const SizedBox(height: Insets.xs),
        // 块操作行：排序/删除/其后插入（MVP 按钮显式操作，§4）
        Row(
          children: [
            _iconBtn(Icons.keyboard_arrow_up, '上移', index > 0, () => _move(index, -1)),
            _iconBtn(Icons.keyboard_arrow_down, '下移', index < _blocks.length - 1, () => _move(index, 1)),
            _iconBtn(Icons.delete_outline, '删除块', true, () => _delete(index)),
            _iconBtn(Icons.playlist_add, '在其后添加块', true, () => _insertAfter(index)),
            const Spacer(),
            TextButton.icon(
              onPressed: _commitActive,
              icon: const Icon(Icons.done, size: 18),
              label: const Text('完成'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _iconBtn(IconData icon, String tip, bool enabled, VoidCallback onPressed) => IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tip,
        onPressed: enabled ? onPressed : null,
      );
}

// ---------- 块 ↔ 编辑文本 映射（纯函数，可单测） ----------

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
      ListBlock() when block.items.length == 1 => serializeInline(block.items.first.inline),
      ListBlock() => serializeBlock(block),
      DividerBlock() => '',
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
      return _reparseList(editedText, original, parser);
    case DividerBlock():
      return original;
  }
}

/// 多项列表回写：逐行剥 `-`/`N.`/`[x]` 标记重建条目；剥不掉的行按普通条目
/// 兜底（列表性质不因编辑丢失）。出现待办标记时列表归为无序。
ListBlock? _reparseList(String editedText, ListBlock original, RichTextParser parser) {
  final items = <ListItem>[];
  var sawTodo = false;
  for (final line in editedText.split('\n')) {
    final l = line.trimRight();
    if (l.trim().isEmpty) continue;
    // 待办标记可在行首，也可在 `- `/`N.` 之后（serializeBlock 的待办行形式）
    final todo = RegExp(r'^\s*(?:[-*+]\s+|\d+[.)]\s+)?\[([ xX])\]\s+(.*)$').firstMatch(l);
    if (todo != null) {
      sawTodo = true;
      items.add(ListItem(parser.parseInline(todo.group(2)!), done: todo.group(1) != ' '));
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
