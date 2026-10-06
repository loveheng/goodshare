import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// 全局 Toast（2026-10-06 拍板，替代 SnackBar）：
/// **顶部微倒角浮动卡片**——拇指热区在下半屏，成功/信息类提示不该压住
/// 速记条与底部操作条；时长与信息性质解耦（轻确认 1.5s / 状态 3s /
/// 失败驻留），全部可上滑划走（fling 响应，不要求拖过阈值）。
///
/// 规范对齐：
/// - **去胶囊**（2026-10-01 硬约束）：圆角矩形 `Radii.lg`，禁 Stadium；
/// - **装饰不走橘红**：success/info 图标 `onSurfaceVariant`，仅 error 用
///   `colorScheme.error`（语义色非装饰色）；背景 `surfaceContainerHighest`
///   （主题层已覆写暗色三阶浮，无 M3 紫露出）；
/// - **单例替换**（禁叠罗汉）：同档轻提示交叉替换文案重置计时；error
///   升级即时顶替 success/info；
/// - **生命周期安全**：挂 `ToastManager.navigatorKey` 的根 overlay（goRouter
///   结构下不依赖子页 context），消失时 `Timer.cancel` + `entry.remove`
///   双保；宿主组件自持 controller，remove 前 unmount 不触发 setState。
///
/// 触感（ui-spec §6.0 对号）：error 必配 mediumImpact；success/info 默认
/// 静音（操作本身已有轻反馈，避免双重震动），调用点可显式开。

enum ToastKind { success, info, error }

/// 全局唯一入口。任意层（页面/Sheet/动作回执）均可 `ToastManager.show(...)`
/// ——挂根 overlay，不依赖调用方 context 的路由位置。
class ToastManager {
  ToastManager._();

  /// 根导航 key：MaterialApp 绑定（main.dart），Toast 挂其 overlay——
  /// 页面切换/弹层关闭不影响 Toast 生命周期。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static _ToastEntry? _current;

  static void show(
    String message, {
    ToastKind kind = ToastKind.info,
    Widget? action,
    VoidCallback? onDismissed,
    bool haptic = false,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return; // App 尚未挂载（如测试冷启）——静默放弃
    if (kind == ToastKind.error) {
      HapticFeedback.mediumImpact();
    } else if (haptic) {
      HapticFeedback.lightImpact();
    }
    // 单例替换：轻档复用当前窗口换文案重置计时；error 顶替一切。
    final current = _current;
    if (current != null) {
      if (current.kind != ToastKind.error || kind == ToastKind.error) {
        current.replace(message, kind, action);
        return;
      }
      // 现存 error + 新来轻档：error 驻留不被轻提示顶掉，忽略新提示
      return;
    }
    final entry = _ToastEntry(
      overlay: overlay,
      message: message,
      kind: kind,
      action: action,
      onDismissed: onDismissed,
    );
    _current = entry;
    entry.present();
  }

  static void _clear(_ToastEntry entry) {
    if (_current == entry) _current = null;
  }

  /// 测试专用复位：static 状态跨 testWidgets 用例泄漏——前例的 error 驻留
  /// toast 永不自动退场，会把后续用例的轻档 toast 全部静默吞掉。**硬停**
  /// （不播退场动画）：flutter_test 的不变量检查（pending Timer / active
  /// Ticker）在 tearDown 之前执行，动画式 dismiss 在复位路径里必然踩雷。
  @visibleForTesting
  static Future<void> resetForTest() async {
    final entry = _current;
    _current = null;
    if (entry == null) return;
    entry._timer?.cancel();
    entry._timer = null;
    entry.controller.stop();
    final e = entry._entry;
    entry._entry = null;
    entry._removed = true;
    if (e != null && e.mounted) e.remove();
    entry.controller.dispose();
  }
}

/// 一次 Toast 的生命周期载体：controller / entry / timer 三件自持，
/// dismiss 双保（cancel + remove），防「秒级退页后 setState 孤儿」。
class _ToastEntry {
  _ToastEntry({
    required this.overlay,
    required this.message,
    required this.kind,
    required this.action,
    this.onDismissed,
  }) : controller = AnimationController(
          duration: const Duration(milliseconds: 200),
          reverseDuration: const Duration(milliseconds: 150),
          vsync: overlay,
        );

  final OverlayState overlay;
  ToastKind kind;
  String message;
  Widget? action;
  final VoidCallback? onDismissed;
  final AnimationController controller;
  OverlayEntry? _entry;
  Timer? _timer;
  bool _removed = false;

  /// 跟手拖拽累计位移（onPanStart 归零；>48px 直接收卡）。
  double _dragAccum = 0;

  void present() {
    _entry = OverlayEntry(builder: (_) => _ToastCard(entry: this));
    overlay.insert(_entry!);
    controller.forward();
    _armTimer();
  }

