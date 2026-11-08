library;

import 'package:app_debug_bridge/app_debug_bridge.dart';
import 'package:flutter/material.dart';

import '../action/commands.dart';
import '../models/item.dart' show bodyMd5;
import '../service/mcp_bridge_channel.dart';
import '../service/on_device_service.dart';
import '../ui/toast.dart';
import 'goodshare_app_refs.dart';
import 'goodshare_debug_log.dart';
import 'goodshare_debug_routes.dart';
import 'goodshare_debug_screenshot.dart';

/// 拾贝调试桥端口：与 goodhub 的公共包默认端口（8767）错开。
///
/// Android 的 loopback 是整机共享的地址空间，同机两个接桥 App 都绑 8767 时
/// 后启动者必然失败；宿主在装配期显式分配互异端口，端点/token 由 logcat 自描述，
/// CLI 按包名发现（见 scripts/agent-tools/debug-bridge.sh discover）。

/// 拾贝调试桥状态快照（MCP 服务运行态 + 包标识 + 访问令牌）。
///
/// 供 `/debug/state` 回显；仅暴露调试关心的运行态，不触及业务状态。
/// mcpToken 与「MCP 页点开令牌文本」可见性等价，同样受 loopback + Bearer 约束，
/// 且 debug 桥只在 !kReleaseMode 装配。自动化据此走结构化观测，不再依赖点显隐
/// 按钮后的控件树重建时序（2026-11-06 真机实证：UI 路径会读到旧帧）。
Map<String, Object?> _stateProvider() => <String, Object?>{
      'packageId': 'goodshare',
      'mcpRunning': goodshareMcpController.running,
      'mcpPort': goodshareMcpController.port,
      'mcpEndpoint': goodshareMcpController.endpoint,
      'mcpToken': goodshareMcpController.token,
      // W6-a 端侧登记表快照（联调设施 §G1a）：e2e 断言「占位保持/摘登记/无残留」
      // 的状态真源，替代日志反推；语义 = tasksSnapshot()（空表 = 无在途 deferred）。
      'onDeviceTasks': OnDeviceAsyncService.instance.tasksSnapshot(),
      // host_sim 注入态回显（§G6）：e2e 前置复位检查。
      'hostSimNotReady': McpBridgeChannel.debugNotReady,
    };

/// 装配调试桥：把宿主专有三件（日志源 / 导航柄 / 路由白名单）接到公共包注入端口。
///
/// 导航柄复用既有 `ToastManager.navigatorKey`（全局根 key），无需新增；公共包本身不含
/// 任何宿主业务，此处完成汇合。`navigate` 经 `debugRouteRegistry` 限白名单，`tap_node`
/// / `set_text` 经当前 context 遍历控件树，均确定性、不依赖坐标。
DebugBridge buildDebugBridge() {
  // 导航句柄 + 遍历起点（动作面需要挂载中的 context）。
  debugNavigatorProvider = () => ToastManager.navigatorKey.currentState;
  debugContextProvider = () => ToastManager.navigatorKey.currentContext;
  // 路由白名单（navigate 只跳登记页）。
  debugRouteRegistry = goodshareDebugRouteRegistry;
  return DebugBridge(
    stateProvider: _stateProvider,
    logSink: GoodShareDebugLogSink.instance,
    uiTreeProvider: () => collectDebugUiTree(ToastManager.navigatorKey.currentContext),
    actionHandler: _executeGoodshareDebugAction,
    screenshotProvider: goodshareCaptureScreenshot,
  );
}

/// 宿主自定义调试动作 → 未命中回落公共包动作面（tap_node / navigate / …）。
Future<Object?> _executeGoodshareDebugAction(
  String action,
  Map<String, Object?> args, {
  BuildContext? contextOverride,
  NavigatorState? navigatorOverride,
}) async {
  if (action == 'edit_body') return _editBodyDebugAction(args);
  if (action == 'task_inject') return _injectTaskDebugAction(args);
  if (action == 'task_clear') return _taskClearDebugAction();
  if (action == 'set_caps') return _setCapsDebugAction(args);
  if (action == 'host_sim') return _hostSimDebugAction(args);
  return executeDebugAction(
    action,
    args,
    contextOverride: contextOverride,
    navigatorOverride: navigatorOverride,
  );
}

