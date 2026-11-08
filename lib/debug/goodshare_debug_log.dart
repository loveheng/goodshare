library;

import 'package:app_debug_bridge/app_debug_bridge.dart' show DebugLogEntry, DebugLogSink;
import 'package:flutter/foundation.dart' show debugPrint;

/// 拾贝调试日志源：把全局 `debugPrint` 重定向进内存环形缓冲，供 `/debug/logs` 消费。
///
/// 拾贝无结构化日志内核（MCP 层与框架均用 `debugPrint`），故桥的日志端点在宿主侧
/// 用本适配器落地：安装后所有 `debugPrint` 同时入缓冲（保留原输出），`/debug/logs` 即能回看。
/// 缓冲上限 500 条、超出丢弃最旧；`revision` 随每次新增自增，作增量游标。
class GoodShareDebugLogSink implements DebugLogSink {
  GoodShareDebugLogSink._();

  static final GoodShareDebugLogSink instance = GoodShareDebugLogSink._();

  static const int _max = 500;
  final List<DebugLogEntry> _buf = <DebugLogEntry>[];
  int _revision = 0;

  /// 重定向 `debugPrint` → 缓冲（保留原输出到 console）。
  ///
  /// 仅应在 debug 装配期调用一次；覆盖的是全局变量，故公共包自身与 Flutter 框架的
  /// `debugPrint` 一并入缓冲（桥自身日志也可回看）。
  static void install() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      original(message, wrapWidth: wrapWidth); // 保留原输出
      final msg = message ?? '';
      instance._buf.add(DebugLogEntry(
        timestamp: DateTime.now(),
        level: _levelOf(msg),
        message: msg,
      ));
      if (instance._buf.length > _max) instance._buf.removeAt(0);
      instance._revision++;
    };
  }

  static String _levelOf(String message) {
    if (message.startsWith('[DEGRADE]')) return 'error';
    if (message.startsWith('[debug-bridge]')) return 'debug';
    return 'info';
  }

  @override
  int get length => _buf.length;

  @override
  int get revision => _revision;

  @override
  List<DebugLogEntry> entries() => List<DebugLogEntry>.from(_buf);
}
