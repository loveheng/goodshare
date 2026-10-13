---
status: active
updated: 2026-10-13
---

# goodshare 接入 goodhub 本地插件机制 · 评估结论（goodshare 侧）

> 对照 goodhub 宿主侧契约 `thirdconnect.md`（TC1~TC14）与 goodshare 任务源协议 `docs/design/ai-app-split.md` 的评估。
> goodhub 是通用 MCP 宿主，goodshare 走与 todo 等一致的「本地插件」通用通道，不特制适配。
> 本文 §5 结论与 §4 风险确认均基于 goodshare 仓库**实际代码取证**（行号引用见各条），非空想推演。

## 1. 现状 vs 目标（不变，复述备忘）

| 项 | 现状（HTTP MCP server） | 目标（本地 Binder 插件） |
|---|---|---|
| 接入类 | 远端服务（Streamable HTTP，手动填 `id/endpoint/token`） | 本地插件（Binder/AIDL，零网络） |
| 端口 | 监听 `0.0.0.0:8765`（硬编码 `McpController.defaultPort`） | Release 绝对零端口 |
| 发现 | ⚙ 手填端点，存 `ServerEndpointStore` | 系统级自动发现、零配置热插拔 |
| 鉴权 | `X-Api-Key` 请求头（`mcp_server.dart:90`） | 同签名 `signature` 权限，零弹窗 |
| 生命周期 | 前台服务常驻保活（`mcp_controller.dart` + `flutter_foreground_task`） | 平时休眠、goodhub 随调随起 |

> 节点卡「Server 节点」分区只列手填远端 HTTP 端点；本地插件走自动发现通道不进该清单。

## 2. goodshare 侧取证要点（决定可行性的硬事实）

- **传输/业务已解耦**：`McpServer`（`lib/mcp/mcp_server.dart`）只做 `HttpServer.bind` + 鉴权；业务逻辑 `_dispatch` / `callTool` / `toolSchemas` 是协议无关的纯 JSON-RPC。这是能切 Binder 的决定性前提——换 Binder 只需把 `_dispatch` 暴露成 `call(String)`。
- **零插件脚手架**：全仓搜索 `Binder / AIDL / IMcpChannel / goodhub-mcp-plugin-core` 命中 0。SDK 须由 goodhub 侧交付；本仓无任何 Binder Service / goodhub action / meta-data 声明。
- **前台服务耦合**：`AiQueueService` 复用 `McpController` 持有的单前台服务保活主 isolate，使 OCR/转写后台消费能退后台继续（`ai_queue_service.dart:16,34`）。该前台服务对象上是给 **AI 队列后台推理**用的，MCP HTTP server 只是搭车。
- **长任务已是异步**：所有重活（transcribe/ocr/translate/summarize/extract_tags）均为「入队即返 `job_id`，客户端轮询 `get_job_status`/`get_item`」模式（`tools.dart` 各 case 调 `handler.execute` 后立即返回，真实工作在 `QueueConsumer` 后台 isolate）。因此这些工具的 `call` 本身秒回。
- **唯一同步长阻塞**：`ai_suggest_tags` 同步 `await sampling(...)` 最多 90s（`tools.dart:1339`，超时 `mcp_server.dart:286`）——这是 Binder 下必须改异步的唯一工具。

## 3. goodhub 自动提供（goodshare 不用做，复述备忘）

系统级自动发现、工具名前缀 `<server_id>__<tool>` 自动加/剥、未激活拦截 + JIT 元工具、网关聚合 `:8766`、`activate_server_tools`、权限卡 L1/L2、PII 过滤、`ops.log` 审计、`notifications/resources/updated` 消费。

## 4. 风险确认（goodshare 侧逐条）

