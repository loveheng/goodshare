import 'dart:io';

import 'html_to_md.dart';
import 'plain_to_md.dart';

/// 文档归一化：把各种来源格式统一转成 app 的富文本载体（Markdown 子集）。
///
/// SSOT：docs/design/content-pipeline.md §4。
/// 与 `AiReconstructor` Registry / `ItemViewRegistry` 同构——新增格式 = 实现
/// [DocumentNormalizer] + 注册，框架零改动。
///
/// 归一化是**有损**的（尤其 PDF 启发式与复杂网页），故每次产出都带
/// [NormalizeMeta]：UI 据此向用户明示覆盖率与降级情况（R1：降级必须被感知，
/// 不允许静默成功）。

/// 富文本长度上限：超过即截断。
///
/// 依据：网页抓取正文上限 20000 字（`url_extract.dart`），且长文一次性构建
/// 全部 widget 必掉帧——渲染侧同样需要门控。
const int kNormalizeMaxChars = 20000;

/// 归一化覆盖率与降级信息。
class NormalizeMeta {
  const NormalizeMeta({
    required this.chars,
    this.degradedBlocks = 0,
    this.truncated = false,
    this.note,
  });

  /// 产出富文本字数。
  final int chars;

  /// 降级为纯文本的块数（如表格、无法表达的复杂结构）。
  final int degradedBlocks;

  /// 是否触发长度截断。
  final bool truncated;

  /// 失败 / 降级原因（原样展示，不自行编造兜底文案）。
  final String? note;

  Map<String, Object?> toJson() => {
        'chars': chars,
        'degraded_blocks': degradedBlocks,
        'truncated': truncated,
        if (note != null) 'note': note,
      };
}

/// 归一化产物：富文本 + 覆盖率元信息。
class NormalizedDoc {
  const NormalizedDoc({required this.markdown, required this.meta});

  /// Markdown 子集富文本。
  final String markdown;

  final NormalizeMeta meta;

  bool get isEmpty => markdown.trim().isEmpty;
}

/// 文档归一化器。
abstract class DocumentNormalizer {
  /// 支持的扩展名（小写，不含点）。
  List<String> get extensions;

  /// 归一化已读取的文本内容 → Markdown 子集。
  ///
  /// 纯函数实现（html/plain）直接返回；需要引擎的实现（pdf）内部异步处理。
  Future<NormalizedDoc> normalize(String content, {int maxChars = kNormalizeMaxChars});
}

/// 归一化器注册表：按扩展名分派。
class DocumentNormalizers {
  DocumentNormalizers._();

  static final List<DocumentNormalizer> _all = [
    MarkdownNormalizer(),
    HtmlNormalizer(),
    PlainTextNormalizer(),
    // PdfNormalizer 待 pdfx 引入后注册（PDF 是二进制，需专门读取路径）。
  ];

  /// 取路径扩展名（小写，不含点）；无扩展名返回空串。
  static String extOf(String path) {
    final name = path.split('/').last;
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }

  /// 按扩展名解析归一化器；无匹配返回 null（调用方据此给「不支持」提示）。
  static DocumentNormalizer? resolveFor(String path) {
    final ext = extOf(path);
    if (ext.isEmpty) return null;
    for (final n in _all) {
      if (n.extensions.contains(ext)) return n;
    }
    return null;
  }

  /// 读文件并归一化。无匹配归一化器 / 读取失败返回 null（不抛异常逃逸）。
  static Future<NormalizedDoc?> normalizeFile(
    String path, {
    int maxChars = kNormalizeMaxChars,
  }) async {
    final n = resolveFor(path);
    if (n == null) return null;
    try {
      final content = await File(path).readAsString();
      return await n.normalize(content, maxChars: maxChars);
    } catch (e) {
      return NormalizedDoc(
        markdown: '',
        meta: NormalizeMeta(chars: 0, note: '读取失败：$e'),
      );
    }
  }
}
