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

/// 行内图片块（整行 `![alt](url)`，SSOT：docs/design/rich-text-media.md §2）。
class ImageBlock extends RichBlock {
  const ImageBlock({required this.url, this.alt = ''});

  final String url;

  /// 图片说明（用户/AI 原话，规则层禁加类型前缀——往返幂等）。
  final String alt;
}

/// 行内音频块（整行 `[label](url)` 且 url 后缀命中音频白名单）。
class AudioBlock extends RichBlock {
  const AudioBlock({required this.url, this.label = ''});

  final String url;
  final String label;
}

/// 行内视频块（整行 `[label](url)` 且 url 后缀命中视频白名单）。
class VideoBlock extends RichBlock {
  const VideoBlock({required this.url, this.label = ''});

  final String url;
  final String label;
}

// ---------- 媒体 url 后缀分类 ----------

/// 媒体 url 后缀归类（rich-text-media.md §2 白名单两档）。
enum MediaSuffix {
  /// 音频，可直接内嵌播放。
  audioPlayable,

  /// 音频但平台兼容性存疑（如 .amr）：parse 照常归 AudioBlock（AST 不携带
  /// 能力信息），呈现层降级为文件卡不进播放器。
  audioDegrade,

  /// 视频。
  video,

  /// 非媒体或未识别。
  unknown,
}

const Set<String> _audioPlayableExt = {'.mp3', '.m4a', '.aac', '.wav', '.opus'};
const Set<String> _audioDegradeExt = {'.amr'};
const Set<String> _videoExt = {'.mp4', '.mov', '.webm', '.m3u8'};

/// url → 后缀归类。取 `Uri.parse(url).path`（天然剥离 query 与 fragment）、
/// toLowerCase 后与白名单比对；parse 与呈现层共用此单一事实源。
MediaSuffix classifyMediaUrl(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return MediaSuffix.unknown;
  final ext = path.substring(dot).toLowerCase();
  if (_audioPlayableExt.contains(ext)) return MediaSuffix.audioPlayable;
  if (_audioDegradeExt.contains(ext)) return MediaSuffix.audioDegrade;
  if (_videoExt.contains(ext)) return MediaSuffix.video;
  return MediaSuffix.unknown;
}

/// AI 回写防冲刷护城河（2026-09-30 拍板叮嘱②，rich-text-media.md §7）：
/// 对比原 md 与 AI 产出 md 的**行内媒体块 url 集合**，返回原文有而产出丢失的 url。
/// 非空 = AI 润色/重构自作主张删掉了用户媒体资产，动作层必须拒绝整替（保留原文）。
/// 只对 apply_ai_result 管线回写生效；UI/MCP 的 update 走块编辑器，用户删媒体是合法操作。
Set<String> lostMediaUrls(String originalMd, String incomingMd) {
  Set<String> mediaUrlsOf(String md) => {
    for (final b in MarkdownSubsetParser().parse(md))
      ...switch (b) {
        ImageBlock(:final url) => {url},
        AudioBlock(:final url) => {url},
        VideoBlock(:final url) => {url},
        _ => <String>{},
      },
  };
  final original = mediaUrlsOf(originalMd);
  if (original.isEmpty) return const {};
  return original.difference(mediaUrlsOf(incomingMd));
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
      // 媒体块降级（三出口之 blockToPlain，rich-text-media.md §2）
      ImageBlock(:final alt) => alt.isEmpty ? '[图片]' : '[图片: $alt]',
      AudioBlock(:final label) => label.isEmpty ? '[音频]' : '[音频: $label]',
      VideoBlock(:final label) => label.isEmpty ? '[视频]' : '[视频: $label]',
    };

// ---------- 序列化 ----------

/// 行内纯文本需转义的字符：`\` 本身与子集语法标记（`*` `_` `[` `` ` ``）。
final RegExp _escapeInlineRe = RegExp(r'[\\*_[`]');

String _escapeText(String s) =>
    s.replaceAllMapped(_escapeInlineRe, (m) => '\\${m[0]}');

/// 行内节点 → Markdown 子集串。与 [MarkdownSubsetParser.parseInline] 互逆：
/// 纯文本中的语法标记一律转义，保证「字面内容」往返不变形。
String serializeInline(List<InlineNode> nodes) => nodes.map((n) => switch (n) {
      InlineText(:final text) => _escapeText(text),
      InlineStrong(:final children) => '**${serializeInline(children)}**',
      InlineEm(:final children) => '*${serializeInline(children)}*',
      InlineCode(:final code) => '`$code`',
      InlineLink(:final label, :final url) =>
        '[${_escapeText(label)}]($url)',
    }).join();

/// 块 → Markdown 子集串。与 [MarkdownSubsetParser.parse] 互逆（三出口护栏
/// 之 serialize，SSOT：docs/design/rich-text-component.md §5）。
String serializeBlock(RichBlock block) => switch (block) {
      HeadingBlock(:final level, :final inline) =>
        '${'#' * level} ${serializeInline(inline)}',
      ParagraphBlock(:final inline) => serializeInline(inline),
      QuoteBlock(:final children) => children
          .map(serializeBlock)
          .map((md) => md.split('\n').map((l) => '> $l').join('\n'))
          // 子块间补空引用行（`>`），否则重解析时相邻段落会并段
          .join('\n>\n'),
      ListBlock(:final ordered, :final items) =>
        items.asMap().entries.map((e) {
          final text = serializeInline(e.value.inline);
          final done = e.value.done;
          if (done != null) return '- [${done ? 'x' : ' '}] $text';
          return ordered ? '${e.key + 1}. $text' : '- $text';
        }).join('\n'),
      CodeBlock(:final code, :final language) =>
        '```${language ?? ''}\n$code\n```',
      DividerBlock() => '---',
      // 媒体块出口标准 Markdown 链接语法，MCP 桌面端零感知（§2）；
      // label/alt 原话直出，禁注入类型前缀（往返幂等）
      ImageBlock(:final url, :final alt) => '![${_escapeText(alt)}]($url)',
      AudioBlock(:final url, :final label) => '[${_escapeText(label)}]($url)',
      VideoBlock(:final url, :final label) => '[${_escapeText(label)}]($url)',
    };