/// `edit_body` 调试动作（stale 链路真机构造用）：追加正文并走**正规写入口**
/// [ItemActionHandler]（与业务写 / MCP 写同源，禁绕过动作层直写 DB）。
/// args：`{id, append}` 或 `{titleMatch, append}`——human_md 全量替换为
/// 「旧文 + append」；titleMatch = 标题含子串的首条（免查 itemId）。
Future<Object?> _editBodyDebugAction(Map<String, Object?> args) async {
  final id = args['id']?.toString();
  final titleMatch = args['titleMatch']?.toString();
  final append = args['append']?.toString();
  if ((id == null || id.isEmpty) && (titleMatch == null || titleMatch.isEmpty)) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_args',
      'detail': 'edit_body 需要 {id, append} 或 {titleMatch, append}',
    };
  }
  if (append == null) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_args',
      'detail': 'edit_body 需要 append',
    };
  }
  final target = id != null && id.isNotEmpty
      ? await goodshareRepo.byId(id)
      : (await goodshareRepo.list(limit: 200)).firstWhere(
          (it) => (it.humanTitle ?? '').contains(titleMatch!),
          orElse: () => throw StateError('title 未命中: $titleMatch'),
        );
  if (target == null || target.id == null) {
    return <String, Object?>{'ok': false, 'error': 'not_found', 'detail': '条目不存在'};
  }
  final newMd = '${target.humanMd ?? ''}$append';
  final r = await goodshareActionHandler.execute(
    UpdateItemCommand(id: target.id!, humanMd: newMd),
    actor: CommandActor.ai,
  );
  return <String, Object?>{
    'ok': true,
    'action': 'edit_body',
    'itemId': target.id,
    'result': r.toJson(),
  };
}

/// `task_inject` 调试动作（not_found 链路真机构造用，W6-a 验收 5）：注入一条
/// **宿主侧不存在**的假 deferred 登记（taskId = `debug_notfound_<epoch>`），
/// 走正规 [OnDeviceAsyncService.registerDeferred] 入口——占位 / 轮询 / 收敛与
/// 真实任务同管线，仅 taskId 对宿主不可知 → Pull 应答 not_found → 失败注记。
/// args：`{id, append}` 的 id 或 `{titleMatch, append}` 的 titleMatch 定位条目。
Future<Object?> _injectTaskDebugAction(Map<String, Object?> args) async {
  final id = args['id']?.toString();
  final titleMatch = args['titleMatch']?.toString();
  final target = id != null && id.isNotEmpty
      ? await goodshareRepo.byId(id)
      : (await goodshareRepo.list(limit: 200)).firstWhere(
          (it) => (it.humanTitle ?? '').contains(titleMatch ?? ''),
          orElse: () => throw StateError('title 未命中: $titleMatch'),
        );
  if (target == null || target.id == null) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_args',
      'detail': 'task_inject 需要 {id} 或 {titleMatch}（条目须存在）',
    };
  }
  final taskId = 'debug_notfound_${DateTime.now().millisecondsSinceEpoch}';
  await OnDeviceAsyncService.instance.registerDeferred(
    taskId: taskId,
    itemId: target.id!,
    bodyMd5: bodyMd5(target.humanMd),
    instruction: 'debug:not_found 构造',
  );
  return <String, Object?>{
    'ok': true,
    'action': 'task_inject',
    'taskId': taskId,
    'itemId': target.id,
    'hint': '前台 30s 轮询 / 回前台触发 Pull，宿主应答 not_found → 失败注记',
  };
}

/// `task_clear` 调试动作（e2e 可重复性前置）：清空端侧登记表（走正规
/// [OnDeviceAsyncService.clearForDebug]），残留登记会让「登记数=1」类断言
/// 不可重复。
Future<Object?> _taskClearDebugAction() async {
  await OnDeviceAsyncService.instance.clearForDebug();
  return <String, Object?>{
    'ok': true,
    'action': 'task_clear',
    'onDeviceTasks': OnDeviceAsyncService.instance.tasksSnapshot(),
  };
}

/// `set_caps` 调试动作（e2e 前置注入，联调设施 §G6a）：走正规 [AiCapabilities]
/// 开关通道（与设置页同一实例持久化，禁旁路直写 prefs），当前开放端侧异步模式。
/// args：`{onDeviceAsync: bool}`。
Future<Object?> _setCapsDebugAction(Map<String, Object?> args) async {
  final v = args['onDeviceAsync'];
  if (v is! bool) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_args',
      'detail': 'set_caps 需要 {onDeviceAsync: bool}',
    };
  }
  await goodshareCaps.setOnDeviceAsyncEnabled(v);
  return <String, Object?>{
    'ok': true,
    'action': 'set_caps',
    'onDeviceAsyncEnabled': goodshareCaps.onDeviceAsyncEnabled,
  };
}

/// `host_sim` 调试动作（S1-S3 离线态可重复注入，联调设施 §G6）：置
/// [McpBridgeChannel.debugNotReady] 模拟宿主不可达（通道级环境态，两侧收敛行为
/// 与真实离线同路径），免真实卸载/停止 goodhub。args：`{notReady: bool}`。
Future<Object?> _hostSimDebugAction(Map<String, Object?> args) async {
  final v = args['notReady'];
  if (v is! bool) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_args',
      'detail': 'host_sim 需要 {notReady: bool}',
    };
  }
  McpBridgeChannel.debugNotReady = v;
  debugPrint('[debug-sim] host_sim notReady=$v');
  return <String, Object?>{
    'ok': true,
    'action': 'host_sim',
    'notReady': v,
    'hint': 'true = 通道按宿主不可达处理（onDeviceCall→null / notify→丢弃）；测完置 false 复位',
  };
}
