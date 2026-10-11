---
dev-loop: memory
format: v1
epic: ai-app-split
total-merged: 0
last-merge: none
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
- [2026-10-10] epic 立项，M0 契约文档落盘（docs/design/ai-app-split.md）；v2-pipeline devlog 已归并（用户真机复测待办在该 epic 断点）。
- [2026-10-10] M1 实施完成并验证：三接缝工具 + 占位守卫 + apply 同出口落库，analyze 0 issue / 相关测试 86 项全过；代码未提交（待宿主仓命名一并提交）。

## 断点
- [断点] M1 已提交（d34dda5），宿主仓定名 goodhub。下一步：① AtomGit 建 goodhub 仓 + 最小壳（MCP 客户端 claim→LLM→apply 闭环）；② 闭环真机跑通后开 M2（摘 LiteRT）。
