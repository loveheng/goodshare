---
dev-loop: devlog
format: v1
epic: ai-app-split
total-merged: 2
last-merge: 2026-10-13
---

（追加区：≥5 条自动归并进 memory.md）
- [2026-10-14] M2 减法落地：拆除端侧大模型引擎——删 `lib/ai/llm*.dart` 五件套 + 双端 `LlmBridge.*` + `litertlm-android` 依赖 + proguard keep；`main.dart` 摘 `llmEngine`/`llmR1`/`LlmModelManager`/`summarizeHead` 装配，`ClipReconstructor` 摘本地摘要步；`settings_page` 摘端侧大模型模型区。保留任务契约：`taskLlmSummarize`/`taskLlmTags`/`blockSummarizeTaskAction` 常量、`summary_md` 字段、`SummarizeCommand`/`ExtractTagsCommand`、MCP `summarize_item`/`extract_tags`/`block_summarize_item`、`claim/touch/apply_ai_task` 接缝（占位守卫 M1 已在 `pendingTasks` SQL 层生效）。验证：`flutter analyze` 0 issue + `flutter test` 790 全过。`on-device-llm.md` 墓碑化指向 ai-app-split.md。备份分支 `keep/on-device-llm` 保留拆除前完整态。
