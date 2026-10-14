---
dev-loop: memory
format: v1
epic: ai-app-split
total-merged: 2
last-merge: 2026-10-13
---

# ai-app-split · LLM 拆出至 AI 宿主 App

- [挂载] docs/design/ai-app-split.md

## 目标
- LLM 类任务（`llm_summarize`/`llm_tags`/`block_summarize`——同一 LiteRT 引擎的物理绑定三分支）拆至独立 AI 宿主 App；goodshare 此后不再持有 LLM
- 轻量模型（ML Kit 全族）+ ASR/Sherpa + 非模型任务全留原地
- 接缝 = 3 个新增 MCP 工具（claim/touch/apply）+ 占位守卫；宿主 App 独立新仓、产品 SSOT 自管

## 拍板（2026-10-10）
- **方向**：AI 宿主 App = **master（交互式 MCP 客户端）**，非 worker——goodshare 不派活、不知道宿主存在；认领时机/并发/引擎选择（端侧/云端）全由宿主自主
- **范围**：只拆 LLM 两任务（+块分支）；`llm_tags` 与 `llm_summarize` 物理同引擎必须同进退（「留原地」不可行）；「llm_tags 改接 ML Kit 实体提取」为独立候选（已登待办）
- **载荷**：纯文本无附件（LLM 输入 = 正文）；附件通道（FileProvider `content_uri`）延后至 ASR 远程化重开
- **安全**：同令牌（claim 对持令牌者可见，不建第二鉴权层）；`expected_version` 乐观锁照旧；Vault 物理隔离不变
- **顺序纪律**：M1 加法先行（三工具 + 宿主最小壳跑通闭环）→ M2 减法（摘 LiteRT）——不可反

## 进度
- [2026-10-10] epic 立项，M0 契约文档落盘（docs/design/ai-app-split.md）；v2-pipeline devlog 已归并。
- [2026-10-10] M1 实施完成并验证：三接缝工具（claim/touch/apply）+ 占位守卫 + apply 同出口落库，analyze 0 issue / 相关测试 86 项全过；**已提交 d34dda5**（feat(ai-split): 三接缝工具+占位守卫，23 文件 +868，含 epic context 三件与契约文档）。宿主仓命名拍板为 **goodhub**。
- [2026-10-11] M3 接缝扩展提交落盘：capabilities 增 `sampling`+`resources.subscribe`、GET /mcp SSE 下行（ResourceSubscriptionHub，server 级全局订阅 + updated 广播）、Repository.itemChanges 变更事件流、`ai_suggest_tags` 只读消费工具（工具总数 38）；sampling 反向推理（SSE 流内 `srv_` 帧 + 宿主 POST 回程）；修复 HttpResponse.bufferOutput 缓冲滞留（SSE 帧即时性）。契约文档本仓 ai-app-split.md 新增 §3.10/§3.11 + 修订 §3.6/§3.8。
- [2026-10-11] 验证口径：goodshare 本仓 795 测试全过 + analyze 0；M3 实施验证与全量测试归属 goodhub 侧 m3-ui-subs-sampling epic 账本。

## 断点
- [断点] 下一步：接缝无活跃改动；M2 减法（摘 LiteRT）待 goodhub 侧下一期排期（候选：端侧 LLM）。后续 goodshare→goodhub 接入形态演进见独立 epic `goodhub-local-plugin`（本地 Binder 插件改造）。
