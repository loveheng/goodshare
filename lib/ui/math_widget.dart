import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import 'tokens.dart';

/// 数学公式渲染：行内（`$…$`）与块级（`$$…$$`）共用 [Math]（flutter_math_fork，
/// 纯 Dart 端口 KaTeX——离线、无 WebView，覆盖绝大多数 LaTeX 语法）。
///
/// 解析层（package:rich_text）已把数学作为一等公民（`InlineMath` / `MathBlock`），
/// 本件只负责「渲染闭环」：把 AST 节点落成可见公式。
///
/// **错误兜底铁律**：非法 / 不支持的 LaTeX 不崩、不丢内容——降级为等宽源码文字
/// （见 [_mathFallback]）。与项目总原则「降级铁律：宁可样式平，不可吞内容」同构。
/// 设计落点 SSOT：docs/design/rich-text-gfm.md 数学章节。

/// 行内公式：作为 [WidgetSpan] 嵌进 `Text.rich`，基线居中对齐；超宽时横向滚动
/// （不撑破段落流、不溢出裁剪）。
InlineSpan inlineMathSpan(
  String source,
  TextStyle base, {
  required ColorScheme scheme,
}) =>
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _ScrollableMath(source: source, display: false, base: base, scheme: scheme),
    );

/// 块级公式：居中 + 超宽横向滚动（短公式居中、长公式可滚动，二者不冲突）。
///
/// 渲染为带浅色圆角容器的独立块，阅读态与代码块/引用块同源质感。
Widget mathBlockView(
  String source,
  TextStyle base, {
  required ColorScheme scheme,
}) =>
    Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: _ScrollableMath(source: source, display: true, base: base, scheme: scheme),
    );

/// 公式 + 横向滚动容器（行内 / 块级共用）。
///
/// - 行内：受 [WidgetSpan] 紧约束，宽度即剩余行宽，超宽则内部滚动；高度取公式高。
/// - 块级：经 [LayoutBuilder] 给最小宽度 = 视口宽——短公式居中、长公式超出后滚动。
class _ScrollableMath extends StatelessWidget {
  const _ScrollableMath({
    required this.source,
    required this.display,
    required this.base,
    required this.scheme,
  });

  final String source;
  final bool display;
  final TextStyle base;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      source,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: base.copyWith(decoration: TextDecoration.none),
      onErrorFallback: (_) => _mathFallback(source, base, scheme),
    );

    if (!display) {
      return SingleChildScrollView(scrollDirection: Axis.horizontal, child: math);
    }

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Center(child: math),
        ),
      ),
    );
  }
}

/// 源码降级（onErrorFallback）：非法 / 不支持的 LaTeX 以等宽文字原样显示源码，
/// 不丢内容、不抛异常（阅读态零崩溃）。
Widget _mathFallback(String source, TextStyle base, ColorScheme scheme) => Text(
      source,
      style: base.copyWith(
        fontFamily: 'monospace',
        decoration: TextDecoration.none,
        backgroundColor: null,
        color: scheme.onSurfaceVariant,
      ),
    );
