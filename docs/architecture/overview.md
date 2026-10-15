---
status: active
updated: 2026-10-15
---

# 架构总览

拾贝是一个 Flutter 单模块应用：**系统分享 → 私有存储 → 浏览检索 → MCP 对外**。Android 首发；iOS/鸿蒙迁移时本层结构可整体保留，仅平台插件层需按端适配。LLM 推理不在本仓（见「关键决策」末条）。

## 分层

```mermaid
flowchart TD
    subgraph 采集摄入
        SH[系统分享 ACTION_SEND / SEND_MULTIPLE] --> SI[lib/share/share_intake.dart<br/>文本/链接归一 + 附件分型落盘]
        SI -->|CollectCommand / AppendSegmentCommand| H
    end
    subgraph 写入（唯一入口）
        UI[Flutter UI<br/>lib/pages + lib/ui] -->|组装 ItemCommand| H
        MCP[MCP tools.dart<br/>大模型 JSON] -->|ItemCommand.fromJson| H
        H[ItemActionHandler.execute / executeAll<br/>校验 + 落库 + 回最新快照] --> R
    end
    subgraph 存储
        R[(Repository<br/>sqflite goodshare.db)]
        R --- T1[inbox_items<br/>三层集散表 raw/human/machine]
        R --- T2[ai_task_queue + ai_revisions]
        R --- T3[workspaces + workspace_items + templates]
        R --- T4[drafts / block_artifacts / item_embeddings / daily_metrics]
    end
    subgraph 消费
        R --> P[lib/pages<br/>3 tab 主壳 全部/工作区/设置]
        R --> QC[QueueConsumer<br/>端侧轻量 AI 管线 OCR/转写/翻译]
        R --> MS[lib/mcp/mcp_server.dart<br/>HTTP :8765 + Binder 双通道]
    end
    MS -->|stdio 桥| BR[mcp-bridge/stdio-bridge.mjs<br/>桌面 Claude/Cursor]
    MS -->|claim/touch/apply_ai_task| HB[AI 宿主 App（goodhub）<br/>LLM 推理方]
    QC -->|ApplyAiResultCommand| H
```

> 分层细节与写路径约束（命令模式 / 防呆下沉 / 乐观锁 / 原子批量）以 `docs/architecture/human-ai-parity.md` 为 SSOT，本文不重复。

## 关键决策

- **存储**：`inbox_items` 三层集散表（`raw_content` 脏数据 / `human_md` 人类态 / `machine_json` 机器态）+ `ai_task_queue` 后台队列；派生数据分表（`block_artifacts` 块产物 / `item_embeddings` 向量 / `ai_revisions` AI 写回快照 / `drafts` 草稿）；`daily_metrics` 为时光机上下文占位（健康/日历抓取已于 2026-10-15 砍除，表无写入方）。v1 单表 `items` 未经设计，升级时弃旧数据整体重建、不做迁移。
- **附件分型直存**（2026-10-06 拍板）：图片/音频/PDF 收到即复制进 `documents/shares/`（owned）；视频维持引用（ref）——直接引用源 URI 并尝试 `takePersistableUriPermission`，失效时由「附件迁移」页转 owned 兜底（persistable 可达性未真机验证，属已知平台约束）。
- **MCP 传输**：`dart:io HttpServer` 手写 Streamable HTTP——`POST /mcp` 单 JSON 响应（通知 202）；`tools/call` 带 `_meta.progressToken` 时升级 SSE 帧流（progress 通知 + keep-alive 心跳 + 终帧）；`GET /mcp` 开 SSE 下行长连接承载 `resources.subscribe` 订阅推送与 sampling 反向请求。支持协议版本 2025-06-18 / 2025-03-26 / 2024-11-05；无会话 id、无状态。
- **Binder 本地插件**（goodhub-local-plugin）：同进程外第二入口 `McpBinderService`（headless FlutterEngine，随调随起），走同签名 `signature` 权限而非 X-Api-Key；HTTP 服务保留为可关闭回退。详见 `docs/design/goodhub-local-plugin.md`。
- **鉴权**：HTTP 侧单令牌 `X-Api-Key`（安装时随机生成，可在 app 内重置）。OAuth 过重，v1 不做；LAN 暴露场景的最低防护。
- **LLM 不在本仓**（ai-app-split，2026-10-14 M2 落地）：`llm_summarize`/`llm_tags`/`block_summarize`/`template_apply` 为远程任务集合，只经 `claim_ai_task`/`touch_ai_task`/`apply_ai_result` 三工具由 AI 宿主 App 认领回写；本机保留 ML Kit 全族（OCR/分类/条码/实体/翻译）+ Sherpa 转写 + 非模型任务。SSOT = `docs/design/ai-app-split.md`。
- **保活**：`flutter_foreground_task`（dataSync）。**targetSdk 固定 34**——targetSdk 35+ 的 dataSync 前台服务有 6h/24h 系统限额，与 MCP 常驻冲突（本 app 侧载分发，无商店硬约束）。开机自启放弃（Android 15 限制 BOOT_COMPLETED 拉起 dataSync 服务）。
- **桥接器**：stdio 型桌面客户端无法直连 HTTP，`mcp-bridge/stdio-bridge.mjs` 做 stdin/stdout ↔ HTTP 转发（含 SSE 解包、token 注入），零依赖纯 Node ≥18。

## 测试

- `test/mcp_server_test.dart`：真 HTTP 起服（端口 0）验证握手/通知/错误码/工具闭环/鉴权；VM 下用 `sqflite_common_ffi` 工厂
- `test/mcp_tools_test.dart`：42 工具面契约（含 readOnlyHint 声明、AI 可见性过滤、edit_locked/乐观锁拒写）
- `test/wal_two_conn_test.dart`：主/binder 双连接并发写（busy_timeout=5000 缓解实证）
- `mcp-bridge/e2e-check.mjs`：mock 上游 + 真桥接进程的端到端自检

## 已知边界（后续迭代）

- FTS5 未建，检索走 `LIKE`（个人数据规模够用；V3 项）；`item_embeddings` 表已建但无检索消费方（向量三步走 Phase 1）
- 图片 base64 内联上限 **512KB**，更大附件返回 `mcp-blob://` URI 经 `resources/read` 取字节（避免 Binder/HTTP 事务撑爆）
- 本地无 LLM：`summarize_item`/`extract_tags` 等入队后需 AI 宿主 App 认领才有产出；宿主未就绪时任务滞留 pending（占位守卫保证不被本机管线吞掉）
- 队列无自动退避重试：失败任务置 failed + `last_note` 明因，可手动 reprocess；卡死的 processing 任务由 `reclaimStaleTasks`（30s 无心跳）回收
- 附件文件删除（`delete_forever`）是文件系统副作用，不随事务回滚——故禁止混入批量
- 鸿蒙端：需 flutter_flutter fork + 插件 ohos 化（receive_sharing_intent / flutter_foreground_task 均需社区版或自写），未开始
