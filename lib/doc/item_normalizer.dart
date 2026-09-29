import 'dart:convert';

import 'normalizer.dart';

/// 条目级文档归一化：把转换产物落成条目字段，并给出用户可见的覆盖率文案。
///
/// SSOT：docs/design/content-pipeline.md §4 / §7。
class ItemDocNormalizer {
  const ItemDocNormalizer();

  /// 归一化产物 → 待写入的条目字段。
  ///
  /// 富文本写 `human_md`：语义即「人类可读正文」，AI 重构时自然升级覆盖，
  /// **不新增列**（content-pipeline §4 决策）。覆盖率与确认状态写 `doc_meta_json`。
  Map<String, Object?> fieldsFor(NormalizedDoc doc) => {
        'human_md': doc.markdown,
        'doc_meta_json': jsonEncode(doc.meta.toJson()),
      };

  /// 是否需要用户确认。
  ///
  /// **分级提醒**（content-pipeline §7）：转换质量高则**静默**——零阻力吞噬是
  /// 核心体验，每次弹确认等于自毁；只有有损 / 不确定才提示。
  bool needsConfirmation(NormalizedDoc doc) =>
      doc.meta.truncated ||
      doc.meta.degradedBlocks > 0 ||
      (doc.meta.note?.isNotEmpty ?? false);

  /// 覆盖率文案：把指标翻译成人话，供确认条展示。
  ///
  /// 硬要求：确认必须「**有据**」——只给一段渲染好的文字让用户点确认，
  /// 他判断不出后面是不是被截断了。故必须暴露字数 / 降级数 / 是否截断。
  String coverageText(NormalizeMeta meta) {
    final parts = <String>['共提取 ${meta.chars} 字'];
    if (meta.degradedBlocks > 0) {
      parts.add('${meta.degradedBlocks} 处结构已降级为纯文本');
    }
    if (meta.truncated) parts.add('超出上限已截断');
    if (meta.note != null) parts.add(meta.note!);
    return parts.join(' · ');
  }

  /// 标记用户已确认（写回 doc_meta_json，避免每次打开都提示）。
  String confirmedMetaJson(NormalizeMeta meta) => jsonEncode({
        ...meta.toJson(),
        'confirmed': true,
        'confirmed_at': DateTime.now().millisecondsSinceEpoch,
      });
}