/// 块列表 → Markdown 子集串（块间空行分隔；编辑器回写唯一出口）。
String serializeBlocks(List<RichBlock> blocks) =>
    blocks.map(serializeBlock).join('\n\n');

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

  /// 整行即媒体的两种形态（rich-text-media.md §2：只识别「整行即媒体」，
  /// 段落中间混排降级 InlineLink）。
  static final RegExp _imageLine = RegExp(r'^!\[([^\]]*)\]\(([^)]*)\)\s*$');
  static final RegExp _linkLine = RegExp(r'^\[([^\]]*)\]\(([^)]*)\)\s*$');

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

      // 媒体行：整行 `![alt](url)` → ImageBlock；整行 `[label](url)` 且后缀
      // 命中白名单 → AudioBlock/VideoBlock（不命中则落回普通段落，不丢内容）
      final image = _imageLine.firstMatch(line);
      if (image != null) {
        blocks.add(ImageBlock(url: image.group(2)!, alt: _unescape(image.group(1)!)));
        i++;
        continue;
      }
      final link = _linkLine.firstMatch(line);
      if (link != null) {
        final url = link.group(2)!;
        final media = classifyMediaUrl(url);
        if (media == MediaSuffix.audioPlayable || media == MediaSuffix.audioDegrade) {
          blocks.add(AudioBlock(url: url, label: _unescape(link.group(1)!)));
          i++;
          continue;
        }
        if (media == MediaSuffix.video) {
          blocks.add(VideoBlock(url: url, label: _unescape(link.group(1)!)));
          i++;
          continue;
        }
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
      _ordered.hasMatch(line) ||
      _imageLine.hasMatch(line) ||
      // 媒体链接行才算块起始（普通链接行仍并入段落，保持既有行为）
      (_linkLine.hasMatch(line) &&
          classifyMediaUrl(_linkLine.firstMatch(line)!.group(2)!) !=
              MediaSuffix.unknown);

  ListItem _listItem(String content) {
    final todo = _todo.firstMatch(content);
    if (todo != null) {
      final mark = todo.group(1)!;
      return ListItem(parseInline(todo.group(2)!), done: mark != ' ');
    }
    return ListItem(parseInline(content));
  }

  /// 行内解析：转义 / 粗体 / 斜体 / 行内码 / 链接，其余为纯文本。
  ///
  /// 匹配顺序即优先级：`\X` 转义最先（serialize 的字面出口），`**` 先于 `*`，
  /// 避免 `**粗**` 被拆成两个斜体。返回前合并相邻纯文本节点（规范形，
  /// 保证 parse→serialize→parse 块树逐节点相等）。
  @override
  List<InlineNode> parseInline(String text) {
    if (text.isEmpty) return const <InlineNode>[];

    final pattern = RegExp(
      r'\\([\\`*_\[])' // 1 转义：`\X` → 字面 X
      r'|(\*\*|__)(.+?)\2' // 2,3 粗体
      r'|(\*|_)(.+?)\4' // 4,5 斜体
      r'|`([^`]+)`' // 6 行内码
      r'|!?\[([^\]]*)\]\(([^)]*)\)', // 7,8 链接（`!` 前缀吞掉：行内图片降级 InlineLink，消灭「!+链接」残留）
      dotAll: true,
    );

    final out = <InlineNode>[];
    var pos = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > pos) {
        out.add(InlineText(text.substring(pos, m.start)));
      }
      if (m.group(1) != null) {
        out.add(InlineText(m.group(1)!));
      } else if (m.group(3) != null) {
        out.add(InlineStrong(parseInline(m.group(3)!)));
      } else if (m.group(5) != null) {
        out.add(InlineEm(parseInline(m.group(5)!)));
      } else if (m.group(6) != null) {
        out.add(InlineCode(m.group(6)!));
      } else if (m.group(7) != null) {
        out.add(InlineLink(label: _unescape(m.group(7)!), url: m.group(8) ?? ''));
      }
      pos = m.end;
    }
    if (pos < text.length) {
      out.add(InlineText(text.substring(pos)));
    }
    return out.isEmpty ? [InlineText(text)] : _mergeText(out);
  }

  /// 合并相邻 [InlineText]（转义会产生碎片节点，合并为规范形）。
  static List<InlineNode> _mergeText(List<InlineNode> nodes) {
    final out = <InlineNode>[];
    for (final n in nodes) {
      final last = out.isEmpty ? null : out.last;
      if (n is InlineText && last is InlineText) {
        out[out.length - 1] = InlineText(last.text + n.text);
      } else {
        out.add(n);
      }
    }
    return out;
  }

  static String _unescape(String s) =>
      s.replaceAllMapped(RegExp(r'\\([\\`*_\[\]])'), (m) => m.group(1)!);
}
