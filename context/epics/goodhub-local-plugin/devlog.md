---
dev-loop: devlog
format: v1
epic: goodhub-local-plugin
total-merged: 1
last-merge: 2026-10-13
---

（追加区：≥5 条自动归并进 memory.md）

## 2026-10-13 归并：PoC #1 + 评估回填 + R1 缓解（原 10 条 → memory/done）

当日三批工作全部落地，详情归档 done.md 2026-10-13，决策与断点已入 memory.md：

1. **PoC 改造清单 #1**（b5fc82f）：AIDL(IMcpChannel/IMcpCallback) + McpBinderService(headless FlutterEngine + IMcpChannel.Stub) + lib/mcp_binder_entrypoint.dart（mcpBinderMain → McpServer.handleJsonRpc/answerReverse，MethodChannel `goodshare/mcp_binder`，tokenProvider 恒 null）+ AndroidManifest（exported Service + com.zzh.goodhub.action.MCP_SERVER + meta-data SERVER_ID/SERVER_TITLE + `<queries>`）；HTTP :8765 按 DP2 保留回退。验证：analyze 0 + `flutter build apk --debug` 通过；goodhub 真机联调待排。
2. **评估回填 B1/B2/B3/R2**（goodhub 交接文档要求，eval §7.1）：call per-call 5s 超时（TimeoutException→-32000）；errorJson 改 org.json.JSONObject + extractId 回显请求 id；ready 10s→5s；Manifest signature 权限 + Service android:permission。
3. **R1 缓解与实证**：db.dart onOpen `PRAGMA busy_timeout=5000`；main.dart import mcp_binder_entrypoint（保 kernel 可达，@pragma vm:entry-point 防摇树）；test/wal_two_conn_test.dart 双 Isolate 并发写——默认态实证 SQLITE_BUSY、缓解后 600 行全落。
4. **工程收口**：sqlite3 ^3.5.2 补 dev_dependencies（原间接依赖）、dispose→close、analyze 0。

## 2026-10-13 阶段 A 落地：#2 前台服务解绑 + #3 mcp-blob 降级

能力平移批次（不依赖 goodhub），两条均已 analyze 0 + `flutter build apk --debug` 通过。

1. **#2 前台服务与 AI 队列保活解绑**：新增 `ForegroundServiceCoordinator`（`lib/service/foreground_task_init.dart`）
   统一管理 MCP(HTTP 回退) 与 AI 队列的前台服务保活——二者各自 `acquire`/`release`，服务在任一持有者
   存活时运行、最后释放时停止（flutter_foreground_task 仅单实例）。具体：
   - `mcp_controller.enable()` 经协调器声明 MCP 保活（不再隐式依赖 AI 队列），`_shutdown()` 改 `release`
     而非无条件 `stopService`，**修掉 MCP disable 误杀 AI 后台推理保活的 bug**；
   - `ai_queue_service` 去除对 `McpController` 的依赖（`mcp` 字段/构造参数移除），独立声明/释放 AI 保活，
     通知优先级 mcp(DEFAULT) > ai(LOW)。
   - 关键判定：`McpBinderService` 是绑定服务（不 `startForeground`），Binder 插件路径本就不经 McpController、
     无需前台保活；MCP 的 HTTP 回退（用户手动开启）仍保留前台保活以可达，**未删**（与 #1 DP2 回退一致）。
2. **#3 mcp-blob 降级**：`get_item` 大图/大附件（>512KB）改返回 `mcp-blob://com.zzh.goodshare/<encodedPath>`
   `resource_link`（小图 ≤512KB 仍内联，兼容 HTTP 桌面客户端）；`resources/read` 新增 mcp-blob URI 解析
   返回 `blob`(base64)，文本加 512KB 阈值帽（超阈值截断并提示走 get_item）。严禁 `$ref://`。
   - 偏差：原文「4MB 帽改 mcp-blob」实现为「512KB 内联 + 超出走 mcp-blob」——与 eval §4「超 512KB 走 URI」
     对齐，且保留小图内联避免无谓破坏现有 HTTP 客户端；宿主取字节需经 resources/read（goodhub 侧待实现）。

下一步（能力平移批次剩余）：#4 ai_suggest_tags `_async` → #5 sampling onEvent 闭环（共用 onEvent 帧机制，
取决于 goodhub 契约是否含 sampling）；#9 同签名须尽早与 goodhub 约排期。

## 2026-10-13 #4/#5 落地：ai_suggest_tags `_async` + sampling onEvent 闭环

