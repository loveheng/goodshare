import 'dart:async';

import 'package:flutter/widgets.dart';

/// 应用生命周期广播中心（规则一/三/四的架构枢纽）。
///
/// 以 mixin 形式复用 [WidgetsBindingObserver] 的默认实现，仅覆写
/// [didChangeAppLifecycleState] 做广播；将 [AppLifecycleState] 变化发给订阅者，
/// 任务队列、安全中心、草稿管理器等各自订阅关心的状态，逻辑彻底解耦。
/// 需在使用前调用 [init]（main 中一次即可）。
class AppLifecycleManager with WidgetsBindingObserver {
  AppLifecycleManager._();

  static final AppLifecycleManager instance = AppLifecycleManager._();

  final StreamController<AppLifecycleState> _controller =
      StreamController<AppLifecycleState>.broadcast();

  /// 生命周期状态变更广播流；订阅者自行 [Stream.where] 过滤关心的状态。
  Stream<AppLifecycleState> get states => _controller.stream;

  /// 仅关心「回到前台」的便捷流（队列回收 / 排空 / 草稿恢复订阅它）。
  Stream<AppLifecycleState> get onResumed =>
      states.where((s) => s == AppLifecycleState.resumed);

  /// 仅关心「离开前台」的便捷流（高斯模糊遮罩 / FLAG_SECURE / 草稿防抖写盘订阅它）。
  Stream<AppLifecycleState> get onBackgrounded => states.where(
        (s) => s == AppLifecycleState.paused || s == AppLifecycleState.inactive,
      );

  final StreamController<void> _memoryController =
      StreamController<void>.broadcast();

  /// 系统内存压力广播（[didHaveMemoryPressure] 触发）：AI 队列据此优雅中断推理。
  Stream<void> get onMemoryPressure => _memoryController.stream;

  bool _initialized = false;

  /// 注册为 WidgetsBinding 观察者；幂等，重复调用安全。
  void init() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// 反注册并关闭广播流（进程退出 / 测试用）。
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.close();
    _memoryController.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.add(state);
  }

  @override
  void didHaveMemoryPressure() {
    _memoryController.add(null);
  }
}
