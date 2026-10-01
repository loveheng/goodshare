import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../doc/rich_text.dart';
import 'audio_playback_service.dart';
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
/// 打磨项（rich-text-media 评估）：粘贴多段文本（单次变更插入 `\n\n`）按段界
/// 拆成多个段落块；激活块 IME 避让——不在视口内时滚至视口顶缘（键盘上方）。
/// 手敲回车逐事件只插入一个 `\n`，永不触发拆块（拆块仍是显式粘贴行为的后果，
/// 不做 md 块级语法自动检测——已驳回）。
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

  /// 页面级音频播放服务控制器（rich-text-media.md §4：编辑态音频预览可播、
  /// 走同一服务）。fullscreen dialog 的 context 不在页面 InheritedWidget
  /// 作用域内，由调用方显式透传；缺省时音频预览降级为静态卡。
  AudioPlaybackController? audioPlayback,
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
      audioPlayback: audioPlayback,
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
    this.audioPlayback,
  });

  final String markdown;
  final String title;
  final TextEditingController? titleField;
  final TextEditingController? tldrField;

  /// 每次块变更（编辑/排序/增删/勾选）回传当前全量 md（过程草稿同步）。
  final ValueChanged<String>? onChanged;

  final AudioPlaybackController? audioPlayback;

  @override
  State<_BlockEditorPage> createState() => _BlockEditorPageState();
}