| # | 风险项 | 确认结论 | 代码依据 |
|---|---|---|---|
| 1 | Binder 1MB 事务上限 | **确认触发，集中单点**：`get_item` 图片内联 `base64Encode(file.readAsBytes())` 上限 `4*1024*1024`（`tools.dart:910`），base64 后约 5.3MB，远超 1MB 硬上限 / 512KB 建议值。字幕已受 `_kSubtitleInlineMaxBytes=256KB` 帽（`tools.dart:37`）安全；`resources/read` 返回 `bodyText` 文本（建议也加帽）；`claim_ai_task` 纯文本载荷（`block_summarize` 源 transcript ≤ ~50KB）安全 | `tools.dart:910,37` |
| 2 | 长任务 `_async` 改造量 | **极小**：仅 `ai_suggest_tags` 需改为 `_async`（立即回 `{"_async":true}` + `onEvent` 推终帧）；其余重活已是轮询异步，call 秒回无需改造。另 HTTP 版 SSE 帧流（`_streamingToolCall`/progressToken）须平移到 Binder `onEvent` 帧机制 | `tools.dart:1339`、`mcp_server.dart:192-265` |
| 3 | 节点卡展示位 | **纯 goodhub 侧待补**，本仓不阻塞；真机联调须双方对齐 T5 节点卡是否覆盖本地插件通道（在线点/延迟/工具计数/鉴权态） | — |
| 4 | PC 网关暴露路径变更 | **确认破坏性**：PC 现状直连 goodshare HTTP——`mcp-bridge/stdio-bridge.mjs` 直连 `http://127.0.0.1:8765/mcp` + `X-Api-Key`（`:41-49`），`mcp_page.dart` 教 `adb reverse tcp:8765` + 局域网端点 + token（`:100,148`）。改零端口后 PC 须走 goodhub `:8766` 聚合，旧直连配置失效 | `stdio-bridge.mjs:41-49`、`mcp_page.dart:100,148` |
| 5 | 反向 Server 角色（FC6） | **暂缓**：当前无需求，goodshare 不依赖 goodhub 反向暴露特权工具；触发条件=出现真实需求 | — |

## 5. 评估结论清单（goodshare 侧填写）

| # | 评估项 | 结论 | 工时估算 | 备注 |
|---|---|---|---|---|
| 1 | 能否移除 HTTP 端口监听、改 Binder Service | **是（可行，前台服务须解耦）** | 中 M（约 1 周） | 业务/传输解耦是前提；删 `HttpServer` + 新 Android Service 壳 + `call` 转发 `_dispatch`。前台服务不能顺手删——AI 队列后台推理仍需保活，须把「AI 队列保活」与「MCP 可达性」解绑（MCP 走 Binder 自动发现，无需自起前台服务） |
| 2 | 接入 `goodhub-mcp-plugin-core` SDK 可行性 | **是（推荐，工具注册方式要改）** | 中 M（SDK 到位后约 1~1.5 周） | 须把 hand-coded `switch(name)`（`tools.dart:798`）迁成 `@McpTool` 注解方法，裸名交给 SDK 自动前缀加/剥。SDK 未到位时手搓 `com.zzh.goodhub.mcp.IMcpChannel` 兜底（文档要求优先 SDK，手搓额外 +0.5 周） |
| 3 | 大结果是否触发 1MB 事务上限、需 URI 降级 | **是（确定性触发，必须改）** | 小~中 S~M（约 0.5 周） | 硬爆点=`get_item` 图片内联 4MB 帽（`tools.dart:910`）→ 改 `mcp-blob://com.zzh.goodshare/<path>`（严禁 `$ref://`），宿主经 content URI / `ParcelFileDescriptor` 取字节；建议给 `resources/read` 文本加阈值帽 |
| 4 | 长任务 `_async` 改造范围 | **极小（仅 `ai_suggest_tags`）** | 小 S（约 0.5 周） | 重活早已是入队轮询异步；仅 `ai_suggest_tags` 同步采样 90s 须改 `_async`。SSE 帧流平移为 `onEvent` 帧 |
| 5 | 采样反向请求闭环迁移量 | **小（仅 1 个消费点）** | 小 S（与 #4 合并约 0.5~1 周） | 全仓唯一 sampling 消费=`ai_suggest_tags`（`tools.dart:1316`）。现夹带 SSE 流（`mcp_server.dart:271-292`），Binder 下改 `IMcpCallback.onEvent` 推 + `answerReverse` 回，completer 注册表复用 |
| 6 | 任务源协议（claim/apply）是否保留 | **是（零改动复用）** | 0 | `claim_ai_task`/`touch_ai_task`/`apply_ai_result`（`tools.dart:1367/1417/1424`）纯 JSON-RPC、与传输无关；`$ref` 由 goodhub `ToolRouter.serverFor` 解析，goodshare 不关心前缀 |
| 7 | PC 网关聚合访问迁移影响 | **中（破坏性，阻塞于 goodhub 网关）** | 中 M（goodshare 侧约 0.5 周，阻塞于网关/PC 桥就绪） | `stdio-bridge.mjs` 改连 goodhub 网关或换 goodhub 提供的新 PC 桥；`mcp_page.dart` 端点/token/接入指南整段重写为「本地插件自动挂载、PC 经 GoodHub 网关」，token 概念可能消失（同签名零弹窗） |
| 8 | 同签名权限零弹窗是否满足 | **是（满足）** | 0 | 包名 `com.zzh.goodshare` vs `com.zzh.goodhub` 同发布者签名，`<permission protectionLevel="signature">` 零弹窗。前提：两 app 同签名发布（需 goodhub 侧确认） |

## 6. 总评估与排期建议

