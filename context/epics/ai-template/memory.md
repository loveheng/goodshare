---
dev-loop: memory
format: v1
epic: ai-template
total-merged: 0
---

# ai-template · 内容生产模板（AI 托管 + 人类/AI 双视图）

- [挂载] context/epics/ai-template/todos.md

## 目标
- 内容生产模板（会议纪要 / 日记…）：`body_md` 为单一事实源，双派生——人类视图渲染完整样式、AI 视图为 skill 文件
- goodshare 持有模板数据（事实源），MCP 是唯一对 AI 能力面；AI 经 MCP 建/改/删，人类端只读
- 模板产出（`template_output`）与摘要（`summary_md`）**语义分离、从首版独立**，不走 summary_md
- P2：对存量内容选模板 → 入队 `template_apply` 待办 → AI 经 claim/apply 按模板 skill 远程处理 → 回写 template_output

## 拍板（2026-10-14）
- 语义 = 内容生产模板；数据主权 = goodshare 持数据 + MCP 对 AI；人类入口 = P1 只读预览页、P2 套用产出
- 落点独立：`inbox_items.template_output` / `template_id` / `template_output_anchor`（v23，与 summary 平级不混用），无中间路线
- 双视图同源：`body_md` 唯一源，人类渲染与 AI skill 均派生、零漂移；AI 经结构化 MCP 工具管 `body_md`，skill 文件为派生只读 resource
- ADR（待落）：模板管理权归 AI、人类仅消费 = **有意不对称**；写仍走统一 `ItemActionHandler` 出口（守 R2 同出口，分层只在触发权）
- 复用 ai-app-split 接缝：`template_apply` 入远程集合，宿主 claim → `resources/read` 模板 skill → 处理 → apply 回写
- origin = `'ai' | 'official' | 'user'`：`'user'` 预留但暂不放开（人类编辑入口遵循 ADR 人类只读；数据模型首版即支持，放开时仅加 UI 入口、无需再动 schema）
- 模板 CRUD 走 Repository 直接方法（同 workspace 定位），**不经 ItemActionHandler 条目命令协议**（命令协议面向条目内容写）；仅 `template_output` 写入（P2 apply）走命令协议
- schema 微调（2026-10-14）：`template_id` 松散关联无 FK（删模板不级联删产出）；`template_output_anchor` 口径与 `summary_anchor` 完全镜像（trim / null 兜底 / md5(humanMd)）

## 断点
- [断点] **P2 已完成（2026-10-14 初版 + 2026-10-15 硬化轮）**：①只追加结构保证——`_applyAiResult` 模板任务分支早退（只写模板三列，human_md 等零触碰；无产出不写列）；②授权断点修复——远程入队点 ai_visible 主体门禁（`_requireAiReadable`：ai 发起守门/ui 显式触发=一次性授权），claim 信任已入队任务 + 回 template_id；③入队互斥（同条目同模板 active 拒）；④详情页呈现规约四条（入口降权/渐进披露/BottomSheet 选择器+原文不改明示/状态与 stale 完备）；⑤SSOT = docs/design/ai-template.md（新建）。验证：analyze 0 + 全量 816 过。**下一步 = P3**：宿主侧真机验收（选模板 → claim → 读 skill → apply 回写只追加），宿主接入归 goodhub 账本。