先查 goodhub 侧契约 `goodhub/docs/design/thirdconnect.md` 钉死 sampling 是否在契约——**确认在**：
§1.2.2 钉死长任务 `_async`（call 内立即回 `{"_async":true}`、终帧经 onEvent 推同 id）+ 反向请求闭环
（onEvent 推 `sampling/createMessage` → answerReverse 回）；§5 列举 sampling/createMessage；§1.2.7/TC14 要求
SDK 在 >5s 自动降级 `_async` 严禁同步阻塞越 Binder 预算触发 ANR。附带：#3 mcp-blob 也被 TC9/§10.1 钉死为红线
（非可延后）。故 #4/#5 为必做项，已落地（analyze 0 + debug apk 通过）。

1. **#4 `_async`**：`McpServer.handleJsonRpc` 对 `onEventEmitter` 非空 + 工具在 `_kBinderAsyncTools`
   （现 = {ai_suggest_tags}）的 `tools/call`，立即回 `{"result":{"_async":true}}` 并 `_fireAndForget(_runAsyncTool)`，
   后台算完经 onEvent 推同 id 终帧（`_emitAsyncResult`）。规避 Binder 5s 调用预算（sampling 最长 90s 同步阻塞必 ANR）。
   终帧为响应帧（id + result/error，无 method），与反向请求帧（id + method）经同一 onEvent 通道，GoodHub 按「是否含
   method」路由（§1.2.2）。HTTP 路径（onEventEmitter 为 null）不受影响，仍走 SSE 流同步返回。
2. **#5 sampling onEvent 闭环**：新增 `McpServer.onEventEmitter`（由 `mcp_binder_entrypoint` 接原生 `pushEvent`
   通道转 `IMcpCallback.onEvent`）；`_binderSampling` 经 `_emitOnEvent` 推 `sampling/createMessage` 反向请求，
   宿主经 `answerReverse` 回注、复用既有 `_pendingServerRequests` completer 注册表唤醒。原生 `McpBinderService`
   的 `pushEvent`（`callback?.onEvent(json)`）与 `registerCallback`/`answerReverse` 早已就绪，Dart 侧仅补齐发射器接线。

跨仓依赖（**已核对 2026-10-13：goodhub 侧已实现，无需 goodshare 改动**）：其 `BinderTransport` 对 `_async:true` 保持
completer 开启、按 onEvent 终帧 id 完成 tools/call，并按 method 有无路由 onEvent 帧（反向请求 vs 终帧）——见
memory.md 跨仓契约核对条目（binder_transport.dart `send`/`_onNativeEvent` + BinderTransport.kt `onEvent`/`registerCallback`
+ E2E slowEcho/reverseDemo 覆盖）。能力平移批次 goodshare 侧已闭环。

下一步：能力平移批次仅余无（#4/#5 已毕）；剩余 #6 SDK / #7 桥迁移 / #8 文档 / #10 联调 均卡 goodhub 侧就绪；
#9 同签名须尽早与 goodhub 约排期（跨仓协调，启动要早）。

## 2026-10-14 补 Binder 专属测试：钉死 #4/#5 帧形状（test/mcp_binder_test.dart）

跨仓契约核对（2026-10-13）建议 #10 联调前给 `ai_suggest_tags` 补 Binder 专属 e2e + `_async`/onEvent 单元测试。
新增 `test/mcp_binder_test.dart`（`flutter test test/mcp_binder_test.dart` 全绿，7/7），直接构造
`McpServer` 注入 `onEventEmitter` 捕获帧（模拟 `mcpBinderMain` 接 `pushEvent`、绕开 MethodChannel/端口），
消费式 `_EventTap`（backlog 消费 + broadcast 订阅，规避丢失）等待 onEvent 帧。覆盖：

1. `_async` 占位（#4）：`onEventEmitter` 未接（非 Binder/HTTP）→ `ai_suggest_tags` 同步 `sampling_unavailable`、不 `_async`；
   已接 → 立即回 `{"result":{"_async":true}}` 且 call 不阻塞（断言 <5s），占位帧返回时尚未推终帧（真实结果后台异步）。
2. onEvent 帧形状（§1.2.2）：e2e 闭环——反向请求帧含 `method=sampling/createMessage` + `id` 前缀 `srv_` + 载荷含条目正文/
   `systemPrompt`/`maxTokens:256`（与 goodhub `samplingRequestHandler` 字段对齐）；宿主 `answerReverse` 回程 → 终帧无 `method`、
   id 同原 call、标签回写 `status:ok` + tags。另验宿主回 `-32000` → 终帧 `status:sampling_quota_exceeded`（不 isError 帧，防宿主熔断）。
3. `_emitAsyncResult` error 分支（#4）：条目不存在 → 终帧走 `error` 帧（id 同 call、无 method、code=errInvalidParams），且未发采样帧。
4. `answerReverse` 容错（#5）：未知 id / 坏 JSON 静默忽略不抛。

