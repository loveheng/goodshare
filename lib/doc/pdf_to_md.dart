import 'package:pdfrx/pdfrx.dart';

import 'normalizer.dart';

/// PDF → 富文本（content-pipeline §4：pdfrx 提取文本 + 启发式判标题）。
///
/// **只支持文本型 PDF**（用户拍板）：pdfrx 走 pdfium 提取文本层，不做 OCR、
/// 不渲染页面——扫描件 / 图片型 PDF 提取为空，UI 据 [NormalizeMeta.note] 明示。
///
/// 保真度中低（设计标注 DEGRADE）：PDF 文本层常缺失段落 / 层级信息，启发式仅按
/// 行特征（短行 / 序号 / 全大写）猜标题，命中即 `##`，否则段落。宁可平，不吞内容。
class PdfNormalizer extends DocumentNormalizer {
  @override
  List<String> get extensions => const ['pdf'];

  @override
  Future<NormalizedDoc> normalize(String content, {int maxChars = kNormalizeMaxChars}) =>
      normalizePath(content, maxChars: maxChars);

  @override
  Future<NormalizedDoc> normalizePath(String path, {int maxChars = kNormalizeMaxChars}) async {
    // 直接调 openFile 属非 widget 上下文，pdfrx 需先初始化原生后端（幂等）。
    await pdfrxFlutterInitialize();
    final doc = await PdfDocument.openFile(path);
    try {
      final out = StringBuffer();
      var chars = 0;
      var degraded = 0;
      // 每页独立文本块：页间空行分隔，保留原始分页（便于回看点）
      for (var i = 0; i < doc.pages.length; i++) {
        if (i > 0) out.writeln();
        final page = doc.pages[i];
        final raw = await page.loadText();
        final pageText = raw?.fullText ?? '';
        final md = _structure(pageText);
        degraded += _countDegraded(pageText, md);
        if (chars + md.length > maxChars) {
          out.write(md.substring(0, (maxChars - chars).clamp(0, md.length)));
          return NormalizedDoc(
            markdown: out.toString(),
            meta: NormalizeMeta(chars: maxChars, truncated: true, degradedBlocks: degraded),
          );
        }
        out.write(md);
        chars += md.length;
      }
      if (chars == 0) {
        return NormalizedDoc(
          markdown: '',
          meta: NormalizeMeta(
            chars: 0,
            note: 'PDF 无文本层（可能是扫描件/图片型，本版不支持 OCR）',
          ),
        );
      }
      return NormalizedDoc(
        markdown: out.toString(),
        meta: NormalizeMeta(chars: chars, degradedBlocks: degraded),
      );
    } finally {
      doc.dispose();
    }
  }

  /// 启发式结构：把扁平文本按行切成 Markdown 子集；短行 / 序号 / 全大写猜作标题。
  static String _structure(String raw) {
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final buf = StringBuffer();
    for (final line in lines) {
      if (_isHeading(line)) {
        buf.writeln('## $line');
      } else {
        buf.writeln(line);
      }
      buf.writeln();
    }
    return buf.toString();
  }

  static bool _isHeading(String t) {
    if (t.length > 40) return false;
    if (RegExp(r'^[0-9]+[\.、。]').hasMatch(t)) return true;
    if (RegExp(r'^[一二三四五六七八九十百千]+[、.\s]').hasMatch(t)) return true;
    if (t == t.toUpperCase() && RegExp(r'[A-Z]').hasMatch(t)) return true;
    return false;
  }

  /// 行数多但零标题命中 → 整体平铺，记一次降级（提示结构丢失）。
  static int _countDegraded(String raw, String md) =>
      raw.contains(RegExp(r'[。.!?]')) && !md.contains('## ') ? 1 : 0;
}
