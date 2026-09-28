import Flutter
import UIKit
import Foundation

/// 端侧 LLM MethodChannel 桥 — iOS 侧（2026-09-28，设计见 docs/design/on-device-llm.md）。
///
/// iOS 策略与 Android 分治：**FoundationModels framework（iOS 26+）调系统内置
/// ~3B 模型，零下载零模型管理**。桥层只做三件事：
/// ① 可用性探测（系统版本 + FoundationModels availability 门控）；
/// ② LanguageModelSession 调用（MVP 先占位，待 FoundationModels 真机接入）；
/// ③ 错误统一 PlatformException 回传，Dart 侧降级为 null，不卡队列。
///
/// 协议（channel: goodshare/llm，与 Android LlmBridge 同一套四方法）：
/// - isAvailable        → Bool
/// - unavailableReason  → String?
/// - generate(prompt, system?, max_tokens) → String?
/// - socModel           → String?（iOS 无 SoC 型号语义，恒 nil）
enum LlmBridge {
    static func register(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "goodshare/llm", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "socModel":
                result(nil)
            case "isAvailable":
                result(LLMAvailability.isAvailable)
            case "unavailableReason":
                result(LLMAvailability.unavailableReason)
            case "generate":
                // TODO(foundationmodels): iOS 26+ LanguageModelSession 接入。
                // FoundationModels 需 iOS 26 SDK 编译 + 真机可用性门控；未接入前
                // 恒回不可用，Dart 侧走占位完成（与「降级不卡死」口径一致）。
                result(FlutterError(code: "llm_unavailable",
                                    message: "FoundationModels 尚未接入",
                                    details: nil))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

/// FoundationModels 可用性门控（纯系统版本判定；framework 接入后补 availability 细分）。
private enum LLMAvailability {
    /// iOS 26.0 = FoundationModels 首发版本。
    private static let foundationModelsMinVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    static var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(foundationModelsMinVersion)
    }

    static var unavailableReason: String? {
        isAvailable ? nil : "需要 iOS 26+ 且设备支持 Apple Intelligence（系统设置中开启）"
    }
}
