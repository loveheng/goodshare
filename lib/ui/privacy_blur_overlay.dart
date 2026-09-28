import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../app/lifecycle_manager.dart';

/// 隐私遮罩：监听 [AppLifecycleManager]，当 App 进入 `inactive` / `paused`
/// （退后台 / 锁屏）时全屏高斯模糊 + 加锁图标，防护 iOS / Android 多任务卡片
/// 对当前屏幕的自动快照偷窥；回到 `resumed` 瞬间移除，体验平滑。
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

  @override
  void initState() {
    super.initState();
    _sub = AppLifecycleManager.instance.states.listen((s) {
      final should = s == AppLifecycleState.paused || s == AppLifecycleState.inactive;
      if (should != _blurred && mounted) setState(() => _blurred = should);
    });
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
