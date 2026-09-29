import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';

import '../data/repository.dart';
import 'reconstructor.dart';
import 'ml_capability.dart';

/// 文本分析（ML Kit Language ID + Entity Extraction，2026-09-29）：端侧、离线、零 GMS 依赖。
///
/// 仅**手动触发**（`task_action=analyze_text`，与 OCR / 分类 / 条码同口径：摄入不自动跑模型），
/// 作用于**笔记条目**。一次手动动作同时跑两件事：
/// ① 语言识别 → 写入 `facets['语言']`（BCP-47 离线转中文，未命中保留原始码）；
/// ② 实体提取（日期 / 邮箱 / 电话 / 地址 / URL / 金额 / 卡号等）→ 写入 `facets['实体']`
/// （结构化 `[类型:值]` 列表）。识别只标注不动作（如 URL 实体不自动打开）。
///
/// 错误 / 空产出按 R1/R3 可观测：失败原因进 `note`。
///
/// 设计取舍：**语言识别与实体提取合并为单一手动入口**——实体提取以语言为前置，
/// 两模型同跑一次最省事；拆成两个独立入口只会增加 UI / MCP / 队列各两套脚手架，
/// 对「用户只想看懂这段笔记是什么语言 + 有没有可提取的结构信息」无增益。
class TextAnalysisCapability extends MlCapability {
  TextAnalysisCapability();

  @override
  String get id => Repository.taskAnalyzeText;

  @override
  ExecutionMode get mode => ExecutionMode.backgroundQueue;

  @override
  Future<CapabilityReadiness> ensureReady() async => CapabilityReadiness.ready;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == 'note' && input.taskAction == Repository.taskAnalyzeText;

  /// 执行：取笔记正文 → 语言识别 →（语言受支持时）实体提取，返回原始结果。
  @override
  Future<TextAnalysisRaw> run(ReconstructInput input) async {
    final text = (input.humanMd ?? input.rawContent ?? '').trim();
    if (text.isEmpty) return const TextAnalysisRaw(noText: true);

    // ① 语言识别（离线、极快；BCP-47 码，'und' = 无法确定）。
    final identifier = LanguageIdentifier(confidenceThreshold: 0.5);
    final code = await identifier
        .identifyLanguage(text)
        .timeout(const Duration(seconds: 20));
    await identifier.close();

    // ② 实体提取：仅当识别到的语言受 EntityExtractor 支持才跑；否则跳过（只给语言）。
    final entities = <String>[];
    if (code != 'und') {
      final lang = _toExtractorLang(code);
      if (lang != null) {
        final extractor = EntityExtractor(language: lang);
        try {
          final annotations = await extractor
              .annotateText(text)
              .timeout(const Duration(seconds: 20));
          for (final a in annotations) {
            for (final e in a.entities) {
              if (e.type == EntityType.unknown) continue;
              entities.add('${e.type.name}:${e.rawValue}');
            }
          }
        } finally {
          await extractor.close();
        }
      }
    }
    return TextAnalysisRaw(
      languageCode: code == 'und' ? null : code,
      entities: entities,
    );
  }

  /// 后置归一化：原始结果 → 统一 [ReconstructResult]（facets / note 同口径）。
  @override
  ReconstructResult normalize(Object? raw, ReconstructInput input) {
    final r = raw as TextAnalysisRaw;
    final humanMd = input.rawContent ?? '';
    if (r.noText) {
      return ReconstructResult(humanMd: humanMd, note: '笔记为空，无文本可分析');
    }
    final langName = r.languageCode == null ? '未知' : _langNameZh(r.languageCode!);
    final facets = <String, List<String>>{'语言': [langName]};
    if (r.entities.isNotEmpty) {
      facets['实体'] = r.entities;
      return ReconstructResult(
        humanMd: humanMd,
        facets: facets,
        note: '已识别语言：$langName，提取 ${r.entities.length} 个实体',
      );
    }
    return ReconstructResult(
      humanMd: humanMd,
      facets: facets,
      note: '已识别语言：$langName（未提取到结构化实体）',
    );
  }
}

/// BCP-47（取主码，忽略 - 后的地区）→ [EntityExtractorLanguage]；不支持返回 null。
EntityExtractorLanguage? _toExtractorLang(String bcp47) {
  final base = bcp47.split('-').first.toLowerCase();
  return const {
    'zh': EntityExtractorLanguage.chinese,
    'en': EntityExtractorLanguage.english,
    'ja': EntityExtractorLanguage.japanese,
    'ko': EntityExtractorLanguage.korean,
    'fr': EntityExtractorLanguage.french,
    'de': EntityExtractorLanguage.german,
    'it': EntityExtractorLanguage.italian,
    'es': EntityExtractorLanguage.spanish,
    'pt': EntityExtractorLanguage.portuguese,
    'ru': EntityExtractorLanguage.russian,
    'nl': EntityExtractorLanguage.dutch,
    'pl': EntityExtractorLanguage.polish,
    'th': EntityExtractorLanguage.thai,
    'tr': EntityExtractorLanguage.turkish,
    'ar': EntityExtractorLanguage.arabic,
  }[base];
}

/// BCP-47 → 中文语言名（未命中保留原始码，便于 AI / 人直接读）。
String _langNameZh(String bcp47) {
  final base = bcp47.split('-').first.toLowerCase();
  return const {
    'zh': '中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'fr': '法语',
    'de': '德语',
    'it': '意大利语',
    'es': '西班牙语',
    'pt': '葡萄牙语',
    'ru': '俄语',
    'nl': '荷兰语',
    'pl': '波兰语',
    'th': '泰语',
    'tr': '土耳其语',
    'ar': '阿拉伯语',
    'und': '未知',
  }[base] ?? bcp47;
}

/// [run] 的原始输出：语言码（BCP-47 或 null）+ 实体列表（[类型:值]）+ 无文本标记。
class TextAnalysisRaw {
  const TextAnalysisRaw({this.languageCode, this.entities = const [], this.noText = false});

  final String? languageCode;
  final List<String> entities;
  final bool noText;
}
