import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 差异类型（ai-writeback-revert §7：Inline Diff 绿增 / 红删）。
enum DiffKind { equal, insert, delete }

/// 行内片段：一次 diff 的最小着色单元。
class DiffSpan {
  const DiffSpan(this.text, this.kind);

  final String text;
  final DiffKind kind;
}

/// 一行差异（含若干行内片段）。整行新增 / 删除时只有一片；「改」行由
/// 相邻的一删一增两行表达（行内片段各自只标真正动过的部分）。
class DiffLine {
  const DiffLine({required this.spans, required this.kind});

  final List<DiffSpan> spans;
  final DiffKind kind;
}

/// diff 结果：行序列 + 变更概览统计 + 首个差异行下标（自动滚动定位用）。
class AiDiffResult {
  const AiDiffResult({
    required this.lines,
    required this.added,
    required this.deleted,
    required this.firstDiff,
  });

  final List<DiffLine> lines;

  /// 新增 / 删除字符数（概览口径：整行变更按整行长计）。
  final int added;
  final int deleted;

  /// 首个差异行下标；-1 = 两侧完全一致。
  final int firstDiff;

  bool get hasDiff => firstDiff >= 0;

  /// 变更概览（悬浮条统计用；无差异也给出明确说法，不静默留空）。
  String get summary =>
      hasDiff ? '新增 $added 字 · 删除 $deleted 字' : '与你的版本一致';
}

/// LCS 单元格上限（性能防线）：行/词元级 LCS 是 O(n·m)，超限一律退化为
/// 「公共前后缀裁剪 + 整段替换」，数万字长文不会把 UI 卡死——与本项目
/// 「长文本不许有 O(n²) 交互路径」的口径一致。
const int _kLcsCellCap = 250000;

/// 词元级行内 diff 的单行长度上限（超此值整行标变更，不细究行内）。
const int _kInlineMaxChars = 4000;

/// 文本差异：`before`（基线）↔ `after`（当前）的行级 + 行内词元级 diff。
///
/// 两阶段：先按行 LCS 对齐（行数少、代价低），再只对**成对的改动行**做
/// 词元级 LCS（中文按字切分，英文按词切分）——既给出可读的行内着色，
/// 又把最贵的运算圈在单行内。
AiDiffResult computeAiDiff({required String before, required String after}) {
  final a = before.split('\n');
  final b = after.split('\n');
  final ops = _lcsOps(a, b, cap: _kLcsCellCap);
  final lines = <DiffLine>[];
  var added = 0;
  var deleted = 0;
  var i = 0;
  while (i < ops.length) {
    final op = ops[i];
    if (op.kind == DiffKind.equal) {
      lines.add(
        DiffLine(spans: [DiffSpan(op.text, DiffKind.equal)], kind: DiffKind.equal),
      );
      i++;
      continue;
    }
    // 一段连续的删 + 一段连续的增：按行位置两两配对做行内 diff，剩余各自成行。
    final dels = <String>[];
    final inss = <String>[];
    while (i < ops.length && ops[i].kind == DiffKind.delete) {
      dels.add(ops[i].text);
      i++;
    }
    while (i < ops.length && ops[i].kind == DiffKind.insert) {
      inss.add(ops[i].text);
      i++;
    }
    final pairs = math.min(dels.length, inss.length);
    for (var t = 0; t < pairs; t++) {
      final (delSpans, insSpans) = _inlineDiff(dels[t], inss[t]);
      lines.add(DiffLine(spans: delSpans, kind: DiffKind.delete));
      lines.add(DiffLine(spans: insSpans, kind: DiffKind.insert));
    }
    for (var t = pairs; t < dels.length; t++) {
      lines.add(
        DiffLine(spans: [DiffSpan(dels[t], DiffKind.delete)], kind: DiffKind.delete),
      );
    }
    for (var t = pairs; t < inss.length; t++) {
      lines.add(
        DiffLine(spans: [DiffSpan(inss[t], DiffKind.insert)], kind: DiffKind.insert),
      );
    }
    for (final d in dels) {
      deleted += d.length;
    }
    for (final s in inss) {
      added += s.length;
    }
  }
  return AiDiffResult(
    lines: lines,
    added: added,
    deleted: deleted,
    firstDiff: lines.indexWhere((l) => l.kind != DiffKind.equal),
  );
}