- **可行性：高。** 传输/业务解耦是决定性利好；硬风险仅两点——`get_item` 图片爆事务（改 `mcp-blob` URI）+ 前台服务与 AI 队列保活解绑，均有明确改法。其余项（采样、`_async`、claim/apply、同签名）工作量小或为零。
- **三个关键依赖/阻塞**：
  1. `goodhub-mcp-plugin-core` SDK 交付（决定 #2 走 SDK 还是手搓 AIDL）；
  2. goodhub `:8766` 网关 + 新 PC 桥就绪（决定 #7）；
  3. 两 app 同签名确认（#8 前提）。
- **建议排期（按依赖顺序）**：
  1. **PoC（最小改动）**：Manifest 声明 `exported` Service + `com.zzh.goodhub.action.MCP_SERVER` + meta-data（`SERVER_ID`/`SERVER_TITLE`）+ `<queries>` action；Android 11+ 可见性；Service 壳把 `call(json)` 转发现有 `McpServer._dispatch`。验证 `initialize/tools/list/tools/call` 走通。
  2. **能力平移**：`_async` + `onEvent` 帧（替代 SSE 帧流）+ sampling 反向请求（`ai_suggest_tags` 单点迁移）；大结果 `mcp-blob` URI 降级（`get_item` 图片 + 文本阈值帽）；前台服务与 AI 队列保活解绑。
  3. **PC 网关迁移 + 真机联调（第三批）**：桥脚本改造、接入指南重写、与 goodhub 侧对齐 §4.3 节点卡展示位与 §4.4 PC 网关路径，再排联调。

> 填完后回 goodhub 侧，双方对齐 §4.3 节点卡展示位与 §4.4 PC 网关迁移，再排真机联调第三批。

## 7. goodhub 侧评估回填（2026-10-13，Bug1~3 + R1~R4）

goodhub 宿主侧（Dart `BinderTransport`/`LocalPluginDiscovery` + 原生 `BinderTransport.kt`）已完成阶段一只读评估：PoC 的 AIDL/manifest/Service 逐条对齐契约，协议主干可通；提出 1 致命 bug（call 无超时）+ 1 安全缺位（无 signature 权限）+ 1 轻微（error 帧不回 id），及 4 项真机风险。goodshare 侧处理结论如下。

### 7.1 已落地修复（本轮已改，`flutter build apk --debug` 编译通过）

| # | 项 | 结论 | 落地点 |
|---|---|---|---|
| B1 | `resultFuture.get()` 加 ≤5s 超时 | **已修（联调前）** | `McpBinderService.call` → `resultFuture.get(5, TimeUnit.SECONDS)`；`TimeoutException` → `-32000 MCP Binder call timeout`，避免 Dart 不回时 Binder 线程永久阻塞。根本解（长工具 `_async`+`onEvent` 终帧使 call 秒回）在 #4/#5 |
| B2 | Service 加 signature 权限 + `<permission>` 声明 | **已修（随本轮一并落地）** | Manifest 加 `<permission com.zzh.goodhub.permission.MCP_SERVER protectionLevel="signature"/>` + Service `android:permission`。**强耦合：goodhub 必须同步加 `<uses-permission>` 且两包同签名，否则 bind 报 SecurityException** |
| B3 | error/timeout 回显请求 id | **已修** | 新增 `extractId(jsonRpcRequest)` 先取 id，全部 `errorJson` 回显；`errorJson` 改 `org.json.JSONObject` 构造（string id 自动加引号、message 自动转义） |
| R2 | `ready` 等待收紧 ≤5s | **已修** | `ready.completeFutureOrDefault(false, 5, SECONDS)`，对齐 goodhub 冷启 5s 超时 |

### 7.2 评估结论（本轮不落码，转真机验证 / 后续批次）

| # | 项 | 结论 | 计划批次 | 备注 |
|---|---|---|---|---|
| R1 | 双 isolate WAL 并发写 `goodshare.db` | **部分成立，PoC 接受** | 真机验证 | 「WAL 下安全」确属乐观——WAL 不消除跨连接写竞争。缓解：联调期 Binder 路径读为主（`list_items`/`get_item`），写工具单并发；后续按需加 `PRAGMA busy_timeout` 或单 isolate actor 串行化。真机按「UI 加 item + MCP `add_item` 并发」盯 `database is locked` |
| R3 | 长工具 `_async` 改造范围 | **确认范围极小（仅 `ai_suggest_tags`）** | #4/#5 | 与本仓 eval §5-4 / §2 一致（重活早已入队轮询异步）；联调只用短工具 |
| R4 | PC 网关聚合访问迁移 | **确认破坏性** | 第三批 | 与本仓 eval §5-7 / §4-4 一致，阻塞于 goodhub `:8766` 网关 + 新 PC 桥就绪 |
