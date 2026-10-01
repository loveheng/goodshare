import 'package:flutter/material.dart';

import '../doc/rich_text.dart';
import 'rich_text_view.dart';
import 'tokens.dart';

/// 富文本正文公共组件（呈现层唯一入口，SSOT：docs/design/rich-text-component.md）。
///
/// 三层架构：调用层（页面）→ 本组件（呈现层）→ `lib/doc/rich_text.dart`（规则层）。
/// 本组件不做语法解析（只调规则层）、不认识 `InboxItem`。
///
/// 双面：
/// - [.sliver]（[contentSlivers]）：返回真 Sliver 对象供外层 `CustomScrollView`
///   虚拟化（长文性能硬约束，Phase 1 成果，禁止降级为 shrinkWrap）
/// - [ContentBody]（.inline）：自含 shrinkWrap ListView，用于附录、媒体附文等嵌入场景
/// - [ContentBodySliver]（.sliver，Phase 3）：sliver 面自带解析缓存与长文
///   Isolate 异步（详情页 slivers 直接放它，替代「先 sync parse 再 contentSlivers」）
///
/// 阅读态选择：正文区统一靠外层 [SelectionArea] 提供跨块复制；块内是普通
/// `Text`/`RichText`（见 [buildRichBlock]），禁止每块各自 `SelectableText`。
///
/// ```dart
/// // sliver 面（详情页 CustomScrollView 外层包 SelectionArea）：
/// SelectionArea(
///   child: CustomScrollView(slivers: [
///     ContentBodySliver(markdown: item.bodyText),
///   ]),
/// )
/// // inline 面：
/// ContentBody(markdown: item.bodyText)
/// ```
class ContentBody extends StatefulWidget {
  const ContentBody({
    super.key,
    required this.markdown,
    this.serif = false,
    this.parser = const MarkdownSubsetParser(),
    this.onTodoToggle,
    this.todoDone,
  });

  /// Markdown 子集富文本。
  final String markdown;

  /// 衬线阅读态（ui-spec §2.2 P0）：文章类详情开启，媒体附文不开启。
  final bool serif;

  final RichTextParser parser;

  /// 待办勾选回调（勾选是写操作，走动作层命令；null 时不可点）。
  final void Function(String text, bool done)? onTodoToggle;

  /// 判断某待办行是否已勾选。null 时按 Markdown 里的 `[x]` 显示。
  final bool Function(String text)? todoDone;

  @override
  State<ContentBody> createState() => _ContentBodyState();
}

class _ContentBodyState extends State<ContentBody> with RichBlockParseState {
  @override
  Widget build(BuildContext context) {
    ensureBlocksParsed(widget.markdown, widget.parser);
    final blocks = parsedBlocks;
    if (blocks.isEmpty) return const SizedBox.shrink();
    // inline 面：嵌入外层滚动容器，自身禁滚动；选择能力由调用方的 SelectionArea 提供
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemBuilder: (context, i) => Padding(
        padding: EdgeInsets.only(
          bottom: i == blocks.length - 1 ? 0 : gapAfterBlock(blocks[i]),
        ),
        child: buildRichBlock(
          context,
          blocks[i],
          serif: widget.serif,
          onTodoToggle: widget.onTodoToggle,
          todoDone: widget.todoDone,
        ),
      ),
      itemCount: blocks.length,
    );
  }
}

/// sliver 面：正文块列表 → 真 Sliver 列表（虚拟化，详情页 CustomScrollView 直接组合）。
///
/// 硬约束：返回的必须是 Sliver 对象——`CustomScrollView` 的 direct child 不接受
/// RenderBox，严禁在外面包 `Container`/`Padding` 等盒组件。
List<Widget> contentSlivers(
  List<RichBlock> blocks, {
  bool serif = false,
  void Function(String text, bool done)? onTodoToggle,
  bool Function(String text)? todoDone,
}) =>
    [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (c, i) => Padding(
            padding: EdgeInsets.only(
              bottom: i == blocks.length - 1 ? 0 : gapAfterBlock(blocks[i]),
            ),
            child: buildRichBlock(
              c,
              blocks[i],
              serif: serif,
              onTodoToggle: onTodoToggle,
              todoDone: todoDone,
            ),
          ),
          childCount: blocks.length,
        ),
      ),
    ];

/// sliver 面异步解析宿主（Phase 3）：自带解析缓存 + 长文 Isolate 异步。
///
/// `build` 直接产出 Sliver 对象，可作 `CustomScrollView` 的 slivers 成员
/// （虚拟化硬约束同 [contentSlivers]——一旦解析完成走 [SliverList]，在途/
/// 空结果才走 `SliverToBoxAdapter` 空占位）。替代「页面侧 sync parse 再
/// contentSlivers」的旧接法，长文打开不再阻塞 UI 帧。
class ContentBodySliver extends StatefulWidget {
  const ContentBodySliver({
    super.key,
    required this.markdown,
    this.serif = false,
    this.onTodoToggle,
    this.todoDone,
    this.emptyView,
  });

  /// Markdown 子集富文本。
  final String markdown;

  /// 衬线阅读态（ui-spec §2.2 P0）：文章类详情开启，媒体附文不开启。
  final bool serif;

  /// 待办勾选回调（勾选是写操作，走动作层命令；null 时不可点）。
  final void Function(String text, bool done)? onTodoToggle;

  /// 判断某待办行是否已勾选。null 时按 Markdown 里的 `[x]` 显示。
  final bool Function(String text)? todoDone;

  /// 解析结果为空时显示的 widget（内部包进 `SliverToBoxAdapter`；
  /// 缺省为空占位）。
  final Widget? emptyView;

  @override
  State<ContentBodySliver> createState() => _ContentBodySliverState();
}

class _ContentBodySliverState extends State<ContentBodySliver>
    with RichBlockParseState {
  @override
  Widget build(BuildContext context) {
    ensureBlocksParsed(widget.markdown);
    final blocks = parsedBlocks;
    if (blocks.isEmpty) {
      final empty = widget.emptyView;
      return empty == null
          ? const SliverToBoxAdapter(child: SizedBox.shrink())
          : SliverToBoxAdapter(child: empty);
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (c, i) => Padding(
          padding: EdgeInsets.only(
            bottom: i == blocks.length - 1 ? 0 : gapAfterBlock(blocks[i]),
          ),
          child: buildRichBlock(
            c,
            blocks[i],
            serif: widget.serif,
            onTodoToggle: widget.onTodoToggle,
            todoDone: widget.todoDone,
          ),
        ),
        childCount: blocks.length,
      ),
    );
  }
}

/// 块后间距（原 rich_text_view 的 `_gapAfter`，公开供双面共用）。
double gapAfterBlock(RichBlock b) => switch (b) {
      HeadingBlock() => Insets.lg,
      DividerBlock() => Insets.lg,
      CodeBlock() => Insets.lg,
      _ => Insets.md,
    };