/// 一次 LCS 对齐的操作（保留文本，供上层组装）。
class _Op {
  const _Op(this.kind, this.text);

  final DiffKind kind;
  final String text;
}

/// 通用 LCS diff：产出 equal/delete/insert 操作序列。
///
/// [cap] 超限（n·m 太大）时退化为公共前后缀裁剪 + 整段替换——保住了
/// 「不卡死」，代价是超长文本的 diff 粒度变粗（有界降级，非静默失败）。
List<_Op> _lcsOps(List<String> a, List<String> b, {required int cap}) {
  final n = a.length;
  final m = b.length;
  if (n * m > cap) return _coarseOps(a, b);
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  final ops = <_Op>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      ops.add(_Op(DiffKind.equal, a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.add(_Op(DiffKind.delete, a[i]));
      i++;
    } else {
      ops.add(_Op(DiffKind.insert, b[j]));
      j++;
    }
  }
  while (i < n) {
    ops.add(_Op(DiffKind.delete, a[i]));
    i++;
  }
  while (j < m) {
    ops.add(_Op(DiffKind.insert, b[j]));
    j++;
  }
  return ops;
}

/// 粗粒度降级：公共前后缀之外的部分整段判为「删 + 增」。
List<_Op> _coarseOps(List<String> a, List<String> b) {
  final short = math.min(a.length, b.length);
  var p = 0;
  while (p < short && a[p] == b[p]) {
    p++;
  }
  var s = 0;
  while (s < short - p && a[a.length - 1 - s] == b[b.length - 1 - s]) {
    s++;
  }
  return [
    for (var i = 0; i < p; i++) _Op(DiffKind.equal, a[i]),
    for (var i = p; i < a.length - s; i++) _Op(DiffKind.delete, a[i]),
    for (var i = p; i < b.length - s; i++) _Op(DiffKind.insert, b[i]),
    for (var i = 0; i < s; i++) _Op(DiffKind.equal, a[a.length - s + i]),
  ];
}

/// 行内 diff：返回（删除侧片段, 新增侧片段）——两侧都保留 equal 部分，
/// 使红/绿两行各自都能通读，而不是只剩被改动的那几个字。
(List<DiffSpan>, List<DiffSpan>) _inlineDiff(String a, String b) {
  if (a.isEmpty || b.isEmpty || a.length > _kInlineMaxChars || b.length > _kInlineMaxChars) {
    return ([DiffSpan(a, DiffKind.delete)], [DiffSpan(b, DiffKind.insert)]);
  }
  final ta = _tokens(a);
  final tb = _tokens(b);
  if (ta.length * tb.length > _kLcsCellCap) {
    return ([DiffSpan(a, DiffKind.delete)], [DiffSpan(b, DiffKind.insert)]);
  }
  final del = <DiffSpan>[];
  final ins = <DiffSpan>[];
  for (final op in _lcsOps(ta, tb, cap: _kLcsCellCap)) {
    switch (op.kind) {
      case DiffKind.equal:
        _appendSpan(del, op.text, DiffKind.equal);
        _appendSpan(ins, op.text, DiffKind.equal);
      case DiffKind.delete:
        _appendSpan(del, op.text, DiffKind.delete);
      case DiffKind.insert:
        _appendSpan(ins, op.text, DiffKind.insert);
    }
  }
  if (del.isEmpty) del.add(DiffSpan(a, DiffKind.delete));
  if (ins.isEmpty) ins.add(DiffSpan(b, DiffKind.insert));
  return (del, ins);
}

