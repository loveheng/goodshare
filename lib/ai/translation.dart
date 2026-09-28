import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'language_codes.dart';
import 'subtitle.dart';

/// 端侧文本翻译层（2026-09-28，设计见 docs/design/asr-subtitle.md §8）。
///
/// 作用域是**文本层**——拿到 cue 文本或条目正文之后才介入，与 ASR / OCR 完全解耦，
/// 因此没有 VAD、没有下载模型能力时同样可挂载（只是恒走 Noop，保留原文）。
///
/// 本期（骨架期）引擎实现只有两个：
/// - `MlKitTranslationEngine`：Android + GMS + 语言包已下载（iOS 系统框架属后续）；
/// - `NoopTranslationEngine`：全平台兜底，返回原文，**保证翻译永不卡死队列**。
/// 真离线自托管模型（OPUS-MT）按同一接口后续插拔，届时只需加一个实现并注册进路由。

export 'language_codes.dart';

/// 端侧翻译引擎接口（设计 §8 契约）。
abstract class TranslationEngine {
  /// 实现名（日志 / 设置页展示）。
  String get name;

  /// 平台与前置门禁：平台是否支持、GMS 是否可用、**语言包是否已下载**。
  Future<bool> get isAvailable;

  /// 不可用时给人类看的原因（设置页小字）；可用时为 null。
  String? get unavailableReason;

  /// 支持的目标语言集合（BCP-47）；引擎在 [isAvailable] 为 false 时可以返回空集。
  Future<Set<String>> supportedTargets();

  /// 翻译单句。返回 null = **未产出译文**（不可用 / 无需翻译），调用方保留原文，
  /// 不视为错误——翻译是增强，不是主链路。
  Future<String?> translate(String text, {required String from, required String to});
}

/// 兜底实现：恒不产出译文，调用方保留原文。
///
/// 存在的意义是「翻译永不卡死队列」——无论平台、语言包、模型处于什么状态，
/// 翻译层总能解析出一个实现，产物退化为原文而非死信（与 §8 降级条款一致）。
class NoopTranslationEngine implements TranslationEngine {
  const NoopTranslationEngine();

  @override
  String get name => '未启用翻译';

  @override
  Future<bool> get isAvailable async => true;

  @override
  String? get unavailableReason => '当前无可用的端侧翻译引擎，产物保留原文';

  @override
  Future<Set<String>> supportedTargets() async => kTargetLanguages.toSet();

  @override
  Future<String?> translate(String text, {required String from, required String to}) async => null;
}

/// 句子级切分：MT API 均有输入长度上限，须按中英标点拆句逐句翻译，再按序回填，
/// 不得整段直灌（设计 §8 必处理项）。
///
/// 切分保留终结符与换行归属各自句子；[maxChars] 为硬切上限，防止无标点的超长串
/// （如整段英文无句号）一次性灌进引擎。
List<String> splitSentences(String text, {int maxChars = 500}) {
  const terminators = {'。', '！', '？', '.', '!', '?', '；', ';', '…'};
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    final s = buf.toString();
    buf.clear();
    if (s.trim().isNotEmpty) out.add(s);
  }

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    buf.write(ch);
    if (ch == '\n' || terminators.contains(ch) || buf.length >= maxChars) flush();
  }
  flush();
  return out;
}

/// 源语言判定（BCP-47）。
///
/// DEGRADE: 未接 ML Kit Language ID——它与翻译语言包同走 Play 动态下发，
/// 国内同样不可达（asr-subtitle §8 已拍板不引入额外在线依赖）。这里用字符分布
/// 启发式判源语：判错时译文质量下降，但**不会卡死或产生死信**（失败即保留原文）。
/// 接语言识别能力后应替换本函数（接口不变）。
String detectSourceLanguage(String text) {
  var latin = 0;
  var cjk = 0;
  var kana = 0;
  var hangul = 0;
  var cyrillic = 0;
  for (final rune in text.runes) {
    if (rune >= 0x3040 && rune <= 0x30FF) {
      kana++;
    } else if (rune >= 0xAC00 && rune <= 0xD7AF) {
      hangul++;
    } else if (rune >= 0x4E00 && rune <= 0x9FFF) {
      cjk++;
    } else if (rune >= 0x0400 && rune <= 0x04FF) {
      cyrillic++;
    } else if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    }
  }
  // 假名优先于汉字：含假名即判日语（日语文本必然夹带假名，中文不会）
  if (kana > 0 && kana >= cjk ~/ 4) return 'ja';
  if (hangul > 0) return 'ko';
  if (cyrillic > 0 && cyrillic >= latin) return 'ru';
  if (cjk > 0 && cjk >= latin) return 'zh';
  return 'en';
}

