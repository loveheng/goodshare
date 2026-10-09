import 'package:flutter/material.dart';

import 'package:goodshare/doc/rich_text.dart' show SpanListKind;
import 'package:goodshare/share/quick_note_line_shape.dart' show LineShape, parseLine;

/// 段类型枚举（问题#1 引导层·统一排版规约）：正文 / 一级标题 / 二级标题 /
/// 无序列表 / 引用 / 待办。与 [ComposerDoc.setLineKind] 的语义类型对齐，是
/// 侧轨角标、打样浮层、正文渲染共用的同一份「类型词汇」。
enum BlockKind { plain, h1, h2, bullet, quote, todo }

/// 段类型排版规约（Single Source of Truth）。
///
/// 正文渲染（[SpanTextEditingController] 经 `textTheme` 派生标题档位）、侧轨语义
/// 角标、打样浮层三者**共用同一份语义样式**——样式一律从 [TextTheme] token
/// 解析（arch-guard R7：不写裸 `fontSize` 字面量），与 `span_text_controller`
/// 的标题派生口径同源（H1=titleLarge / H2=titleMedium / 正文=bodyLarge），保证
/// 「所见即所选」：浮层打样的字重/行高与落地的正文逐像素一致。
class BlockPresentation {
  const BlockPresentation({
    required this.kind,
    required this.badge,
    required this.markerPrefix,
    required this.resolveStyle,
  });

  /// 类型。
  final BlockKind kind;

  /// 低对比度语义角标（侧轨/浮层左侧微缩标签）：H1 / H2 / • / ▎ / ☑ / T。
  final String badge;

  /// 行首标记字面（文本真相：标记本就在 buffer 里）；`plain` 为空串。
  final String markerPrefix;

  /// 语义样式解析：从主题 token 派生（不硬编码字号），供正文/打样复用。
  final TextStyle Function(TextTheme theme, ColorScheme scheme) resolveStyle;
}

/// 不可变规约表（问题#1 引导层全部显式类型 + 待办派生变体）。
final List<BlockPresentation> kBlockPresentations = [
  BlockPresentation(
    kind: BlockKind.plain,
    badge: 'T',
    markerPrefix: '',
    resolveStyle: (t, _) => t.bodyLarge ?? const TextStyle(),
  ),
  BlockPresentation(
    kind: BlockKind.h1,
    badge: 'H1',
    markerPrefix: '# ',
    // 2026-10-08：统一"标题=主色"语言——H1/H2 皆主色，层级仅靠字号档
    // （titleLarge 22 vs titleMedium 16）区分，正文(bodyLarge)为常规黑，三档一眼可分。
    resolveStyle: (t, s) => (t.titleLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: s.primary,
    ),
  ),
  BlockPresentation(
    kind: BlockKind.h2,
    badge: 'H2',
    markerPrefix: '## ',
    // 2026-10-08：标记区改透明隐藏后，「H2 与正文只差字重」会在编辑区糊成一
    // 片（用户实测看不出是标题）。补 md 编辑器同款**三件套**——字号档 + 加粗
    // + 主色：凭颜色一眼可辨，不依赖被隐藏的 `##` 标记。
    resolveStyle: (t, s) => (t.titleMedium ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w700,
      color: s.primary,
    ),
  ),
  BlockPresentation(
    kind: BlockKind.bullet,
    badge: '•',
    markerPrefix: '- ',
    resolveStyle: (t, _) => t.bodyLarge ?? const TextStyle(),
  ),
  BlockPresentation(
    kind: BlockKind.quote,
    badge: '▎',
    markerPrefix: '> ',
    resolveStyle: (t, s) => (t.bodyLarge ?? const TextStyle()).copyWith(
      fontStyle: FontStyle.italic,
      color: s.onSurfaceVariant,
    ),
  ),
  BlockPresentation(
    kind: BlockKind.todo,
    badge: '☑',
    markerPrefix: '- [ ] ',
    resolveStyle: (t, _) => t.bodyLarge ?? const TextStyle(),
  ),
];

/// 按类型取规约（缺省回退正文）。
BlockPresentation blockPresentationOf(BlockKind kind) =>
    kBlockPresentations.firstWhere((e) => e.kind == kind,
        orElse: () => kBlockPresentations.first);

/// 行类型推断（文本真相）：给定整段文本与光标偏移，取光标所在行的结构身份。
///
/// 直接复用 [parseLine]（L1/L2 共用原语，禁止旁路正则），与 [deriveLineRuns] /
/// [ComposerDoc] 同一套口径。编辑器仅落 H1/H2（档位 >2 归并到 H2）；有序项在
/// 角标里并入圆点（编辑器列表视觉只有 bullet）。
BlockKind lineKindOf(String plain, int caret) {
  caret = caret.clamp(0, plain.length);
  var start = 0;
  for (var i = 0; i < caret; i++) {
    if (plain.codeUnitAt(i) == 0x0A) start = i + 1;
  }
  final nl = plain.indexOf('\n', start);
  final line = plain.substring(start, nl < 0 ? plain.length : nl);
  final LineShape shape = parseLine(line);
  if (shape.isHeading) return shape.level == 1 ? BlockKind.h1 : BlockKind.h2;
  if (shape.isList) {
    return switch (shape.listKind) {
      SpanListKind.bullet => BlockKind.bullet,
      SpanListKind.todo => BlockKind.todo,
      SpanListKind.ordered => BlockKind.bullet,
      _ => BlockKind.plain,
    };
  }
  if (shape.isQuote) return BlockKind.quote;
  return BlockKind.plain;
}
