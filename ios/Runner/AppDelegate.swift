import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 端侧 LLM 桥（docs/design/on-device-llm.md）：FoundationModels 探测与调用。
    // FlutterAppDelegate 本身是 FlutterPluginRegistry，经 registrar 取 binaryMessenger。
    if let messenger = (self as FlutterPluginRegistry)
      .registrar(forPlugin: "LlmBridge")?
      .messenger() as? FlutterBinaryMessenger {
      LlmBridge.register(messenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
