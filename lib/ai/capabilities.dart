import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI 能力开关与本机能力检测（2026-09-27 决策：设置页开关 + 首次检测持久化）。
///
/// - 开关（图片 OCR）：默认开启，用户可关；
/// - 能力检测：**首次触发后结果持久化，此后不再检测**（用户拍板）；
/// - 无能力时设置页小字提示，开关置灰；有能力则默认开启。
class AiCapabilities extends ChangeNotifier {
  static const _prefOcrEnabled = 'ai_ocr_enabled';
  static const _prefUrlFetchEnabled = 'ai_url_fetch_enabled';
  static const _prefAsrEnabled = 'ai_asr_enabled';
  static const _prefDetected = 'ai_capability_detected';
  static const _prefOcrAvailable = 'ai_ocr_available';

  bool ocrEnabled = true; // 用户开关
  bool urlFetchEnabled = true; // 链接离线抓取网页正文（无设备能力依赖，不需要检测）
  bool asrEnabled = true; // 录音/音频端侧转写（Sherpa 离线，无 GMS 依赖）
  bool? ocrAvailable; // 本机检测结果（null = 尚未检测）
  bool _detected = false;

  /// 是否已完成过首次检测（含从持久化恢复）。
  bool get detected => _detected;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    ocrEnabled = prefs.getBool(_prefOcrEnabled) ?? true;
    urlFetchEnabled = prefs.getBool(_prefUrlFetchEnabled) ?? true;
    asrEnabled = prefs.getBool(_prefAsrEnabled) ?? true;
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
}
