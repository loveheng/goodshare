import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subtitle.dart';
import 'translation.dart';
import 'translation_mlkit.dart';

/// AI 能力开关与本机能力检测（2026-09-27 决策：设置页开关 + 首次检测持久化）。
///
/// - 开关（图片 OCR）：默认开启，用户可关；
/// - 能力检测：**首次触发后结果持久化，此后不再检测**（用户拍板）；
/// - 无能力时设置页小字提示，开关置灰；有能力则默认开启。
///
/// 翻译（2026-09-28）**不走一次性持久化**：它的可用性取决于语言包下载状态，
/// 用户随时可能下载成功，把 false 永久锁死会重演 OCR 早期误判的坑
/// （见 [load] 里对 ocrAvailable 的纠正）。故每次进入设置页实时查询。
class AiCapabilities extends ChangeNotifier {
  static const _prefOcrEnabled = 'ai_ocr_enabled';
  static const _prefUrlFetchEnabled = 'ai_url_fetch_enabled';
  static const _prefAsrEnabled = 'ai_asr_enabled';
  static const _prefDetected = 'ai_capability_detected';
  static const _prefOcrAvailable = 'ai_ocr_available';
  static const _prefTranslationEnabled = 'ai_translation_enabled';
  static const _prefTargetLang = 'ai_translation_target';
  static const _prefSubtitleMode = 'ai_subtitle_mode';

  bool ocrEnabled = true; // 用户开关
  bool urlFetchEnabled = true; // 链接离线抓取网页正文（无设备能力依赖，不需要检测）
  bool asrEnabled = true; // 录音/音频端侧转写（Sherpa 离线，无 GMS 依赖）
  bool? ocrAvailable; // 本机检测结果（null = 尚未检测）

  // ───────── 翻译（2026-09-28） ─────────
  bool translationEnabled = true; // 用户开关（引擎不可用时设置页置灰并说明原因）
  String targetLang = 'zh'; // 目标语言（BCP-47）
  SubtitleMode subtitleMode = SubtitleMode.bilingual; // 字幕译文模式
  bool? translationAvailable; // 实时查询结果（null = 尚未查询）

  /// 翻译引擎路由（main 装配注入）；null = 未接入翻译层。
  TranslationRouter? router;

  /// ML Kit 引擎实例（语言包下载/查询入口）；null = 无该引擎。
  MlKitTranslationEngine? engine;

  bool _detected = false;

  /// 是否已完成过首次检测（含从持久化恢复）。
  bool get detected => _detected;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    ocrEnabled = prefs.getBool(_prefOcrEnabled) ?? true;
    urlFetchEnabled = prefs.getBool(_prefUrlFetchEnabled) ?? true;
    asrEnabled = prefs.getBool(_prefAsrEnabled) ?? true;
    translationEnabled = prefs.getBool(_prefTranslationEnabled) ?? true;
    targetLang = prefs.getString(_prefTargetLang) ?? 'zh';
    if (!isSupportedTarget(targetLang)) targetLang = 'zh'; // 历史脏值兜底
    subtitleMode = SubtitleMode.values.firstWhere(
      (m) => m.name == prefs.getString(_prefSubtitleMode),
      orElse: () => SubtitleMode.bilingual,
    );
    _detected = prefs.getBool(_prefDetected) ?? false;
    if (_detected) {
      // OCR 已切换为 bundled 离线库，本机恒可用（不再依赖 GMS）。
      // 忽略旧持久化结果，避免早期在无 GMS 设备误判的 false 永久锁死开关。
      ocrAvailable = true;
    }
    notifyListeners();
  }

  /// 首次调用执行检测并持久化；之后调用直接返回（幂等）。
  Future<void> ensureDetected() async {
    if (_detected) return;
    await detect();
  }

  /// 执行本机能力检测并持久化结果。
  Future<void> detect() async {
    await _detectOcr();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefDetected, true);
    await prefs.setBool(_prefOcrAvailable, ocrAvailable ?? false);
    _detected = true;
    notifyListeners();
  }

  Future<void> _detectOcr() async {
    // 已切换为 bundled 中文识别库（com.google.mlkit:text-recognition-chinese），
    // 模型随 APK 打包，不依赖 GMS / Play 动态下载，故本机恒可用（含国内无 GMS 设备）。
    // 不再做 GoogleApiAvailability 检测，避免无 GMS 机型被误关 OCR。
    ocrAvailable = true;
  }

  Future<void> setOcrEnabled(bool v) async {
    ocrEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefOcrEnabled, v);
    notifyListeners();
  }

  Future<void> setUrlFetchEnabled(bool v) async {
    urlFetchEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefUrlFetchEnabled, v);
    notifyListeners();
  }

  Future<void> setAsrEnabled(bool v) async {
    asrEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAsrEnabled, v);
    notifyListeners();
  }

  // ───────── 翻译设置 ─────────

  /// 实时查询翻译引擎可用性（语言包就绪才算可用，见 [MlKitTranslationEngine]）。
  Future<bool> checkTranslationAvailable() async {
    final r = router;
    if (r == null) {
      translationAvailable = false;
      notifyListeners();
      return false;
    }
    final e = await r.resolve();
    translationAvailable = e is! NoopTranslationEngine;
    notifyListeners();
    return translationAvailable!;
  }

  /// 不可用原因（设置页小字）；可用时为 null。
  Future<String?> translationUnavailableReason() async {
    final r = router;
    if (r == null) return '翻译层未接入';
    return r.unavailableReason();
  }

  /// 下载目标语言包（设置页入口）。完成后丢弃路由缓存，让新状态立即生效。
  Future<bool> downloadLanguagePack([String? lang]) async {
    final eng = engine;
    if (eng == null) return false;
    final ok = await eng.downloadLanguage(lang ?? targetLang);
    router?.reset();
    await checkTranslationAvailable();
    return ok;
  }

  Future<void> setTranslationEnabled(bool v) async {
    translationEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefTranslationEnabled, v);
    notifyListeners();
  }

  Future<void> setTargetLang(String v) async {
    if (!isSupportedTarget(v)) return;
    targetLang = v;
    router?.reset(); // 语言包就绪状态随语言变化，缓存结果作废
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTargetLang, v);
    await checkTranslationAvailable();
  }

  Future<void> setSubtitleMode(SubtitleMode v) async {
    subtitleMode = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSubtitleMode, v.name);
    notifyListeners();
  }
}