价值：把 goodshare 侧发出帧形状（反向请求 `srv_` 前缀、终帧「无 method」区分、payload 字段名）锁进单测，mirror goodhub 侧
dummy 的 slowEcho/reverseDemo e2e 覆盖，#10 真机联调前先有回归护栏。

## 2026-10-14 #9 同签名跨仓协调清单（same_sign_coord.md）

能力平移批次（#2~#5）已毕、#4/#5 帧形状单测已钉死，转 #9 发布/联调签名门。新增
`context/epics/goodhub-local-plugin/same_sign_coord.md`，把"同签名"从一句 TODO 落成可执行跨仓清单：

- **根因钉死**：goodshare Manifest `<permission ... protectionLevel="signature"/>` 保护 `McpBinderService`；Android `signature` 语义要求请求方 goodhub 与声明方 goodshare **同源证书**，否则 bind 抛 `SecurityException`（无弹窗/无降级）。锚点=goodshare 证书（权限名虽带 goodhub 前缀，但声明方是本仓，已落代码一致）。
- **goodshare 侧动作**：声明侧已落（#1/B2）；**真实缺口**=`build.gradle.kts` 的 `release` 仍 `signingConfig = debug`（TODO 占位），须补真实 release keystore，否则发布零弹窗前提失效；本仓不自加 `<uses-permission>`（请求方是 goodhub）。
- **goodhub 侧动作（跨仓待回执）**：Manifest 加 `<uses-permission com.zzh.goodhub.permission.MCP_SERVER>`（eval B2 已要求）+ 同签名 release/debug 包。
- **联调共享 debug keystore（跨机必做）**：默认每台机 `debug.keystore` 随机互不信任 → 跨机联调必 SecurityException。给两方案：方案1（同机构建零侵入，临时联调）/ 方案2（两侧 debug signingConfig 指同一受控 keystore，跨机稳定）。
- **门禁（§5）**：D.1 `keytool -printcert -jarfile` / `apksigner verify --print-certs` 比对 SHA-256 一致 + D.2 真机 bind `onServiceConnected` 探针不抛 SecurityException → 关闭 #9、解锁 #10。
- **安全红线**：release keystore 禁入 git；联调 debug keystore 绝不可当 release 用（一旦 release 用 debug key 无法换签）。

`todos.md` #9 已挂接文档并标注状态（声明侧落 / release 签名配置缺口 / goodhub 侧待回执 / 门禁未跑）。#9 是 #10 硬前置。

## 2026-10-15 DP2 回退收敛：HTTP 服务隐藏为内部调试（loopback-only）

用户拍板：MCP HTTP 服务不对外（局域网）暴露、仅作内部调试用，MCP 主机制全部走 goodhub 本地 Binder 插件。落地：

1. **bind 收敛**：`mcp_server.dart` `HttpServer.bind` 由 `anyIPv4` 改 `loopbackIPv4`（仅 127.0.0.1，局域网不可达）；桌面端唯一接入途径=USB + `adb reverse tcp:8765 tcp:8765`。
2. **LAN 路径清除**：删 `lib/util/lan_ip.dart`；`mcp_controller.dart` `endpoint()` 去 async 化收敛为同步 getter（恒 `http://127.0.0.1:8765/mcp`），`enable()` 前台通知文案改 loopback 表述；`mcp_page.dart` 删「局域网端点」tile 与指南 LAN 章节，USB/adb reverse 升为唯一途径（标注仅内部调试用）。
3. **文档同步**：mcp-integration.md（删方式 B、加 loopback 说明块）、docs/README.md 索引、product-requirements.md §4 通道描述。

验证（2026-10-15）：`flutter analyze` 0 issue；mcp_server_test + mcp_binder_test 25/25 全绿（含 127.0.0.1 回环访问路径实证 loopback bind 生效）；全量 `flutter test --timeout 60s` 816 全过（跳已知损坏 tag_display_repro_test）。DP2「HTTP 保留作可关闭回退」语义收紧为「保留但隐藏」——开关/前台保活机制不变，仅网络面收敛。

## 2026-10-15 设置入口隐藏：调试手势（长按「关于」）

用户追问「设置里也移除了吗」→ 拍板方案=**藏在调试手势里**（普通用户看不到，开发者仍可开关；彻底移除入口会留下关不掉的僵尸服务）。落地：

1. `settings_page.dart` 删「MCP 网关」分区与「服务与连接」tile（设置树不再可见）。
2. 长按「关于」分区标题 → 调试菜单 BottomSheet（`_showDebugSheet`）→ 「MCP 调试服务」tile（带运行态）→ 进 McpPage。调试菜单是收纳位，后续其他调试入口也挂这里。
3. `mcp-integration.md` 手机端准备第 1 步改为长按手势路径。
