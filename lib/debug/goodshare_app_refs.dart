library;

import '../action/item_action_handler.dart';
import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../service/mcp_controller.dart';

/// 全局可访问的 MCP 总控实例（装配处赋值；调试桥状态快照与路由目标复用）。
///
/// 拾贝的 [McpController] 在 `main()` 内装配，本引用把它提升为全局可见，
/// 供调试桥的 `stateProvider`（MCP 运行态）与 `mcp` 路由目标共用，避免穿透 UI 树取状态。
late McpController goodshareMcpController;

/// 全局动作层 / 仓库引用（装配处赋值；调试桥 `edit_body` 动作复用正规写入口
/// [ItemActionHandler]——调试改文与业务写同源，禁绕过动作层直写 DB）。
late ItemActionHandler goodshareActionHandler;
late Repository goodshareRepo;

/// 全局 AI 能力开关引用（装配处赋值；调试桥 `set_caps` 动作复用正规开关通道——
/// 与设置页同一 [AiCapabilities] 实例持久化，禁旁路直写 prefs）。
late AiCapabilities goodshareCaps;
