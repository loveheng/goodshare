import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../doc/rich_text.dart';
import 'media_blocks.dart';
import 'tokens.dart';

/// 富文本渲染：块树 → Flutter widget。
///
/// SSOT：docs/design/content-pipeline.md §5，docs/design/ui-spec.md §2.2（排版令牌）。
/// 取代 `flutter_markdown_plus` 的 `MarkdownBody`。
///
/// 排版令牌（文档感的来源）：
/// - 正文 `bodyLarge`(16) / 行高 1.65
/// - h1 22 w600 · h2 18 w600 · h3 16 w600 · h4-h6 递减
/// - 引用：左侧 3px 竖线 + 次级色 + 内缩
/// - 代码块：`surfaceContainerHighest` + 等宽 + 12 内边距
/// - 列表缩进 20；待办为勾选行（完成态删除线）
///
/// 渲染采用 `ListView.builder` 虚拟化（2026-09-30 Phase 1）：数万字长文只构建
/// 可视区 widget，不再一次性铺满 `Column`。详情页通过 [richBlocksOf] + [buildRichBlock]
/// 把正文 block 直接并入 `CustomScrollView` 的 `SliverList` 实现真正虚拟化。
/// 解析超阈值（[kRichParseIsolateThreshold]）转 Isolate 异步（Phase 3），
/// 长文打开不再阻塞 UI 帧；sliver 面用 `ContentBodySliver`。
class RichTextView extends StatefulWidget {
  const RichTextView({
    super.key,
    required this.markdown,
    this.parser = const MarkdownSubsetParser(),
    this.onTodoToggle,
    this.todoDone,
    this.shrinkWrap = false,
    this.physics,
  });

  /// Markdown 子集富文本。
  final String markdown;

  final RichTextParser parser;

  /// 待办勾选回调（待办行文本 + 目标状态）。
  ///
  /// **为 null 时待办不可点击**——本轮默认如此：勾选是写操作，须走动作层命令
  /// 并按 `todo_state_json` 的 hash 口径持久化（V2 接线）。接口先留，口径到时定。
  final void Function(String text, bool done)? onTodoToggle;

  /// 判断某待办行是否已勾选（文本 → 状态）。为 null 时只按 Markdown 里的 `[x]` 显示。
  final bool Function(String text)? todoDone;

  /// 是否嵌入其他滚动容器（如附录、嵌套列表）。
  ///
  /// 默认 false：自身作为独立可滚动 `ListView`。当被放进 `Column` / 另一个
  /// 滚动视图时须置 true，内部改用 `shrinkWrap` + 禁滚动，由外层负责滚动。
  final bool shrinkWrap;

  final ScrollPhysics? physics;

  @override
  State<RichTextView> createState() => _RichTextViewState();
}

/// 解析 Markdown 子集为块列表（供详情页 SliverList 虚拟化复用，避免重复解析）。
List<RichBlock> richBlocksOf(
  String markdown, [
  RichTextParser parser = const MarkdownSubsetParser(),
]) =>
    parser.parse(markdown);

// ---------- Phase 3：长文 Isolate 异步解析 ----------

/// Isolate 异步解析阈值（Phase 3）：低于此值同步解析，达到即转后台 isolate。
///
/// 阈值依据 2026-09-30 基准实测（桌面 JIT）：30k/60k 字符 parse ≈18/19ms，
/// 真机 AOT 按此推算 2-4 倍（40-80ms），远超 16ms 帧预算；8k 字符约 5ms
/// （JIT），低于可感 jank 门槛。isolate 派生本身有毫秒级开销，短文不值得。
const int kRichParseIsolateThreshold = 8 * 1024;

/// 是否应转 isolate 解析（自定义解析器永不转——闭包/自定义类型不跨 isolate，
/// 属测试/扩展场景，宁可阻塞不可错）。
bool _shouldIsolate(String markdown, RichTextParser parser) =>
    markdown.length >= kRichParseIsolateThreshold &&
    parser == const MarkdownSubsetParser();

