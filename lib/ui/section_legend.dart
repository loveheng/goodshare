/// 签名式分区卡（mymind 形态，SSOT ui-spec §2.2/§2.3）。
///
/// 「legend 骑框」：小签嵌在描边框顶边上（背景色切断边框），右侧一段延长线——
/// 与 mymind 详情页 TLDR / MIND TAGS 分区同构。详情页正文类分区
/// （TLDR / 附录 / 工具 / 标签）共用此组件，禁止各自手写「边框 + 小签」对。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class SectionLegendCard extends StatelessWidget {
  const SectionLegendCard({
    super.key,
    required this.legend,
    required this.child,
    this.margin = const EdgeInsets.only(bottom: Insets.md),
  });

  /// 分区签名（如 TLDR / 摘要 / 工具），签名式排版规则在组件内统一。
  final String legend;
  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 顶部 8 预留 legend 骑框空间：legend 高约 16，骑在 y=8 的顶边框上。
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          margin: (margin as EdgeInsets).add(const EdgeInsets.only(top: 8)),
          padding: const EdgeInsets.fromLTRB(
              Insets.md, Insets.lg, Insets.md, Insets.md),
          decoration: BoxDecoration(
            border: Border.all(width: 1, color: scheme.outline),
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: child,
        ),
        Positioned(
          top: 0,
          left: Insets.md,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 背景色底衬切断边框，形成「骑框」效果。
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                color: scheme.surface,
                child: Text(
                  legend,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // 延长线：legend 右侧一段边框延伸（mymind 签名元素）。
              Container(width: 48, height: 1, color: scheme.outline),
            ],
          ),
        ),
      ],
    );
  }
}
