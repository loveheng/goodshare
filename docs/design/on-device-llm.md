---
status: deprecated
updated: 2026-10-14
---

# 端侧 LLM 设计（已废弃）

> [Deprecated 2026-10-14] **ai-app-split M2 减法**：端侧 LLM 引擎（LiteRT-LM /
> FoundationModels、`lib/ai/llm*.dart` 五件套、双端 `LlmBridge`、`litertlm-android`
> 依赖、模型下载管理、设置页模型区）已从 goodshare 整体拆除，本地不再持有端侧大模型。
>
> LLM 类任务（`llm_summarize` / `llm_tags` / `block_summarize`）改由独立 AI 宿主
> App（goodhub）经 MCP 接缝 `claim_ai_task` / `touch_ai_task` / `apply_ai_task`
> 远程认领与回写；`summary_md` 字段与入队命令（`SummarizeCommand` 等）、MCP 触发
> 工具（`summarize_item` / `extract_tags` / `block_summarize_item`）作为任务契约保留。
>
> - 继任 SSOT（LLM 拆分与远程接缝）：[ai-app-split.md](./ai-app-split.md)
> - 本地保留的轻量模型能力：[asr-subtitle.md](./asr-subtitle.md)（ML Kit 全族 + ASR/Sherpa）
> - 历史实现设计（选型 / 架构 / SoC 模型矩阵）：归档于 git 历史（`84b0312` 引入、M2 拆除）
