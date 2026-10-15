---
status: draft
updated: 2026-10-15
---

# goodshare → goodhub 本地 Binder 插件改造

> 实施 epic（独立挂载，不与 misc/其他 epic 混）。评估依据与逐项对照见 [`goodshare-goodhub-local-plugin-eval.md`](./goodshare-goodhub-local-plugin-eval.md)；goodhub 侧契约 SSOT = `thirdconnect.md`（TC1~TC14）；任务源高阶协议见 [`ai-app-split.md` §6](./ai-app-split.md)。
> 立场：goodhub 是通用 MCP 宿主，goodshare 走与 todo 等第三方一致的「本地插件」通用通道，不特制适配。

## 目标
将 goodshare 从 **HTTP MCP server**（`:8765/mcp`，手填端点 + `X-Api-Key`）改造为 goodhub **本地 Binder 插件**：Release 零端口、系统级自动发现、同签名零弹窗、随调随起。

## 改造清单（10 项，落 `context/epics/goodhub-local-plugin/todos.md`）
1. **Binder 插件 PoC**：AndroidManifest 声明 exported Service + `com.zzh.goodhub.action.MCP_SERVER` + meta-data(`SERVER_ID`=`goodshare`/`SERVER_TITLE`=`GoodShare`) + Android 11+ `<queries>` action；删 `HttpServer` 端口监听，新 Service 壳把 `call(json)` 转现有 `McpServer._dispatch`（验证 initialize/tools/list/tools/call 走通）。
2. **前台服务与 AI 队列保活解绑**：MCP 改 Binder 后不再自起前台服务保活（goodhub 随调随起）；AI 队列后台推理保活保留独立前台服务（`ai_queue_service.dart` 复用点解耦）。
3. **大结果 `mcp-blob://` URI 降级**：`get_item` 图片内联（512KB 帽，tools.dart `_kInlineMaxBytes`）改 `mcp-blob://com.zzh.goodshare/<path>`（严禁 `$ref://`），`resources/read` 文本加阈值帽。
4. **`ai_suggest_tags` 改 `_async`**：同步采样 90s 阻塞改立即回 `{"_async":true}` + `onEvent` 推同 id 终帧；HTTP 版 SSE 帧流（`_streamingToolCall`）平移为 `IMcpCallback.onEvent` 帧。
5. **sampling 反向请求闭环迁移**：`ai_suggest_tags` 经 `IMcpCallback.onEvent` 推 `sampling/createMessage`、宿主 `answerReverse` 回，按 `srv_<n>` id 关联，复用 completer 注册表（mcp_server.dart:271-292）。
6. **接入 `goodhub-mcp-plugin-core` SDK**：工具 hand-coded `switch(name)`（tools.dart:798）迁 `@McpTool` 注解，裸名交 SDK 自动前缀加/剥（依赖 SDK 交付；未到位手搓 `IMcpChannel` 兜底）。
7. **PC 桥迁移**：`mcp-bridge/stdio-bridge.mjs` 直连 `127.0.0.1:8765` 改连 goodhub 网关 `:8766`（或换 goodhub 新 PC 桥），旧 `adb reverse 8765` 失效。
8. **`mcp_page.dart` 接入指南重写**：本地插件自动挂载、PC 经 GoodHub 网关，移除 `X-Api-Key` token 概念（同签名零弹窗）。
9. **同签名确认**：goodshare 与 goodhub 须同签名发布（本地插件 signature 权限零弹窗前提，对应 eval #8）。
10. **真机联调第三批**：与 goodhub 侧对齐 §4.3 节点卡展示位（在线点/延迟/工具计数/鉴权态）+ §4.4 PC 网关路径（本地插件走自动发现通道，非手填端点卡）。

## 风险（详见 eval §4）
- Binder 1MB 事务上限 → 超 512KB 走 URI/`ParcelFileDescriptor`（#3）。
- 长任务 `_async` 改造范围（#4）。
- 节点卡展示位、PC 网关迁移为 goodhub 侧待补/待迁（#10/#7）。

## 反向 Server 角色（FC6，暂缓）
goodshare 若依赖 goodhub 反向暴露特权工具，该能力暂缓，触发条件 = 出现真实需求。
