---
dev-loop: devlog
format: v1
epic: v2-pipeline
total-merged: 1
last-merge: 2026-10-10
---

（追加区：≥5 条自动归并进 memory.md）

## 2026-10-10 M1 实施：AI 宿主 App 接缝三工具（ai-app-split.md §3/§4）

**决策背景**：用户想把 App 的 AI 能力拆成独立宿主 App（端侧 LLM 跑那边），经 MCP
Streamable HTTP 自主认领任务——master 侧（本仓）只提供接缝工具，不感知宿主存在。
设计 SSOT：docs/design/ai-app-split.md（M0 拍板：纯文本载荷/无附件/心跳 5s/僵尸回收
30s 复用既有机制/远程任务仅三项）。

**M1 实施内容**：
1. **Repository**（lib/data/repository.dart）：
   - `isRemoteTaskAction()` 远程集合**单点定义**（llm_summarize/llm_tags/
     block_summarize:*）——claim 数据源与 pendingTasks 守卫共用，防双消费漂移。
   - `pendingTasks()` SQL 层**占位守卫**（M2 验收第一条钉子）：排除远程集合。
     不排除的话 M2 换 PlaceholderReconstructor 后会先把远程任务「占位完成」，
     宿主永远 claim 不到。
   - `claimRemoteTask()`：原子认领最旧一条远程 pending（复用 claimTask 条件 UPDATE）。
2. **MCP 三工具**（lib/mcp/tools.dart，34→37）：
   - `claim_ai_task`：空队返回 idle；载荷 task_id/item_id/task_action/text/
     version（乐观锁）；llm_tags 附 human_tags；块摘要 text=块源产物（transcript→
     ocr_text 同消费者口径）、附 block_key。条目不可见时不丢任务，返回 not_found
     让宿主 apply failed 收尾。
   - `touch_ai_task`：刷新 updated_at 心跳（僵尸回收判据复用既有 30s 机制）。
   - `apply_ai_result`：经 **ItemActionHandler 同一落库出口**（actor=pipeline，
     与进程内 QueueConsumer 同一特权身份），组装形状镜像消费者 ReconstructResult
     （摘要→summary_md 并列/关键词→tags 并集/块摘要→block_artifacts 零触碰条目）。
     note 落库取推理产物载荷（与消费者同口径，非 handler 回执）；落库被拒
     （乐观锁/Schema）→ 任务标 failed + 原因落库后 rethrow（e.data.code 供宿主
     自我纠正）。
3. **ApplyAiResultCommand** 补 `{super.expectedVersion}`：宿主回写带乐观锁
   （推理期数十秒，人类慢速编辑可能已改条目）；进程内管线不传 = 零改动。

**验收**：analyze 零问题；mcp_tools_test 34/34 过（新增 5 个：占位守卫钉子、
claim 三载荷+idle+轻量不认领、touch 心跳、apply 三分支落库+note 口径、版本冲突
拒绝+参数校验）；存量 block_summarize 入队测试适配守卫（断言改走 claim 路径）；
工具计数 34→37；全量 786 测试过。

**M2 预告**（下阶段）：摘除 LlmReconstructor + LlmModelManager 注册 → 换
PlaceholderReconstructor（handles 恒真 + 占位 note）；占位守卫保证占位实现
吃不到远程任务；宿主 App 仓库另开（Flutter，LiteRT/llama.cpp 端侧推理 +
MCP 客户端循环）。
