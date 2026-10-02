import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'llm_model.dart';

/// 端侧 LLM 引擎接口（2026-09-28，设计见 docs/design/on-device-llm.md）。
///
/// 双端分治：Android = LiteRT-LM Kotlin（Stable）+ SoC 感知模型包；
/// iOS = FoundationModels 系统模型（零下载）。两端实现各自独立，
/// 本层只约定 Dart 侧契约——与 `TranslationEngine` 同一接口化模式。
///
/// 三条口径（与翻译层一致）：
/// - `isAvailable` **动态探测、不做一次性持久化**（模型包状态动态，防 OCR 误判锁死的坑）；
/// - 生成失败不抛给队列——返回 null 交给调用方走「占位完成 + 可观测反馈」；
/// - 引擎不可用时上层不应入队（入队前预检）。
abstract class OnDeviceLlmEngine {
  /// 实现名（日志 / 设置页展示）。
  String get name;

  /// 引擎可用性：Android = 模型包已下载且引擎可初始化；iOS = Apple Intelligence 门控。
  Future<bool> get isAvailable;

  /// 不可用时给人类看的原因（设置页小字）；可用时为 null。
  ///
  /// 同步兜底文案——真实原因走 [unavailableReasonAsync]（异步探测）。
  String? get unavailableReason;

  /// 异步取真实原因（R1：任务 note 必须携带真值，否则 AI/用户被「未下载模型」
  /// 兜底文案误导——实测模型在机仍报不可用，真因在 init/生成阶段却不可见）。
  /// 默认回退到同步值；原生桥实现（ChannelLlmEngine）向原生取真值。
  Future<String?> unavailableReasonAsync() async => unavailableReason;

  /// 文本生成。失败 / 不可用 / 空产出返回 null（不抛，翻译式降级）。
  ///
  /// [system] 为任务指令（摘要/关键词等由调用方组装）；[maxTokens] 限制输出长度。
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512});
}

/// MethodChannel 桥实现：Android/iOS 各自的原生 handler 提供同名协议
/// （`goodshare/llm`：`isAvailable` / `unavailableReason` / `generate` / `socModel`）。
///
/// 原生侧不可用（如 LiteRT-LM 依赖缺失、老 iOS）时 MethodChannel 抛
/// MissingPluginException —— 统一落 [UnavailableLlmEngine] 语义（isAvailable=false），
/// 绝不让异常穿透到队列。
class ChannelLlmEngine implements OnDeviceLlmEngine {
  ChannelLlmEngine({this.channel = const MethodChannel('goodshare/llm')});

  final MethodChannel channel;

  @override
  String get name => '端侧大模型';

  @override
  Future<bool> get isAvailable async {
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[LlmEngine] isAvailable failed: ${e.code}');
      return false;
    }
  }

  @override
  String? get unavailableReason {
    // 同步 getter 拿不到异步结果；原生侧把原因并入 isAvailable 的返回负载，
    // 此处仅给桥层兜底文案（设置页会用 [unavailableReasonAsync] 取真值）。
    return '端侧大模型引擎不可用（未下载模型或系统不支持）';
  }

  /// 异步取真值原因（设置页 / 任务 note 用）；原生侧未实现时返回兜底文案。
  @override
  Future<String?> unavailableReasonAsync() async {
    try {
      return await channel.invokeMethod<String>('unavailableReason') ?? unavailableReason;
    } on MissingPluginException {
      return '当前平台无端侧大模型引擎';
    } on PlatformException catch (e) {
      return e.message ?? unavailableReason;
    }
  }

  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async {
    try {
      final r = await channel.invokeMethod<String>('generate', {
        'prompt': prompt,
        'system': ?system,
        'max_tokens': maxTokens,
      });
      final t = r?.trim();
      return (t == null || t.isEmpty) ? null : t;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[LlmEngine] generate failed: ${e.code}');
      return null;
    }
  }

  /// 设备 SoC 型号（`ro.soc.model`，原生回传）；非 Android / 读取失败为 null。
  /// 用于 NPU 专包的「本机可见性」判定（设计 §3.1 SoC 感知）。
  Future<String?> socModel() async {
    try {
      return await channel.invokeMethod<String>('socModel');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// 兜底实现：恒不可用（测试 / 无原生桥平台）。
class UnavailableLlmEngine implements OnDeviceLlmEngine {
  const UnavailableLlmEngine(this.reason);

  final String reason;

  @override
  String get name => '端侧大模型（不可用）';

  @override
  Future<bool> get isAvailable async => false;

  @override
  String? get unavailableReason => reason;

  @override
  Future<String?> unavailableReasonAsync() async => reason;

  @override
  Future<String?> generate(String prompt, {String? system, int maxTokens = 512}) async => null;
}

/// NPU 专包对本机是否可见（SoC 感知；设计 §3.1）。
/// [soc] 为原生回传的 `ro.soc.model`；null（非 Android / 未知）→ 仅通用包可见。
bool llmModelVisibleOnDevice(LlmModel m, String? soc) =>
    m.socModel == null || (soc != null && soc.toUpperCase() == m.socModel!.toUpperCase());
