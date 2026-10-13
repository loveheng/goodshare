---
memo: todos
format: v3
epic: goodhub-local-plugin
---

# goodhub-local-plugin · 域内待办
- [ ] [2026-10-13] (风险) (层:L1) (重:中) 真机联调第三批：与 goodhub 侧对齐 §4.3 节点卡展示位（在线点/延迟/工具计数/鉴权态）+ §4.4 PC 网关路径（本地插件走自动发现通道，非手填端点卡） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (风险) (层:L1) (重:轻) 同签名确认：goodshare 与 goodhub 须同签名发布（本地插件 signature 权限零弹窗前提，#8） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (文档) (层:L4) (重:轻) mcp_page.dart 接入指南重写：本地插件自动挂载、PC 经 GoodHub 网关，移除 X-Api-Key token 概念（同签名零弹窗） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L4) (重:中) PC 桥迁移：mcp-bridge/stdio-bridge.mjs 直连 127.0.0.1:8765 改连 goodhub 网关 :8766（或换 goodhub 新 PC 桥），旧 adb reverse 8765 失效 (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L1) (重:中) 接入 goodhub-mcp-plugin-core SDK：工具 hand-coded switch(name)(tools.dart:798) 迁 @McpTool 注解，裸名交 SDK 自动前缀加/剥（依赖 SDK 交付；未到位手搓 IMcpChannel 兜底） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L1) (重:中) sampling 反向请求闭环迁移：ai_suggest_tags 经 IMcpCallback.onEvent 推 sampling/createMessage、宿主 answerReverse 回，按 srv_<n> id 关联，复用 completer 注册表（mcp_server.dart:271-292） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L1) (重:中) ai_suggest_tags 改 _async：同步采样 90s 阻塞改立即回 {"_async":true} + onEvent 推同 id 终帧；HTTP 版 SSE 帧流(_streamingToolCall) 平移为 IMcpCallback.onEvent 帧 (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L2) (重:中) 大结果 mcp-blob:// URI 降级：get_item 图片内联(4MB 帽, tools.dart:910) 改 mcp-blob://com.zzh.goodshare/<path>（严禁 $ref://），resources/read 文本加阈值帽 (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L1) (重:中) 前台服务与 AI 队列保活解绑：MCP 改 Binder 后不再自起前台服务保活（goodhub 随调随起），AI 队列后台推理保活保留独立前台服务（ai_queue_service.dart 复用点解耦） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
- [ ] [2026-10-13] (功能) (层:L1) (重:重) goodshare 改 goodhub 本地 Binder 插件 PoC：AndroidManifest 声明 exported Service + com.zzh.goodhub.action.MCP_SERVER + meta-data(SERVER_ID/SERVER_TITLE) + Android 11+ <queries> action；删 HttpServer 端口监听、新 Service 壳把 call(json) 转发现有 McpServer._dispatch（验证 initialize/tools/list/tools/call 走通） (src: ai, 评估 docs/design/goodshare-goodhub-local-plugin-eval.md)
