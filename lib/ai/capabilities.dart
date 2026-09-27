import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_api_availability/google_api_availability.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// AI 能力开关与本机能力检测（2026-09-27 决策：设置页开关 + 首次检测持久化）。
///
/// - 开关（图片 OCR / 录音端侧转写）：默认开启，用户可关；
/// - 能力检测：**首次触发后结果持久化，此后不再检测**（用户拍板）；
/// - 无能力时设置页小字提示，开关置灰；有能力则默认开启。
class AiCapabilities extends ChangeNotifier {
  static const _prefOcrEnabled = 'ai_ocr_enabled';
  static const _prefSttEnabled = 'ai_stt_enabled';
  static const _prefDetected = 'ai_capability_detected';
  static const _prefOcrAvailable = 'ai_ocr_available';
  static const _prefSttAvailable = 'ai_stt_available';

  bool ocrEnabled = true; // 用户开关
  bool sttEnabled = true;
  bool? ocrAvailable; // 本机检测结果（null = 尚未检测）
  bool? sttAvailable;
  bool _detected = false;

  /// 是否已完成过首次检测（含从持久化恢复）。
  bool get detected => _detected;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    ocrEnabled = prefs.getBool(_prefOcrEnabled) ?? true;
    sttEnabled = prefs.getBool(_prefSttEnabled) ?? true;
    _detected = prefs.getBool(_prefDetected) ?? false;
    if (_detected) {
      // 首次检测后结果持久化，此后不再检测
      ocrAvailable = prefs.getBool(_prefOcrAvailable);
      sttAvailable = prefs.getBool(_prefSttAvailable);
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
    await _detectStt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefDetected, true);
    await prefs.setBool(_prefOcrAvailable, ocrAvailable ?? false);
    await prefs.setBool(_prefSttAvailable, sttAvailable ?? false);
    _detected = true;
    notifyListeners();
  }

  Future<void> _detectOcr() async {
    try {
      if (!Platform.isAndroid) {
        // iOS 的 ML Kit 模型内置打包，不依赖 GMS
        ocrAvailable = true;
        return;
      }
      final availability =
          await GoogleApiAvailability.instance.checkGooglePlayServicesAvailability();
      ocrAvailable = availability == GooglePlayServicesAvailability.success;
    } catch (e) {
      debugPrint('[AiCapabilities] OCR detection failed: $e');
      ocrAvailable = false;
    }
  }

  Future<void> _detectStt() async {
    try {
      final stt = SpeechToText();
      sttAvailable = await stt.initialize();
    } catch (e) {
      debugPrint('[AiCapabilities] STT detection failed: $e');
      sttAvailable = false;
    }
  }

  Future<void> setOcrEnabled(bool v) async {
    ocrEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefOcrEnabled, v);
    notifyListeners();
  }

  Future<void> setSttEnabled(bool v) async {
    sttEnabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefSttEnabled, v);
    notifyListeners();
  }
}
