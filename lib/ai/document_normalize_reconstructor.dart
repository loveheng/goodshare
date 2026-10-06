import 'dart:io';

import '../data/repository.dart';
import '../doc/item_normalizer.dart';
import '../doc/normalizer.dart';
import '../models/item.dart';
import 'reconstructor.dart';

/// 文档归一化（content-pipeline §9，2026-10-06）：document 条目摄入即入队
/// [Repository.taskNormalizeDocument]，按扩展名分派 html/plain/pdf/md 归一化器
/// （[DocumentNormalizers]），把转换产物落成 human_md + doc_meta_json。
///
/// 归一化是有损的（尤其 PDF 启发式与复杂网页），按 R1「降级必须被感知」：
/// 转换质量高则静默写回，有损 / 截断 / 不确定才在 note 里给覆盖率文案
/// （[ItemDocNormalizer] 的分级提醒）。
class DocumentNormalizeReconstructor implements AiReconstructor {
  const DocumentNormalizeReconstructor();

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == InboxItem.typeDocument &&
      input.taskAction == Repository.taskNormalizeDocument;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final path = input.rawFilePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      // 文件缺失：保留现正文，占位完成并带原因（降级不卡死口径）。
      return ReconstructResult(
        humanMd: input.humanMd ?? input.rawContent ?? '',
        note: '文档归一化未执行：文档文件不可访问',
      );
    }
    final doc = await DocumentNormalizers.normalizeFile(path);
    if (doc == null) {
      // 无匹配归一化器（不支持的扩展名）：明说，不静默吞。
      return ReconstructResult(
        humanMd: input.humanMd ?? input.rawContent ?? '',
        note: '无可用归一化器（不支持的文件类型）',
      );
    }
    if (doc.isEmpty) {
      return ReconstructResult(
        humanMd: input.humanMd ?? input.rawContent ?? '',
        note: doc.meta.note ?? '文档归一化无产出',
      );
    }
    final norm = const ItemDocNormalizer();
    final fields = norm.fieldsFor(doc);
    // 质量高则静默；有损 / 截断 / 存疑才提示覆盖率（零阻力吞噬是核心体验）。
    final note = norm.needsConfirmation(doc) ? norm.coverageText(doc.meta) : null;
    return ReconstructResult(
      humanMd: doc.markdown,
      docMetaJson: fields['doc_meta_json'] as String,
      note: note,
    );
  }
}
