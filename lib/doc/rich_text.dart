/// 富文本模型与解析（Markdown 子集 → 块树）。
///
/// SSOT：docs/design/content-pipeline.md §3 / §5，docs/design/ui-spec.md §2.2。
///
/// 为什么要自建而不用 `flutter_markdown_plus`：
/// 1. **待办勾选在渲染器架构下无法实现**——渲染器输出不可交互文本流，而
///    `ui-spec` §7 要求 `human_md` 中 `[ ]` 可勾选、状态写 `todo_state_json`
/// 2. 该包是原包归档停更后的社区分叉
/// 3. 文档感全靠排版参数，受渲染器内部结构限制
///
/// 降级铁律：**宁可样式平，不可吞内容**——不认识的块一律降级为段落，
/// 绝不丢弃任何字符。

library;

// ---------- 行内 ----------

/// 行内节点。
sealed class InlineNode {
  const InlineNode();
}

/// 纯文本。
class InlineText extends InlineNode {
  const InlineText(this.text);

  final String text;
}

/// 粗体（`**` 或 `__`）。
class InlineStrong extends InlineNode {
  const InlineStrong(this.children);

  final List<InlineNode> children;
}

/// 斜体（`*` 或 `_`）。
class InlineEm extends InlineNode {
  const InlineEm(this.children);

  final List<InlineNode> children;
}

/// 行内代码。
class InlineCode extends InlineNode {
  const InlineCode(this.code);

  final String code;
}

/// 链接（`[文字](url)`）。**默认不可点击**（不引 `url_launcher`），
/// 仅以链接样式呈现。
class InlineLink extends InlineNode {
  const InlineLink({required this.label, required this.url});

  final String label;
  final String url;
}

// ---------- 块级 ----------

/// 块节点。
sealed class RichBlock {
  const RichBlock();
}

/// 标题（level 1-6）。
class HeadingBlock extends RichBlock {
  const HeadingBlock({required this.level, required this.inline});

  final int level;
  final List<InlineNode> inline;
}

/// 段落。
class ParagraphBlock extends RichBlock {
  const ParagraphBlock(this.inline);

  final List<InlineNode> inline;
}

/// 引用块（内部递归解析，支持引用内多段）。
class QuoteBlock extends RichBlock {
  const QuoteBlock(this.children);

  final List<RichBlock> children;
}

/// 列表项。`done` 非 null 表示这是待办项（可勾选）。
class ListItem {
  const ListItem(this.inline, {this.done});

  final List<InlineNode> inline;

  /// true = 已完成 `[x]`，false = 未完成 `[ ]`，null = 普通列表项。
  final bool? done;
}

/// 列表（有序 / 无序）。
class ListBlock extends RichBlock {
  const ListBlock({required this.ordered, required this.items});

  final bool ordered;
  final List<ListItem> items;
}

/// 代码块（围栏 ```）。
class CodeBlock extends RichBlock {
  const CodeBlock({required this.code, this.language});

  final String code;
  final String? language;
}

/// 分隔线。
class DividerBlock extends RichBlock {
  const DividerBlock();
}

/// 行内节点 → 纯文本（待办回调取文本、复制、检索预览用）。
///
/// 只取「人读到的字」，不含标记符号。
String inlineToPlain(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => text,
      InlineStrong(:final children) => inlineToPlain(children),
      InlineEm(:final children) => inlineToPlain(children),
      InlineCode(:final code) => code,
      InlineLink(:final label) => label,
    }).join();

/// 块 → 纯文本（预览 / 检索用）。
String blockToPlain(RichBlock block) => switch (block) {
      HeadingBlock(:final inline) => inlineToPlain(inline),
      ParagraphBlock(:final inline) => inlineToPlain(inline),
      QuoteBlock(:final children) => children.map(blockToPlain).join('\n'),
      ListBlock(:final items) => items.map((i) => inlineToPlain(i.inline)).join('\n'),
      CodeBlock(:final code) => code,
      DividerBlock() => '',
    };

// ---------- 解析 ----------

/// 富文本解析器接口。
abstract class RichTextParser {
  /// Markdown 子集 → 块树。永不抛异常，永不丢内容。
  List<RichBlock> parse(String markdown);

  /// 行内解析（供外部复用，如标题文案）。
  List<InlineNode> parseInline(String text);
}

/// Markdown 子集默认实现（纯函数，可单测）。
class MarkdownSubsetParser implements RichTextParser {
  const MarkdownSubsetParser();

  static final RegExp _fence = RegExp(r'^```(\w*)\s*$');
  static final RegExp _divider = RegExp(r'^\s*(?:---|\*\*\*|___)\s*$');
  static final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _quote = RegExp(r'^\s*>\s?');
  static final RegExp _bullet = RegExp(r'^\s*[-*+]\s+(.*)$');
  static final RegExp _ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$');

  /// 列表项里的待办标记：`[ ]` / `[x]`。
  static final RegExp _todo = RegExp(r'^\[([ xX])\]\s+(.*)$');

