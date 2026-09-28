import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../app/lifecycle_manager.dart';

/// 隐私遮罩：监听 [AppLifecycleManager]，当 App 进入 `paused` / `detached` /
/// `hidden`（真正退后台 / 锁屏 / 被系统隐藏）时全屏高斯模糊 + 加锁图标，防护
/// iOS / Android 多任务卡片对当前屏幕的自动快照偷窥；回到 `resumed` 瞬间移除。
///
/// 关键：`inactive` 完全忽略。Android 在启动动画、通知栏下拉、多窗切换时频繁
/// 发出 `inactive` 且不补 `resumed`——据此置黑会启动即永久黑屏，据此解黑又会在
/// 真正后台时泄漏隐私。系统快照发生在 paused/hidden，忽略 inactive 两全其美。
///
/// 挂于 `MaterialApp.builder` 最外层，覆盖所有路由（含 BottomSheet）。
class PrivacyBlurOverlay extends StatefulWidget {
  const PrivacyBlurOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<PrivacyBlurOverlay> createState() => _PrivacyBlurOverlayState();
}

class _PrivacyBlurOverlayState extends State<PrivacyBlurOverlay> {
  bool _blurred = false;
  late final StreamSubscription<AppLifecycleState> _sub;

  // 真正退后台的状态：paused / detached / hidden。系统对多任务卡片的快照发生在
  // 这些状态，故仅据此置黑即可保护隐私。
  static const Set<AppLifecycleState> _backgroundStates = {
    AppLifecycleState.paused,
    AppLifecycleState.detached,
    AppLifecycleState.hidden,
  };

  bool _isBackground(AppLifecycleState? s) =>
      s != null && _backgroundStates.contains(s);

  @override
  void initState() {
    super.initState();
    // 用当前真实生命周期初始化（部分机型首帧已为 resumed，避免漏掉启动期首个状态）。
    _blurred = _isBackground(WidgetsBinding.instance.lifecycleState);
    _sub = AppLifecycleManager.instance.states.listen(_onState);
    // 启动期安全网：极少数机型会在首帧发出一次 paused 且不再补 resumed，
    // 导致遮罩永久置黑。首帧后与 ~600ms 后各用权威 lifecycleState 校正一次，
    // 仅当应用确实回到前台（resumed）时才解除模糊。
    WidgetsBinding.instance.addPostFrameCallback((_) => _resync());
    Timer(const Duration(milliseconds: 600), _resync);
  }

  void _onState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      // 回到前台：无条件解除模糊
      if (_blurred && mounted) setState(() => _blurred = false);
    } else if (_isBackground(s)) {
      // 真正退后台：置黑
      if (!_blurred && mounted) setState(() => _blurred = true);
    }
    // inactive：完全忽略——Android 在启动动画 / 通知栏下拉 / 多窗切换时频繁发出，
    // 且不补 resumed；据此置黑会启动即永久黑屏，据此解黑又会在真正后台时泄隐私。
  }

  void _resync() {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        _blurred &&
        mounted) {
      setState(() => _blurred = false);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_blurred)
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.5),
                child: Center(
                  child: Icon(
                    Icons.lock_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
