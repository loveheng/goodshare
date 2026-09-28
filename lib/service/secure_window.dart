import 'package:flutter/services.dart';

/// Android 动态 `FLAG_SECURE` 管控（防截屏 / 录屏 + 多任务卡片偷窥）。
///
/// 仅在 Vault 敏感内容可见时开启，普通页面（Inbox / Timeline 等）保持可截图分享；
/// 进入 VaultPage 或 vaultContext 详情页 `setSecure(true)`，离开 / dispose 时 `setSecure(false)`。
/// iOS 无等价公开 API，调用为 no-op（不影响运行）。
class SecureWindow {
  static const _channel = MethodChannel('goodshare/secure_window');

  static Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', secure);
    } on PlatformException {
      // 平台不支持时静默忽略（如 iOS / 桌面）
    }
  }
}
