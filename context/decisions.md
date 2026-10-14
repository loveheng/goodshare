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

## ai-template

### [2026-10-14] 模板管理权归 AI、人类仅消费（有意不对称） (src: 用户+AI)
**场景/痛点**：内容生产模板需双视图——人类看渲染样式、AI 看 skill 文件。若按 Human-AI 对称（R2）让人类也能建/改模板，则「AI 托管模板」定位不清，且人类编辑入口与 AI 经 MCP 的管理成双写源。
**可选方案**：
- A1 人类也可建/改模板（完全 R2 对称）→ 否决：违背「模板由 AI 管理」定位，双写源难收敛
- **采纳**：管理权归 AI、人类仅消费——模板 CRUD 仅对 MCP（AI）开放，人类端只读预览页；写仍走统一 ItemActionHandler 出口（守 R2「同一落库逻辑」），分层只在**触发权**（谁能发起写）
**最终决定**：模板 CRUD 走 MCP 工具 + handler.execute（R2 同出口），人类端 TemplatePreviewPage 只读无编辑入口；origin 预留 'user' 暂不放开（放开仅加 UI、不动 schema）；template_output 与 summary_md 语义分离、从首版独立（schema v23）；template_id 松散关联无 FK（删模板不级联删产出）。SSOT = context/epics/ai-template/。
**AI 洞察**：这不是破 R2，而是澄清其边界——R2 防「人与 AI 走不同落库逻辑导致状态不一致」，不是「谁都能触发」；模板写逻辑仍单一出口，仅把触发权授予 AI，与 ai-app-split「goodshare 持数据、AI 经 MCP 托管」同构。

## misc
