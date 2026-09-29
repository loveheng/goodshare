import 'package:flutter/services.dart';

/// Android 动态 `FLAG_SECURE` 管控（防截屏 / 录屏 + 多任务卡片偷窥）。
///
/// 仅当「保险箱」相关内容真正可见时才开启；普通页面（全部 / 时光机 / AI 分类 / 设置）
/// 保持可截图分享。两种「占用源」独立标记，任一为真即开启，全部归零才关闭：
///   - [setVaultTabVisible]：底部 5 tab 切到「保险箱」页（HomeShell 在切换 tab 时调用）。
///   - [enterVaultDetail] / [exitVaultDetail]：从保险箱进入的 vaultContext 详情页（叠加在
///     保险箱 tab 之上，其 dispose 不会把整窗的安全态提前解除）。
///
/// 为什么不能由 VaultPage 生命周期驱动：主页用 `IndexedStack` 常驻挂载全部 tab，
/// VaultPage 的 initState 在应用启动即触发——那样 FLAG_SECURE 一启动就全局开启、
/// 永不清除，等价于「银行级、处处不可截图」。故改为按当前 tab 索引切换。
///
/// iOS 无等价公开 API，调用为 no-op（不影响运行）。
class SecureWindow {
  static const _channel = MethodChannel('goodshare/secure_window');

  /// 保险箱 tab 是否处于可见（选中）状态。
  static bool _tabSecure = false;

  /// 叠加在保险箱 tab 之上的 vault 详情页层数（理论上 0 或 1，用计数防重入）。
  static int _detailDepth = 0;

  /// 最近一次实际下发给 native 的状态，避免重复跨通道调用。
  static bool _applied = false;

  /// 主页切到「保险箱」tab 时传 true，切走时传 false。
  static Future<void> setVaultTabVisible(bool visible) async {
    _tabSecure = visible;
    await _apply();
  }

  /// 进入一处 vault 详情页（vaultContext=true）。叠加层数 +1。
  static Future<void> enterVaultDetail() async {
    _detailDepth++;
    await _apply();
  }

  /// 离开一处 vault 详情页。叠加层数 -1，归零不影响 tab 维度的状态。
  static Future<void> exitVaultDetail() async {
    if (_detailDepth > 0) _detailDepth--;
    await _apply();
  }

  static bool get _want => _tabSecure || _detailDepth > 0;

  static Future<void> _apply() async {
    final want = _want;
    if (want == _applied) return;
    _applied = want;
    try {
      await _channel.invokeMethod<void>('setSecure', want);
    } on PlatformException {
      // 平台不支持时静默忽略（如 iOS / 桌面）
    }
  }
}