/// 长文异步解析：长文转 Isolate（`compute`，结果经 `Isolate.exit` 传递——
/// 块树是纯 Dart 对象图，可安全跨 isolate）；短文/自定义解析器同步。
Future<List<RichBlock>> richBlocksOfAsync(
  String markdown, [
  RichTextParser parser = const MarkdownSubsetParser(),
]) async {
  if (!_shouldIsolate(markdown, parser)) return parser.parse(markdown);
  return compute(_parseInIsolate, markdown);
}

/// isolate 入口（顶层函数，[compute] 要求）。
List<RichBlock> _parseInIsolate(String markdown) =>
    const MarkdownSubsetParser().parse(markdown);

/// 解析缓存 + 长文 Isolate 异步共享状态（Phase 3）。
///
/// 供 [RichTextView] / `ContentBody` / `ContentBodySliver` 三个渲染宿主复用：
/// 同一 markdown 不重复解析；长文转 isolate，在途渲染空，结果回来后
/// [setState] 补上。seq 守卫丢弃过期结果——markdown 快速切换（A→B→A）时
/// 只有最后一次派发的结果会被采纳，不串块、不死锁。
mixin RichBlockParseState<S extends StatefulWidget> on State<S> {
  List<RichBlock> _blocks = const [];
  String? _parsedSource;
  int _parseSeq = 0;

  /// 当前已解析的块列表（未回填时空列表）。
  List<RichBlock> get parsedBlocks => _blocks;

  /// 确保按当前 markdown 解析完毕（短文同步、长文异步；build 内调用安全）。
  void ensureBlocksParsed(
    String markdown, [
    RichTextParser parser = const MarkdownSubsetParser(),
  ]) {
    if (_parsedSource == markdown) return;
    _parsedSource = markdown;
    final seq = ++_parseSeq;
    if (!_shouldIsolate(markdown, parser)) {
      _blocks = parser.parse(markdown);
      return;
    }
    _blocks = const [];
    richBlocksOfAsync(markdown, parser).then((blocks) {
      if (!mounted || seq != _parseSeq) return;
      setState(() => _blocks = blocks);
    });
  }
}

class _RichTextViewState extends State<RichTextView> with RichBlockParseState {
  @override
  Widget build(BuildContext context) {
    ensureBlocksParsed(widget.markdown, widget.parser);
    final blocks = parsedBlocks;
    if (blocks.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : widget.physics,
      padding: widget.shrinkWrap ? EdgeInsets.zero : null,
      itemBuilder: (context, i) => Padding(
        padding: EdgeInsets.only(
          bottom: i == blocks.length - 1 ? 0 : _gapAfter(blocks[i]),
        ),
        child: buildRichBlock(
          context,
          blocks[i],
          onTodoToggle: widget.onTodoToggle,
          todoDone: widget.todoDone,
        ),
      ),
      itemCount: blocks.length,
    );
  }
}

/// 构建单个富文本块（与 [RichTextView] 共用，详情页 SliverList 直接复用）。
///
/// [serif] = 衬线阅读态（ui-spec §2.2 P0）：正文/标题走系统衬线 + 行高 ≥1.7，
/// 文章类详情（note/chatlog/url/document）开启；媒体类转录稿不开启。
Widget buildRichBlock(
  BuildContext context,
  RichBlock block, {
  bool serif = false,
  void Function(String text, bool done)? onTodoToggle,
  bool Function(String text)? todoDone,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;

  return switch (block) {
    // 块内用普通 Text/RichText：跨块选择由外层 SelectionArea 统一提供
    // （rich-text-component.md §3 阅读态选择能力约束）
    HeadingBlock(:final level, :final inline) => Text.rich(
        _spans(context, inline, _headingStyle(theme, level, serif)),
      ),
    ParagraphBlock(:final inline) => Text.rich(
        _spans(context, inline, _bodyStyle(theme, serif)),
      ),
    QuoteBlock(:final children) => Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(width: 3, color: scheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.only(left: Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in children) buildRichBlock(context, c, serif: serif),
          ],
        ),
      ),
    CodeBlock(:final code) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Text(
          code,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      ),
    DividerBlock() => Divider(height: 1, color: scheme.outlineVariant),
    ListBlock(:final items, :final ordered) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, item) in items.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: _buildListItem(
                context,
                item,
                ordered ? '${i + 1}.' : '•',
                serif,
                onTodoToggle,
                todoDone,
              ),
            ),
        ],
      ),
    // 行内媒体块（SSOT：docs/design/rich-text-media.md §3）；QuoteBlock 子块
    // 经同一 buildRichBlock 递归，引用内媒体块照常渲染
    ImageBlock b => InlineMediaImage(block: b),
    AudioBlock b => InlineMediaAudio(block: b),
    VideoBlock b => InlineMediaVideo(block: b),
  };
}

