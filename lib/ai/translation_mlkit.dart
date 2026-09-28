import 'dart:io';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'translation.dart';

/// ML Kit 端侧翻译引擎（Android；设计 §8 平台映射表）。
///
/// 门禁口径：**语言包就绪才算可用**——ML Kit Translate 的语言包经 Google Play
/// 服务动态下发，国内设备即便有 GMS 也大概率下载不到，`isAvailable` 因此把
/// `isModelDownloaded` 纳入判定，未就绪即退化为 Noop（产物保留原文，不静默假装可用）。
///
/// iOS 侧（Apple Translation framework）属后续实现，本引擎在非 Android 平台恒不可用。
class MlKitTranslationEngine implements TranslationEngine {
  MlKitTranslationEngine({required this.targetLang});

  /// 当前目标语言（BCP-47）；由设置项在运行期提供，故为取值函数而非常量。
  final String Function() targetLang;

  final OnDeviceTranslatorModelManager _manager = OnDeviceTranslatorModelManager();

  @override
  String get name => 'ML Kit 端侧翻译';

  /// 是否运行在支持的平台（iOS 系统翻译框架尚未接入）。
  static bool get platformSupported => Platform.isAndroid;

  @override
  Future<bool> get isAvailable async {
    if (!platformSupported) return false;
    final to = targetLang();
    if (!isSupportedTarget(to)) return false;
    return isLanguageDownloaded(to);
  }

  @override
  String? get unavailableReason => platformSupported
      ? '语言包未下载（ML Kit 语言包经 Google Play 下发，国内网络通常不可用）'
      : '当前平台未接入端侧翻译引擎';

  @override
  Future<Set<String>> supportedTargets() async => kTargetLanguages.toSet();

  @override
  Future<String?> translate(String text, {required String from, required String to}) async {
    if (!platformSupported) return null;
    final src = BCP47Code.fromRawValue(from.trim().toLowerCase());
    final dst = BCP47Code.fromRawValue(to.trim().toLowerCase());
    if (src == null || dst == null) return null;
    final translator = OnDeviceTranslator(sourceLanguage: src, targetLanguage: dst);
    try {
      final r = await translator.translateText(text);
      return r.trim().isEmpty ? null : r;
    } catch (e) {
      // DEGRADE: 通道失败（无 GMS / 语言包缺失 / 平台未实现）→ 无译文，保留原文。
      // 翻译是增强层，失败不得阻断字幕与正文产出。
      return null;
    } finally {
      await _safeClose(translator);
    }
  }

  /// 语言包是否已下载（通道异常按未下载处理）。
  Future<bool> isLanguageDownloaded(String bcp) async {
    try {
      return await _manager.isModelDownloaded(bcp);
    } catch (_) {
      return false;
    }
  }

  /// 下载语言包（设置页「下载语言包」入口）。失败返回 false，不抛。
  Future<bool> downloadLanguage(String bcp, {bool isWifiRequired = false}) async {
    try {
      return await _manager.downloadModel(bcp, isWifiRequired: isWifiRequired);
    } catch (_) {
      return false;
    }
  }

  Future<void> _safeClose(OnDeviceTranslator t) async {
    try {
      await t.close();
    } catch (_) {
      // 释放失败不影响结果
    }
  }
}