/// 整段翻译：逐句翻译后按原顺序以换行回填。
///
/// 单句失败或引擎无产出 → **该句保留原文**（不抛、不重入队），整篇退化为原文产物，
/// 符合「占位不卡死」（§2）与「翻译失败不重入队」（§10 已确认）。
Future<String> translateParagraph(
  TranslationEngine engine,
  String text, {
  required String from,
  required String to,
}) async {
  final sentences = splitSentences(text);
  if (sentences.isEmpty) return text;
  final out = <String>[];
  for (final s in sentences) {
    final t = s.trim();
    if (t.isEmpty) {
      out.add(s);
      continue;
    }
    try {
      final r = await engine.translate(t, from: from, to: to);
      out.add((r == null || r.trim().isEmpty) ? t : r.trim());
    } catch (e) {
      // DEGRADE: 单句失败保留原文——翻译是增强层，不该让一句拖垮整篇。
      // 至少留日志：翻译失败属「有动作无结果」，按 R1 不应完全无声（2026-09-28）。
      debugPrint('[Translation] sentence translate failed, kept original: $e');
      out.add(t);
    }
  }
  return out.join('\n');
}

/// 译文文件存取：`documents/translations/{itemId}.{lang}.md`（与字幕 documents/subtitles
/// 同层的 app 私有目录）。
///
/// 译文平时随条目存库（详情页有卡片、MCP 可读）；导出成文件是**按需动作**——
/// 用户要拿去用（发给别人 / 存进笔记）时才落盘，不为每条翻译都造文件。
class TranslationStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'translations'));
    await d.create(recursive: true);
    return d;
  }

  static Future<File> fileFor(String itemId, String lang) async =>
      File(p.join((await _dir()).path, '$itemId.$lang.md'));

  /// 写译文文件并返回路径（导出 / 分享入口）。
  static Future<String> save(String itemId, String lang, String text) async {
    final f = await fileFor(itemId, lang);
    await f.writeAsString(text, flush: true);
    debugPrint('[Translation] exported -> ${f.path}');
    return f.path;
  }
}

/// 运行期路由：按可用性取第一个可用实现，全不可用则落 Noop（设计 §8 流程图）。
class TranslationRouter {
  TranslationRouter(this._engines);

  final List<TranslationEngine> _engines;
  TranslationEngine? _resolved;

  /// 解析当前可用引擎；结果**不缓存到永久**——首次解析后复用同一实例，
  /// 语言包下载状态变化时由调用方 [reset] 后重新解析。
  Future<TranslationEngine> resolve() async {
    final cached = _resolved;
    if (cached != null) return cached;
    for (final e in _engines) {
      if (await e.isAvailable) return _resolved = e;
    }
    return _resolved = const NoopTranslationEngine();
  }

  /// 语言包下载 / 目标语言变更后丢弃缓存结果。
  void reset() => _resolved = null;

  /// 当前不可用原因（设置页小字）；可用时为 null。
  Future<String?> unavailableReason() async {
    final e = await resolve();
    return e is NoopTranslationEngine ? e.unavailableReason : null;
  }

  Future<String?> translate(String text, {required String from, required String to}) async {
    final engine = await resolve();
    final r = await engine.translate(text, from: from, to: to);
    return (r == null || r.trim().isEmpty) ? null : r.trim();
  }
}

/// 翻译层对外服务：把「路由 + 设置」绑成一个入口，供字幕管线与文本条目管线共用。
///
/// 三条口径：
/// - 关闭 / 不可用 → 返回原文产物（null 译文），**永不置死信**；
/// - 源语言 == 目标语言 → 视为无需翻译（返回 null），不浪费引擎调用；
/// - 单句失败保留原文，整篇失败退化为原文（不重入队）。
class TranslationService {
  TranslationService({
    required this.router,
    required this.isEnabled,
    required this.targetLang,
  });

  final TranslationRouter router;

  /// 翻译开关（设置项）；null = 恒允许。
  final bool Function()? isEnabled;

  /// 当前目标语言（BCP-47）。
  final String Function() targetLang;

  /// 翻译一段文本。返回 null 表示「没有译文」，调用方保留原文。
  ///
  /// [target] 为任务级目标语言覆盖（MCP / UI 单次指定）；为空则用设置项目标语言。
  Future<String?> translateText(String text, {String? target}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (isEnabled?.call() == false) return null;
    final to = target ?? targetLang();
    if (!isSupportedTarget(to)) return null;
    final from = detectSourceLanguage(t);
    if (from == to) return null;
    return translateParagraph(await router.resolve(), t, from: from, to: to);
  }

  /// 逐条 cue 翻译：返回带 [AsrCue.translation] 的新列表。
  /// 任一条失败不影响其它条；整体不可用时返回原文（translation 全为 null）。
  Future<List<AsrCue>> translateCues(List<AsrCue> cues) async {
    if (cues.isEmpty || isEnabled?.call() == false) return cues;
    final to = targetLang();
    if (!isSupportedTarget(to)) return cues;
    final engine = await router.resolve();
    final out = <AsrCue>[];
    for (final c in cues) {
      final t = c.text.trim();
      if (t.isEmpty) {
        out.add(c);
        continue;
      }
      final from = detectSourceLanguage(t);
      if (from == to) {
        out.add(c);
        continue;
      }
      String? tr;
      try {
        tr = await engine.translate(t, from: from, to: to);
      } catch (e) {
        // DEGRADE: 单条失败保留原文。至少留日志（R1：有动作无结果不应无声）。
        debugPrint('[Translation] cue translate failed, kept original: $e');
        tr = null;
      }
      out.add(AsrCue(
        start: c.start,
        duration: c.duration,
        text: c.text,
        translation: (tr == null || tr.trim().isEmpty) ? null : tr.trim(),
      ));
    }
    return out;
  }
}