double _gapAfter(RichBlock b) => switch (b) {
      HeadingBlock() => Insets.lg,
      DividerBlock() => Insets.lg,
      CodeBlock() => Insets.lg,
      _ => Insets.md,
    };

Widget _buildListItem(
  BuildContext context,
  ListItem item,
  String marker,
  bool serif,
  void Function(String text, bool done)? onTodoToggle,
  bool Function(String text)? todoDone,
) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final text = inlineToPlain(item.inline);

  if (item.done != null) {
    final done = todoDone?.call(text) ?? (item.done ?? false);
    final canToggle = onTodoToggle != null;
    return InkWell(
      onTap: canToggle ? () => onTodoToggle(text, !done) : null,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              done ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: done ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text.rich(
                _spans(
                  context,
                  item.inline,
                  _bodyStyle(theme, serif).copyWith(
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? scheme.onSurfaceVariant : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 20,
        child: Text(
          marker,
          style: _bodyStyle(theme, serif).copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      Expanded(
        child: Text.rich(
          _spans(context, item.inline, _bodyStyle(theme, serif)),
        ),
      ),
    ],
  );
}

/// 正文样式。[serif] = 衬线阅读态（ui-spec §2.2）：系统衬线 + 暖白已由
/// colorScheme.onSurface 提供 + 行高 ≥1.7（非衬线保持 1.65）。
TextStyle _bodyStyle(ThemeData theme, bool serif) =>
    (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: serif ? 1.75 : 1.65,
      fontFamily: serif ? 'serif' : null,
    );

/// 标题层级映射 M3 `textTheme`（架构 R7：禁止裸 fontSize 字面量）。
///
/// h1 `headlineSmall`(24) / h2 `titleLarge`(22) / h3 `titleMedium`(16) /
/// h4-h6 `titleSmall`(14)，均 w600；行高比正文紧；[serif] 时标题同衬线。
TextStyle _headingStyle(ThemeData theme, int level, bool serif) {
  final base = switch (level) {
    1 => theme.textTheme.headlineSmall,
    2 => theme.textTheme.titleLarge,
    3 => theme.textTheme.titleMedium,
    _ => theme.textTheme.titleSmall,
  };
  return (base ?? _bodyStyle(theme, serif)).copyWith(
    fontWeight: FontWeight.w600,
    height: 1.35,
    fontFamily: serif ? 'serif' : null,
  );
}

TextSpan _spans(BuildContext context, List<InlineNode> nodes, TextStyle base) =>
    TextSpan(children: [for (final n in nodes) _span(context, n, base)]);

TextSpan _span(BuildContext context, InlineNode node, TextStyle base) {
  final scheme = Theme.of(context).colorScheme;
  return switch (node) {
    InlineText(:final text) => TextSpan(text: text, style: base),
    InlineStrong(:final children) => TextSpan(
        children: [for (final c in children) _span(context, c, base)],
        style: base.copyWith(fontWeight: FontWeight.w700),
      ),
    InlineEm(:final children) => TextSpan(
        children: [for (final c in children) _span(context, c, base)],
        style: base.copyWith(fontStyle: FontStyle.italic),
      ),
    InlineCode(:final code) => TextSpan(
        text: code,
        style: base.copyWith(
          fontFamily: 'monospace',
          backgroundColor: scheme.surfaceContainerHighest,
        ),
      ),
    InlineLink(:final label, :final url) => TextSpan(
        text: label,
        style: base.copyWith(
          color: scheme.primary,
          decoration: TextDecoration.underline,
        ),
        // 默认不可点击（不引 url_launcher）；URL 保留在语义里供后续启用
        semanticsLabel: url.isEmpty ? label : '$label（$url）',
      ),
  };
}

/// 富文本 → 纯文本（列表预览等场景）。
String richTextToPlain(String markdown) =>
    MarkdownSubsetParser().parse(markdown).map(blockToPlain).join('\n\n');
