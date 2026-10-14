---
dev-loop: memory
format: v1
epic: goodhub-local-plugin
total-merged: 1
last-merge: 2026-10-13
---

# goodhub-local-plugin · goodshare 本地 Binder 插件改造

- [挂载] docs/design/goodhub-local-plugin.md

## 目标
goodshare 由 HTTP MCP server（`:8765/mcp`）改造为 goodhub 本地 Binder 插件：Release 零端口、系统级自动发现、同签名零弹窗、随调随起。评估 SSOT = `docs/design/goodshare-goodhub-local-plugin-eval.md`；goodhub 侧契约 SSOT = `thirdconnect.md`（TC1~TC14）。

## 断点
- [断点] 下一步：待双方真机联调——goodhub 同步带 `<uses-permission com.zzh.goodhub.permission.MCP_SERVER>` + 同签名 debug 包，只用短工具 `list_items`/`get_item`，顺带验 R1 WAL 并发与 `force-stop` 随调随起自愈。已落地归档（done.md 2026-10-13）：PoC 改造清单 #1（b5fc82f）、goodhub 评估回填 B1/B2/B3/R2、R1 缓解 `busy_timeout=5000` + WAL 双连接实证。后续 #6 SDK / #7 网关 / #10 节点卡依赖 goodhub 侧就绪；#4/#5 已于 2026-10-13 落地（ai_suggest_tags `_async` + sampling onEvent 闭环，McpServer.onEventEmitter 接原生 pushEvent）。能力平移批次 goodshare 侧已全闭环，剩余均卡 goodhub。
- [2026-10-13] 跨仓契约核对（#4/#5 闭环钉死）：goodhub 侧 `BinderTransport` 已**正确实现** `_async` + onEvent 路由，无需 goodshare 改动。证据：① Dart `lib/mcp/transport/binder_transport.dart` 的 `send()`(L244-253)/`sendStream()`(L309-314) 检测 `_async` 占位帧并保持 completer 开启至同 id 终帧（且 completer 在 await send 前注册，规避竞态）；`_onNativeEvent`(L126-148) 按 method 有无路由：progress→广播、反向请求(method+id)→answerReverse、终帧(id 无 method)→唤醒 send。② 原生 `BinderTransport.kt` 的 `onEvent`(L238-250) 经主线程 post→EventChannel 透传 Dart，`registerCallback` 在 `onServiceConnected` 后、首次 send 前注册（L270），goodshare `pushEvent` 必命中活 callback。③ 宿主 `samplingRequestHandler`(goodhub/lib/mcp/sampling.dart) 消费 `sampling/createMessage` 真实云端 LLM 推理，参数名与 goodshare `ai_suggest_tags` 发出的 `messages`/`content.text`/`systemPrompt`/`maxTokens`(tools.dart:1352-1366) 逐一吻合（HTTP 路径已验证同载荷）。④ E2E 真机覆盖：`thirdconnect_e2e_test.dart` e2e-2 `dummy__slowEcho`(async=true + progress + 终帧) 验 `_async` 路由、e2e-3 `dummy__reverseDemo`(reverseRequest sampling/createMessage→answerReverse) 验反向请求闭环。结论：goodshare #4/#5 跨仓契约**已对齐可钉死**，无缺口；建议 #10 联调期给 `ai_suggest_tags` 补一条 Binder 专属 e2e（mirror dummy 的 slowEcho/reverseDemo 覆盖）。

## 显式决策
- [2026-10-13] B2 签名权限已提前至 PoC 落地（原计划上线前）：goodhub 侧同步加 `<uses-permission>`，两包必须**同签名同批**出包，否则 bind 报 SecurityException——联调排期强耦合。
- [2026-10-13] R1（双 isolate WAL 并发写）评估为部分成立、PoC 接受：联调期 Binder 路径**读为主**（写工具单并发）；缓解已落地 `PRAGMA busy_timeout=5000`（db.dart onOpen，主/binder 双连接生效），wal_two_conn_test 实证：默认态双连接并发写触发 SQLITE_BUSY、busy_timeout+单事务批量写 600 行全落无 BUSY（eval §7.2）。
- [2026-10-13] PoC 范围 DP1/DP2/DP3（pending-confirm.md 已核销）：DP1=headless FlutterEngine（真·随调随起）；DP2=HTTP server(:8765) 保留作可关闭回退（McpController 未动，Manifest 仅新增 Service）；DP3=PoC 仅 #1，不含 #2~#5。
- [2026-10-13] 评估结论：R3 确认范围极小（仅 ai_suggest_tags 同步采样）；R4 确认破坏性（eval §7）。
- [2026-10-14] #9 同签名跨仓协调**已达成协议、状态锁定**（无需代码改动，现状对称+零侵入）：§3-1 goodhub `<uses-permission>` ✅已落（仅请求，声明方=goodshare）；§3-2 对称——两侧 release 现均 debug 密钥签（goodshare build.gradle.kts:56 ↔ goodhub :41），同机构建即同源无错配，正式 release 证书机制=共享受控 keystore+key.properties gitignore+keytool SHA-256 比对（属正式出包前置、非阻塞 #10）；§4 双方接受方案1（同机/同CI默认keystore零侵入）；§5 双方承诺各跑 D.1 指纹+D.2 真机 bind 探针。#9 收口判定=协调面全对齐，**唯剩 §5 门禁实跑待真机窗口（第三批：真机+BYOK云配置+第二真实服务）**，跑通即关 #9、解锁 #10 T5+T6。详见 same_sign_coord.md §8 回执归档。