  /// 单例替换：换文案/档位 + 重置计时（窗口不垂直排队下挂）。
  void replace(String message, ToastKind newKind, Widget? newAction) {
    this.message = message;
    kind = newKind;
    action = newAction;
    _armTimer();
    // 卡片经 AnimatedSwitcher 键控 message 重建做交叉淡化；error 升级
    // 时图标/底色随 kind 变化由卡片自身 build 感知。
    _entry?.markNeedsBuild();
  }

  void _armTimer() {
    _timer?.cancel();
    final seconds = switch (kind) {
      ToastKind.success => 1.5,
      ToastKind.info => 3.0,
      ToastKind.error => 0.0, // 驻留：手动滑走或点操作
    };
    if (seconds > 0) {
      _timer = Timer(Duration(milliseconds: (seconds * 1000).round()), dismiss);
    }
  }

  /// 淡出 + 移除；幂等（timer 触发与手势/操作可能并发到达）。
  Future<void> dismiss() async {
    _timer?.cancel();
    _timer = null;
    if (!_removed) {
      _removed = true;
      try {
        await controller.reverse();
      } catch (_) {
        // 宿主已随页面/窗口 unmount（ticker 失效）——直接移除兜底
      }
      final e = _entry;
      _entry = null;
      if (e != null && e.mounted) e.remove();
      controller.dispose(); // Ticker 必须随 entry 生命周期销毁（Overlay 复用，漏销毁=泄漏）
      ToastManager._clear(this);
      onDismissed?.call();
    }
  }
}

/// 顶部浮动卡（2026-10-06，规格速查表三档）：
/// - 落点：顶部 SafeArea 下方 + `Insets.lg`，宽 = 屏宽 − 2×`Insets.xl` 居中
///   （浮动卡质感，非全宽 Material 条）；
/// - 形态：圆角矩形 `Radii.lg`（去胶囊硬约束）+ 柔和投影；
/// - 动效：淡入 + 顶部轻微下落（-0.2 → 0，约 10px，忌大幅入屏）；
/// - 退出：垂直上滑 fling（velocity > 300）即走；档位替换时
///   AnimatedSwitcher 交叉淡化换文案（同名元素禁同屏并存）。
class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.entry});

  final _ToastEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 三档取色（规格速查表）：底 surfaceContainerHighest（暗色三阶浮，
    // 主题层已覆写）；图标 success/info=onSurfaceVariant（装饰不走橘红），
    // error=colorScheme.error（语义色）；文本 onSurface。
    final icon = switch (entry.kind) {
      ToastKind.success => Icons.check,
      ToastKind.info => Icons.info_outline,
      ToastKind.error => Icons.error_outline,
    };
    final iconColor = entry.kind == ToastKind.error
        ? scheme.error
        : scheme.onSurfaceVariant;

    return Positioned(
      top: MediaQuery.paddingOf(context).top + Insets.lg,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width - 2 * Insets.xl,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.2),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: entry.controller,
              curve: Curves.easeOutCubic,
            )),
            child: FadeTransition(
              opacity: entry.controller,
              child: _ToastFling(
                entry: entry,
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  elevation: 6,
                  shadowColor: Colors.black,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Padding(
                      // 键控文案：单例替换时交叉淡化，不垂直排队
                      key: ValueKey('${entry.kind}:${entry.message}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.lg,
                        vertical: Insets.md,
                      ),
                      child: Row(
                        children: [
                          Icon(icon, size: 20, color: iconColor),
                          const SizedBox(width: Insets.sm),
                          Expanded(
                            child: Text(
                              entry.message,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: scheme.onSurface),
                              maxLines: entry.kind == ToastKind.error ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Error 驻留档的行动点：tonal 小按钮视觉可扫
                          //（暗底上文字按钮易被当正文）；其余档无操作位。
                          if (entry.action != null) ...[
                            const SizedBox(width: Insets.sm),
                            entry.action!,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 退出手势：垂直拖拽跟手 + 上滑 fling（velocity > 300）加速度响应——
/// 轻确认不打断，不要求拖过阈值才判定成功。
class _ToastFling extends StatelessWidget {
  const _ToastFling({required this.entry, required this.child});

  final _ToastEntry entry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 上滑 fling 即走（含横向轻扫的垂直分量判定——velocity 垂直分量 < -300）
      onPanEnd: (d) {
        if (d.velocity.pixelsPerSecond.dy < -300) entry.dismiss();
      },
      // 跟手淡出：拖拽超过 48px 直接收（避免半悬状态卡住驻留 error）
      onPanUpdate: (d) {
        if (d.delta.dy < 0) {
          entry._dragAccum += -d.delta.dy;
          if (entry._dragAccum > 48) entry.dismiss();
        }
      },
      onPanStart: (_) => entry._dragAccum = 0,
      child: child,
    );
  }
}