class _BlockEditorPageState extends State<_BlockEditorPage> {
  final _parser = const MarkdownSubsetParser();
  late final List<_EdBlock> _blocks;
  int? _active; // 当前激活（编辑态）块下标，null = 无
  TextEditingController? _ctrl; // 激活块的编辑控制器
  bool _focusNew = false; // 新增块首帧抢焦点
  GlobalKey _activeKey = GlobalKey(); // 激活块定位锚（IME 避让 ensureVisible 用）
  String _prevText = ''; // 上一次编辑事件的文本（粘贴多段拆块的插入差量检测）
  double _lastBottomInset = 0; // 键盘高度跟踪（didChangeDependencies 差量触发避让）

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 键盘弹出/收起改变可视区高度，激活块可能被遮——重新避让
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset != _lastBottomInset) {
      _lastBottomInset = inset;
      _ensureActiveVisible();
    }
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
      _activeKey = GlobalKey();
      _ctrl = TextEditingController(text: blockEditText(_blocks[index].block));
      _prevText = _ctrl!.text;
    });
    _ensureActiveVisible();
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
    _prevText = '';
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
      _activeKey = GlobalKey();
      _ctrl = TextEditingController();
      _prevText = '';
    });
    _ensureActiveVisible();
    _notify();
  }

  void _append() {
    _commitActive();
    setState(() {
      _blocks.add(_EdBlock(const ParagraphBlock([])));
      _active = _blocks.length - 1;
      _focusNew = true;
      _activeKey = GlobalKey();
      _ctrl = TextEditingController();
      _prevText = '';
    });
    _ensureActiveVisible();
    _notify();
  }

  // ---------- 粘贴多段拆块 ----------

  /// 编辑事件入口：仅段落块做「粘贴多段拆块」检测。一次变更（= 一次粘贴，
  /// 含硬件 Ctrl+V / 输入法整段上屏）插入片段含 `\n\n` 才拆；手敲回车逐事件
  /// 只插入一个 `\n`，永不触发。
  void _onEdited(String text) {
    final prev = _prevText;
    _prevText = text;
    final i = _active;
    if (i == null || prev == text || _blocks[i].block is! ParagraphBlock) return;
    final span = _insertedSpan(prev, text);
    if (span == null || !span.inserted.contains('\n\n')) return;
    _splitActiveParagraph(i, text, span);
  }

  /// 本次变更的插入片段（公共前缀/后缀差量定位）；纯删除返回 null。
  /// 选中区被粘贴替换也覆盖（前缀/后缀天然吸收被替换文本）。
  ({int start, int end, String inserted})? _insertedSpan(String prev, String next) {
    final minLen = prev.length < next.length ? prev.length : next.length;
    var p = 0;
    while (p < minLen && prev.codeUnitAt(p) == next.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < minLen - p &&
        prev.codeUnitAt(prev.length - 1 - s) == next.codeUnitAt(next.length - 1 - s)) {
      s++;
    }
    final end = next.length - s;
    if (end <= p) return null;
    return (start: p, end: end, inserted: next.substring(p, end));
  }

  /// 段界拆分：粘贴片段按 `\n\n` 切段——首段并入当前块（并空则删块，对齐
  /// rebuildBlock 空块语义），中间段成新段块，末段+光标后原文成尾块并保持
  /// 激活（光标停在粘贴文本之后、原后文之前）；尾段为空则光标留在当前块末尾。
  void _splitActiveParagraph(
      int index, String text, ({int start, int end, String inserted}) span) {
    final segs = span.inserted.split('\n\n');
    if (segs.length < 2) return;
    final before = text.substring(0, span.start) + segs.first;
    final post = text.substring(span.end);
    final mids = segs.length > 2 ? segs.sublist(1, segs.length - 1) : const <String>[];
    final tail = segs.last + post;
    setState(() {
      var insertAt = index;
      if (before.trim().isEmpty) {
        _blocks.removeAt(index);
      } else {
        _blocks[index].block = ParagraphBlock(_parser.parseInline(before));
        insertAt = index + 1;
      }
      for (final m in mids) {
        if (m.trim().isEmpty) continue;
        _blocks.insert(insertAt++, _EdBlock(ParagraphBlock(_parser.parseInline(m))));
      }
      if (tail.trim().isNotEmpty) {
        _blocks.insert(insertAt, _EdBlock(ParagraphBlock(_parser.parseInline(tail))));
        _active = insertAt;
        _ctrl = TextEditingController(text: tail)
          ..selection = TextSelection.collapsed(
              offset: segs.last.length.clamp(0, tail.length));
        _prevText = tail;
      } else if (before.trim().isNotEmpty) {
        // 尾段为空（粘贴以空段收尾）：光标留在当前块末尾
        _active = index;
        final stayText = blockEditText(_blocks[index].block);
        _ctrl = TextEditingController(text: stayText)
          ..selection = TextSelection.collapsed(offset: stayText.length);
        _prevText = stayText;
      } else {
        // 拆分后当前块被清空且无尾段：退出编辑态（空块落库时自然删除）
        _active = null;
        _ctrl?.dispose();
        _ctrl = null;
        _prevText = '';
      }
      _activeKey = GlobalKey();
    });
    _ensureActiveVisible();
    _notify();
  }

  // ---------- IME 避让 ----------

  /// 激活块不在视口内时滚至视口顶缘（= 键盘弹起后仍在上半可见区）；
  /// 已完整可见时不滚动，避免激活时的无谓跳动。键盘高度变化由
  /// didChangeDependencies 差量触发重入。
  void _ensureActiveVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _active == null) return;
      final ctx = _activeKey.currentContext;
      final ro = ctx?.findRenderObject();
      final viewport = ro == null ? null : RenderAbstractViewport.maybeOf(ro);
      final scrollable = ctx == null ? null : Scrollable.maybeOf(ctx);
      if (ctx == null || ro == null || viewport == null || scrollable == null) return;
      final top =
          viewport.getOffsetToReveal(ro, 0.0).offset - scrollable.position.pixels;
      final fullyVisible =
          top >= 0 && top + ro.paintBounds.height <= scrollable.position.viewportDimension;
      if (fullyVisible) return;
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
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
      // 音频预览可播：透传的页面级播放控制器在 dialog 树内下发作用域
      body: widget.audioPlayback != null
          ? AudioPlaybackService(
              controller: widget.audioPlayback!,
              child: _blockList(),
            )
          : _blockList(),
    );
  }

  Widget _blockList() {
    return ListView.builder(
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
            key: bi == _active ? _activeKey : null,
            padding: EdgeInsets.only(top: bi == 0 ? Insets.md : 0, bottom: gapAfterBlock(_blocks[bi].block)),
            child: _blockItem(context, bi),
          );
        },
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
        field = TextField(controller: ctrl, minLines: 1, maxLines: 8, decoration: decoration, autofocus: _focusNew, onChanged: _onEdited);
      case CodeBlock(:final language):
        decoration = decoration.copyWith(labelText: language == null ? '代码' : '代码 · $language');
        field = TextField(
          controller: ctrl,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          minLines: 2,
          maxLines: 16,
          decoration: decoration,
          autofocus: _focusNew,
          onChanged: _onEdited,
        );
      case QuoteBlock():
        // 引用块 = 左侧竖线 + TextField（§4 块类型映射）
        field = Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(width: 4, color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.only(left: Insets.md),
          child: TextField(controller: ctrl, minLines: 1, maxLines: 16, decoration: decoration, autofocus: _focusNew, onChanged: _onEdited),
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
              child: TextField(controller: ctrl, minLines: 1, maxLines: 8, decoration: decoration, autofocus: _focusNew, onChanged: _onEdited),
            ),
          ],
        );
      case ListBlock():
        decoration = decoration.copyWith(
          labelText: block.ordered ? '列表（每行一项）' : '列表（每行一项，可用 - 开头）',
        );
        field = TextField(controller: ctrl, minLines: 2, maxLines: 16, decoration: decoration, autofocus: _focusNew, onChanged: _onEdited);
      case ImageBlock():
        decoration = decoration.copyWith(labelText: '图片说明（alt）');
        field = _mediaEditField(context, block, decoration);
      case AudioBlock():
        decoration = decoration.copyWith(labelText: '音频标签');
        field = _mediaEditField(context, block, decoration);
      case VideoBlock():
        decoration = decoration.copyWith(labelText: '视频标签');
        field = _mediaEditField(context, block, decoration);
      default: // ParagraphBlock / DividerBlock（分隔线无可编辑文本，仅可增删排序）
        field = TextField(controller: ctrl, minLines: 1, maxLines: 24, decoration: decoration, autofocus: _focusNew, onChanged: _onEdited);
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

  /// 媒体块编辑形态（rich-text-media.md §4）：本体预览 + alt/label 输入框。
  /// 预览与阅读态同源（buildRichBlock）；视频预览禁点播（编辑态不启播放），
  /// 音频预览走同一播放服务（controller 透传时）可播。
  Widget _mediaEditField(BuildContext context, RichBlock block, InputDecoration decoration) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IgnorePointer(
          ignoring: block is VideoBlock,
          child: Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: buildRichBlock(context, block),
          ),
        ),
        TextField(controller: _ctrl, minLines: 1, maxLines: 2, decoration: decoration, autofocus: _focusNew, onChanged: _onEdited),
      ],
    );
  }
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
      // 媒体块编辑的是 alt/label（url 不可改），rich-text-media.md §4
      ImageBlock(:final alt) => alt,
      AudioBlock(:final label) => label,
      VideoBlock(:final label) => label,
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
    // 媒体块：只改 alt/label，url 是内容本体——清空文本不删块（url 仍在）
    case ImageBlock(:final url):
      return ImageBlock(url: url, alt: editedText);
    case AudioBlock(:final url):
      return AudioBlock(url: url, label: editedText);
    case VideoBlock(:final url):
      return VideoBlock(url: url, label: editedText);
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
