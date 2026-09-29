import 'package:flutter/material.dart';

import '../doc/rich_text.dart';
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

class _RichTextViewState extends State<RichTextView> {
  List<RichBlock> _blocks = const [];
  String? _parsedSource;

  /// 解析结果缓存：长文（上限已放开为全量）每次 build 重解析会掉帧。
  void _ensureParsed() {
    if (_parsedSource == widget.markdown) return;
    _parsedSource = widget.markdown;
    _blocks = widget.parser.parse(widget.markdown);
  }

  @override
  Widget build(BuildContext context) {
    _ensureParsed();
    if (_blocks.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : widget.physics,
      padding: widget.shrinkWrap ? EdgeInsets.zero : null,
      itemBuilder: (context, i) => Padding(
        padding: EdgeInsets.only(
          bottom: i == _blocks.length - 1 ? 0 : _gapAfter(_blocks[i]),
        ),
        child: buildRichBlock(
          context,
          _blocks[i],
          onTodoToggle: widget.onTodoToggle,
          todoDone: widget.todoDone,
        ),
      ),
      itemCount: _blocks.length,
    );
  }
}

/// 构建单个富文本块（与 [RichTextView] 共用，详情页 SliverList 直接复用）。
Widget buildRichBlock(
  BuildContext context,
  RichBlock block, {
  void Function(String text, bool done)? onTodoToggle,
  bool Function(String text)? todoDone,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;

  return switch (block) {
    HeadingBlock(:final level, :final inline) => SelectableText.rich(
        _spans(context, inline, _headingStyle(theme, level)),
      ),
    ParagraphBlock(:final inline) => SelectableText.rich(
        _spans(context, inline, _bodyStyle(theme)),
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
            for (final c in children) buildRichBlock(context, c),
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
        child: SelectableText(
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
                onTodoToggle,
                todoDone,
              ),
            ),
        ],
      ),
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
              child: SelectableText.rich(
                _spans(
                  context,
                  item.inline,
                  _bodyStyle(theme).copyWith(
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
          style: _bodyStyle(theme).copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      Expanded(
        child: SelectableText.rich(
          _spans(context, item.inline, _bodyStyle(theme)),
        ),
      ),
    ],
  );
}

TextStyle _bodyStyle(ThemeData theme) =>
    (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(height: 1.65);

/// 标题层级映射 M3 `textTheme`（架构 R7：禁止裸 fontSize 字面量）。
///
/// h1 `headlineSmall`(24) / h2 `titleLarge`(22) / h3 `titleMedium`(16) /
/// h4-h6 `titleSmall`(14)，均 w600；行高比正文紧。
TextStyle _headingStyle(ThemeData theme, int level) {
  final base = switch (level) {
    1 => theme.textTheme.headlineSmall,
    2 => theme.textTheme.titleLarge,
    3 => theme.textTheme.titleMedium,
    _ => theme.textTheme.titleSmall,
  };
  return (base ?? _bodyStyle(theme)).copyWith(
    fontWeight: FontWeight.w600,
    height: 1.35,
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