  @override
  List<RichBlock> parse(String markdown) =>
      _parseBlocks(markdown.replaceAll(RegExp(r'\r\n?'), '\n').split('\n'));

  List<RichBlock> _parseBlocks(List<String> lines) {
    final blocks = <RichBlock>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];

      // 代码块：围栏内原样保留，不解析行内
      final fence = _fence.firstMatch(line);
      if (fence != null) {
        final buf = <String>[];
        i++;
        while (i < lines.length && _fence.firstMatch(lines[i]) == null) {
          buf.add(lines[i]);
          i++;
        }
        i++; // 跳过闭合围栏（缺失时不抛，按到文末处理）
        final lang = fence.group(1)!;
        blocks.add(CodeBlock(code: buf.join('\n'), language: lang.isEmpty ? null : lang));
        continue;
      }

      if (_divider.hasMatch(line)) {
        blocks.add(const DividerBlock());
        i++;
        continue;
      }

      final heading = _heading.firstMatch(line);
      if (heading != null) {
        blocks.add(HeadingBlock(
          level: heading.group(1)!.length,
          inline: parseInline(heading.group(2)!),
        ));
        i++;
        continue;
      }

      if (_quote.hasMatch(line)) {
        final buf = <String>[];
        while (i < lines.length && _quote.hasMatch(lines[i])) {
          buf.add(lines[i].replaceFirst(_quote, ''));
          i++;
        }
        blocks.add(QuoteBlock(_parseBlocks(buf)));
        continue;
      }

      // 列表：连续的同类型项聚合为一个 ListBlock
      final bullet = _bullet.firstMatch(line);
      final ordered = _ordered.firstMatch(line);
      if (bullet != null || ordered != null) {
        final isOrdered = ordered != null;
        final items = <ListItem>[];
        while (i < lines.length) {
          final m = isOrdered
              ? (_ordered.firstMatch(lines[i]) ?? _bullet.firstMatch(lines[i]))
              : _bullet.firstMatch(lines[i]);
          if (m == null) break;
          items.add(_listItem(m.group(1)!));
          i++;
        }
        blocks.add(ListBlock(ordered: isOrdered, items: items));
        continue;
      }

      // 裸待办行（`[ ] xxx`，不在列表里）——归入单项无序列表，保证可勾选
      final bareTodo = RegExp(r'^\[([ xX])\]\s+(.*)$').firstMatch(line);
      if (bareTodo != null) {
        blocks.add(ListBlock(
          ordered: false,
          items: [_listItem(line)],
        ));
        i++;
        continue;
      }

      if (line.trim().isEmpty) {
        i++;
        continue;
      }

      // 段落：连续非空且非块起始的行
      final buf = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty && !_isBlockStart(lines[i])) {
        buf.add(lines[i]);
        i++;
      }
      if (buf.isEmpty) {
        i++; // 兜底防死循环
        continue;
      }
      blocks.add(ParagraphBlock(parseInline(buf.join('\n'))));
    }

    return blocks;
  }

  bool _isBlockStart(String line) =>
      _fence.hasMatch(line) ||
      _divider.hasMatch(line) ||
      _heading.hasMatch(line) ||
      _quote.hasMatch(line) ||
      _bullet.hasMatch(line) ||
      _ordered.hasMatch(line);

  ListItem _listItem(String content) {
    final todo = _todo.firstMatch(content);
    if (todo != null) {
      final mark = todo.group(1)!;
      return ListItem(parseInline(todo.group(2)!), done: mark != ' ');
    }
    return ListItem(parseInline(content));
  }

  /// 行内解析：粗体 / 斜体 / 行内码 / 链接，其余为纯文本。
  ///
  /// 匹配顺序即优先级：`**` 先于 `*`，避免 `**粗**` 被拆成两个斜体。
  @override
  List<InlineNode> parseInline(String text) {
    if (text.isEmpty) return const <InlineNode>[];

    final pattern = RegExp(
      r'(\*\*|__)(.+?)\1' // 1,2 粗体
      r'|(\*|_)(.+?)\3' // 3,4 斜体
      r'|`([^`]+)`' // 5 行内码
      r'|\[([^\]]*)\]\(([^)]*)\)', // 6,7 链接
      dotAll: true,
    );

    final out = <InlineNode>[];
    var pos = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > pos) {
        out.add(InlineText(text.substring(pos, m.start)));
      }
      if (m.group(2) != null) {
        out.add(InlineStrong(parseInline(m.group(2)!)));
      } else if (m.group(4) != null) {
        out.add(InlineEm(parseInline(m.group(4)!)));
      } else if (m.group(5) != null) {
        out.add(InlineCode(m.group(5)!));
      } else if (m.group(6) != null) {
        out.add(InlineLink(label: m.group(6)!, url: m.group(7) ?? ''));
      }
      pos = m.end;
    }
    if (pos < text.length) {
      out.add(InlineText(text.substring(pos)));
    }
    return out.isEmpty ? [InlineText(text)] : out;
  }
}
