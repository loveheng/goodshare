import 'package:rich_text/markdown_subset.dart' show SpanListKind;

/// S0 单行纯解析原语（note-editor-source-of-truth.md §6）：`parseLine(line) →
/// LineShape`——行结构不再由坐标 run 存储，而由单行解析实时推导的基石。
///
/// 纯 Dart、零 Flutter 依赖、O(行长)。口径与既有实现**同源**：
/// - 标题：`MarkdownSubsetParser._heading`（`^(#{1,6})\s+`，捕获档位）；
/// - 列表标记：原 `quick_note_span_codec.dart` 的 `_listRe`/`_listMarkerOf`
///   **原样迁入**（见下方注释），本文件与 codec 共用同一份正则——严禁出现
///   第二条解析路径（§4.6）。
///
/// v1 范围：标题 + 列表（bullet/ordered/todo）线级语法。引用/代码块/分隔线属
/// 详情页块级语法，按 §6 S4 再扩 kind，本版不认。

/// 与解析器 `_heading`（`^(#{1,6})\s+(.*)$`）同源：捕获组 1 = `#` 串（档位）。
/// 自 `quick_note_span_codec.dart` 迁入（S0 纯搬迁，正则文本未改）。
final RegExp headingRe = RegExp(r'^(#{1,6})\s+');

/// 引用标记（与解析器 `_quote` `^\s*>\s?` 同源）：捕获标记区含尾随一个可选
/// 空格，正文起点 = end。
final RegExp quoteRe = RegExp(r'^\s*>\s?');

/// 围栏行（与解析器 `_fence` `^```(\w*)\s*$` 同源）：开栏/合栏同一正则，
/// 围栏状态机在 [parseLine] 的消费方（deriveLineRuns）维护。语言标注属
/// 标记区一部分（凹槽/显隐不显示它，正文渲染按围栏样式）。
final RegExp fenceRe = RegExp(r'^```(\w*)\s*$');

/// 行首列表标记（与解析器 `_bullet` / `_ordered` / `_todo` **同源**）：
/// - 无序：`[-*] ` 起手；
/// - 有序：`<数字>[.)] ` 起手——读刮与详情页同一 grammar（`N. ` / `N) `）；
/// - 勾选框：`[ ]` / `[x]` / `[X]`，2026-10-07 起**可裸写**（不强制 `- ` 前缀）。
///
/// 三个捕获组 `bullet` / `ord` / `cb` 全部可选（否则「裸勾选框」与「`- [ ]`」
/// 无法共用一条式），故必须由 [listMarkerOf] 补做「三者至少命中一个」的
/// 校验——否则空行也会被零宽匹配。匹配止于内容起点，便于剥前缀取纯文本。
/// 自 `quick_note_span_codec.dart` 迁入（S0 纯搬迁，正则文本未改）。
final RegExp listRe = RegExp(
  r'^\s*(?:(?<bullet>[-*])[ \t]+|(?<ord>\d+)[.)][ \t]+)?'
  r'(?<cb>\[[ xX]\])?[ \t]*',
);

/// 行首列表标记的解析结果：[end] = 需剥离的前缀长度（含尾随空白）。
class ListMarker {
  const ListMarker(this.kind, this.done, this.end);

  final SpanListKind kind;
  final bool done;

  /// 前缀长度（下一切内容起点），用于剥前缀与回退光标。
  final int end;
}

/// 剥骨架：[listRe] → 语义化标记；无标记返回 null。
/// ⚠️ `done` 只能来自**尚未转换的行文本**（此时勾选框还在文本里）；一旦转换
/// 完成，`done` 便只存活于上层状态——重扫必须自既有状态继承，禁止再从文本反推。
/// 自 `quick_note_span_codec.dart` 迁入（S0 纯搬迁，逻辑未改）。
ListMarker? listMarkerOf(String line) {
  final m = listRe.firstMatch(line);
  if (m == null) return null;
  final cb = m.namedGroup('cb');
  final ord = m.namedGroup('ord');
  final bullet = m.namedGroup('bullet');
  // 三者全空 = 零宽匹配（普通行/空行）→ 不是列表标记
  if (cb == null && ord == null && bullet == null) return null;
  // 优先级：勾选框 > 有序 > 无序。理由：`1. [ ] 甲` 这类混合写法在详情页被
  // 解析成「有序块里的待办项」（item.done 非 null），此处取待办才同源。
  final kind = cb != null
      ? SpanListKind.todo
      : (ord != null ? SpanListKind.ordered : SpanListKind.bullet);
  return ListMarker(kind, cb == '[x]' || cb == '[X]', m.end);
}

/// 单行形状种类。
enum LineKind { plain, heading, list, quote, fence }

/// 单行解析结果（纯值对象）：一行只有一种身份（标题 ⊻ 列表 ⊻ 正文），
/// 类型层面即互斥——旧模型「levelRuns/listRuns 平行列表 + 注释声明互斥」的
/// 根症（§1.2）在此消失。
class LineShape {
  const LineShape.plain()
    : kind = LineKind.plain,
      level = 0,
      listKind = null,
      done = false,
      markerEnd = 0;

  const LineShape.heading(this.level, this.markerEnd)
    : kind = LineKind.heading,
      listKind = null,
      done = false;

  const LineShape.list(this.listKind, this.done, this.markerEnd)
    : kind = LineKind.list,
      level = 0;

  const LineShape.quote(this.markerEnd)
    : kind = LineKind.quote,
      level = 0,
      listKind = null,
      done = false;

  const LineShape.fence(this.markerEnd)
    : kind = LineKind.fence,
      level = 0,
      listKind = null,
      done = false;

  final LineKind kind;

  /// 标题档位（1–6）；仅 [LineKind.heading] 有意义。
  final int level;

  /// 列表种类；仅 [LineKind.list] 有意义。
  final SpanListKind? listKind;

  /// 待办勾选态；仅 [LineKind.list] 且 kind=todo 有意义。
  final bool done;

  /// 标记区末端（含尾随空白）= 正文起点 = bodyStart（0 = 无标记）。
  /// 显隐判据（§3.1）「光标 ≤ 标记区末端」直接消费此值。
  final int markerEnd;

  bool get isPlain => kind == LineKind.plain;
  bool get isHeading => kind == LineKind.heading;
  bool get isList => kind == LineKind.list;
  bool get isQuote => kind == LineKind.quote;
  bool get isFence => kind == LineKind.fence;

  /// 正文片段（标记区之后的内容）；纯文本行即整行。
  String bodyOf(String line) => markerEnd <= 0
      ? line
      : (markerEnd >= line.length ? '' : line.substring(markerEnd));

  /// 正文起点（= markerEnd；纯文本行 0）。
  int get bodyStart => markerEnd;
}

/// 单行解析原语：文本行 → 结构形状。L1（活跃行即时层）与 L2（全局渲染层）
/// 必须共用本函数（契约 2/3），禁止任何旁路正则。
///
/// 优先级与 codec 播种一致：**标题优先**——标题行不再认列表（标题与列表互斥）。
LineShape parseLine(String line) {
  final h = headingRe.firstMatch(line);
  if (h != null) {
    return LineShape.heading(h.group(1)!.length.clamp(1, 6), h.end);
  }
  final mk = listMarkerOf(line);
  if (mk != null) {
    return LineShape.list(mk.kind, mk.done, mk.end);
  }
  final q = quoteRe.firstMatch(line);
  if (q != null) {
    return LineShape.quote(q.end);
  }
  final f = fenceRe.firstMatch(line);
  if (f != null) {
    return LineShape.fence(f.end);
  }
  return const LineShape.plain();
}
