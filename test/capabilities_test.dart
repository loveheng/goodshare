import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/capabilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI 能力开关与一次性检测持久化契约单测（2026-09-27 决策）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认开关为开，检测结果默认未知', () async {
    final caps = AiCapabilities();
    await caps.load();
    expect(caps.ocrEnabled, isTrue);
    expect(caps.urlFetchEnabled, isTrue);
    expect(caps.ocrAvailable, isNull);
    expect(caps.detected, isFalse);
  });

  test('首次 ensureDetected 执行检测并持久化；之后幂等不再检测', () async {
    // VM 环境（非 Android 宿主）：OCR 按 bundled 语义判定为可用
    final caps = AiCapabilities();
    await caps.load();
    await caps.ensureDetected();
    expect(caps.detected, isTrue);
    expect(caps.ocrAvailable, isTrue, reason: '非 Android 平台 OCR 不依赖 GMS');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ai_capability_detected'), isTrue);
    expect(prefs.getBool('ai_ocr_available'), isTrue);

    // 新实例从持久化恢复结果（模拟下次启动），不再触发检测
    final caps2 = AiCapabilities();
    await caps2.load();
    expect(caps2.detected, isTrue);
    expect(caps2.ocrAvailable, isTrue);
    await caps2.ensureDetected(); // 幂等：不应重新检测（无断言爆炸即通过）
  });

  test('开关切换持久化', () async {
    final caps = AiCapabilities();
    await caps.load();
    await caps.setOcrEnabled(false);

    final caps2 = AiCapabilities();
    await caps2.load();
    expect(caps2.ocrEnabled, isFalse);
  });
}