void _appendSpan(List<DiffSpan> out, String text, DiffKind kind) {
  if (text.isEmpty) return;
  if (out.isNotEmpty && out.last.kind == kind) {
    out[out.length - 1] = DiffSpan(out.last.text + text, kind);
    return;
  }
  out.add(DiffSpan(text, kind));
}

/// 词元切分：CJK 逐字成词元（中文没有空格，整段成一元就退化成整行标红/绿），
/// 其余按连续非空白串 + 空白串切分。
List<String> _tokens(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
  }

  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (_isCjk(r) || ch == ' ' || ch == '\t') {
      flush();
      out.add(ch);
    } else {
      buf.write(ch);
    }
  }
  flush();
  return out;
}

bool _isCjk(int r) =>
    (r >= 0x3400 && r <= 0x9FFF) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0x3000 && r <= 0x303F) ||
    (r >= 0xFF00 && r <= 0xFFEF);

/// Inline Diff 只读视图（ai-writeback-revert §7/§8.6）。
///
/// **只读是本组件的硬约束**：对比态若允许直接打字接管，覆盖保存会把 diff
/// 的着色语义一并写进 `human_md` 污染 Markdown——故本组件不挂任何输入框，
/// 要接管必须先退出对比回到纯 Markdown 渲染态。
class AiDiffView extends StatefulWidget {
  const AiDiffView({super.key, required this.result});

  final AiDiffResult result;

  @override
  State<AiDiffView> createState() => _AiDiffViewState();
}

class _AiDiffViewState extends State<AiDiffView> {
  final _firstKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 展开即平滑滚动到首个差异段落（§7 Scroll to View）：中长篇里手动翻找
    // 差异是不可接受的负担。等首帧布局完成后才有几何可滚。
    if (widget.result.hasDiff) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _firstKey.currentContext;
        if (ctx == null) return;
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: 0.15,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.sm,
        Insets.lg,
        Insets.xxl,
      ),
      itemCount: widget.result.lines.length,
      itemBuilder: (context, i) {
        final line = widget.result.lines[i];
        final isFirst = i == widget.result.firstDiff;
        final bg = switch (line.kind) {
          DiffKind.insert => Colors.green.withValues(alpha: 0.22),
          DiffKind.delete => Colors.red.withValues(alpha: 0.20),
          DiffKind.equal => null,
        };
        return Container(
          key: isFirst ? _firstKey : null,
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: RichText(
            text: TextSpan(
              style: base?.copyWith(
                height: 1.5,
                color: scheme.onSurface,
                // 等宽非必需（对比态追求可读性），但删除侧加删除线更直观
                decoration: line.kind == DiffKind.delete
                    ? TextDecoration.lineThrough
                    : null,
              ),
              children: [
                for (final s in line.spans)
                  TextSpan(
                    text: s.text,
                    style: switch (s.kind) {
                      DiffKind.insert => TextStyle(
                          backgroundColor: Colors.green.withValues(alpha: 0.45),
                          fontWeight: FontWeight.w600,
                        ),
                      DiffKind.delete => TextStyle(
                          backgroundColor: Colors.red.withValues(alpha: 0.40),
                          decoration: TextDecoration.lineThrough,
                        ),
                      DiffKind.equal => null,
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 打开对比面板（只读）：`before`（AI 动笔前基线）↔ `after`（当前正文）。
Future<void> showAiDiffSheet(
  BuildContext context, {
  required String before,
  required String after,
}) {
  final result = computeAiDiff(before: before, after: after);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.lg,
                  Insets.lg,
                  Insets.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.compare_arrows_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        'AI 动笔前 ↔ 当前版本',
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      result.summary,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                child: Text(
                  '对比为只读：要改动请先关闭本面板。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: Insets.md),
              const Divider(height: 1),
              Expanded(child: AiDiffView(result: result)),
            ],
          ),
        ),
      );
    },
  );
}
