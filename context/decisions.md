---
dev-loop: decisions
format: v1
epic: global
total-merged: 0
last-merge: none
---

# decisions

## ai-app-split

### [2026-10-10] AI 能力拆出：方向与范围拍板 (src: 用户)
**场景/痛点**：LLM（LiteRT-LM 1.5B）是 goodshare 包体/OOM/JNI 崩溃三大痛点源，且产品方向上需要一个独立的主交互入口 App 承担 AI 能力。
**可选方案**：
- A1 宿主 App 当 goodshare 队列 worker（后台无头）→ 否决：角色颠倒，goodshare 派活、宿主无 UI 无灵魂，用户交互仍在 goodshare，与「独立入口」诉求背离
- A2 好 share 全面去 AI（含 ML Kit/ASR）→ 否决：一刀切伤筋动骨，ML Kit bundled 毫秒级无痛点，ASR 远程化需附件通道（FileProvider）前置工程量大
- **采纳**：分治 + 只拆 LLM——goodshare 保留轻量模型/ASR/非模型任务，仅 LLM 两任务（`llm_tags` 与 `llm_summarize` 同一引擎物理绑死，同进退；「留 tags」不可行）迁至独立宿主 App
**最终决定**：宿主 App = 独立新仓、master/交互式 MCP 客户端（非 worker）；接缝 = 3 个 MCP 工具（claim/touch/apply）+ 占位守卫；附件通道延后至 ASR 远程化；同令牌安全口径；顺序纪律 M1 加法先行 → M2 减法。SSOT = docs/design/ai-app-split.md。
**AI 洞察**：`llm_tags` 看似可独立留原地，实为 LlmReconstructor 同类的 prompt 分支（llm_reconstructor.dart:135 isSummary 分叉）——「摘引擎留任务」物理不成立，拆分边界必须按引擎物理归属划而非按任务名义划；ML Kit 实体提取（analyze_text）才是好 share 侧真正的「轻标签」能力，用户混淆点已澄清并立候选待办。

## misc
