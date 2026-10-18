---
status: active
updated: 2026-10-15
---

# 内容生产模板（AI 托管 + 人类消费）

> SSOT 声明：本文档是「内容生产模板」功能的设计与口径 SSOT——双视图派生、ADR（管理权归 AI）、P2 只追加回写、授权断点口径、详情页呈现规约。过程记忆在 `context/epics/ai-template/`；远程任务接缝契约见 [ai-app-split.md](ai-app-split.md) §3；冲突时本文档对**模板域**优先。

## 1. 定位与范围

- 语义 = **内容生产模板**（会议纪要 / 日记…）：`templates.body_md` 为**单一事实源**，双派生——人类视图渲染完整样式（只读预览页）、AI 视图为 skill 文件（`goodshare://templates/{id}` resource 派生，只读）。
- goodshare 持数据 + MCP 是唯一对 AI 能力面；模板 CRUD（`list_template`/`create_template`/`update_template`/`delete_template`）仅对 MCP（AI）开放。
- **P1（2026-10-14 已落地）**：数据模型（schema v23：`templates` 表 + `inbox_items` 模板产出三列）+ Repository CRUD + MCP 四工具 + skill resource + `get_item` 暴露 + 人类只读预览页（`TemplatePreviewPage`）+ `template_test`。
- **P2（本文档主体，2026-10-15）**：存量内容「按模板处理」——UI 提交待办 → 宿主认领 → 回写**只追加**。

## 2. ADR：模板管理权归 AI、人类仅消费（有意不对称）

- **采纳**（2026-10-14 拍板，SSOT = context/decisions.md「ai-template」）：管理权归 AI、人类仅消费。若按 Human-AI 对称让人类也能建/改模板，「AI 托管模板」定位不清且成双写源。
- 边界澄清：这不是破 R2——R2 防「人与 AI 走不同落库逻辑」，不是「谁都能触发」；模板写逻辑仍单一出口（`ItemActionHandler`），分层只在**触发权**。
- `origin` = `'ai' | 'official' | 'user'`：`'user'` 数据模型首版即支持但**暂不放开**（放开仅加 UI、不动 schema）。
- `template_apply` 是**消费**非管理（人类 actor=ui 可触发，与摘要同构）；`template_output` 与 `summary_md` 语义分离、从首版独立，绝不混用。

## 3. P2 · 只追加回写（硬约束）

用户口径：**对用户的文本不做修改，只是追加内容**。

- **数据结构**（P1 已建）：产出落独立列 `template_output` / `template_id` / `template_output_anchor`（schema v23），与 `human_md`/`summary_md` 平级并列；原文 `human_md`/`raw_content` 一个字不动，UI 在正文下方以「模板产出」区展示（§5）。
- **回写路径**（P2 实现）：`_applyAiResult` 对 `template_apply:<id>` 任务**分支早退**（镜像 clip / 块任务先例）——只写模板三列（过打码层 + 版本锚），`human_md`/`is_processed`/`tags`/`machine_json`/`facets`/`translated_md` **零触碰**；无产出（宿主带 `note` 收尾）时连模板列也不写（不清空旧产出）。
- **为什么不用 rawEcho 间接保护**：通用路径靠「回显 rawContent 判等保留正文」，但 `human_md` 为空的条目会被填入 rawContent（= 改了用户文本）——只追加语义必须**结构上保证**，不靠技巧。
- **版本锚**：`template_output_anchor` = 写入时 `human_md` 的 md5；失配 = 产出过期（`template_output_stale`），UI 明示（§5 规约 4）。
- 模板删除不影响既有产出（松散关联无 FK，产出作归档保留）。

## 4. 授权断点：ai_visible 门禁与人类显式触发

**断点事实**：人类笔记默认 `ai_visible=0`（v20 口径：AI 读门禁）。LLM 迁宿主后，UI 触发的 `summarize`/`extract_tags`/`template_apply` 入队后，`claim_ai_task` 按 `aiVisible:true` 读条目 → 返回 `not_found` → 任务卡死循环——**功能对默认场景不可用**（M2 后通用断点，非 P2 独有）。

**P2 口径（防呆下沉，2026-10-15 拍板）**：

1. 授权判定**下沉到入队口**：远程任务入队点（`_summarize` / `_extractTags` / 块摘要 / `_templateApply`）按主体门禁——`actor==ai` 且 `ai_visible=0` → 拒（`forbidden` + hint「在手机端详情页开启『对 AI 可见』」）；`actor==ui`（人类显式触发）= **对该任务的一次性授权**，不设限。
2. `claim_ai_task` **信任已入队任务**：byId 去掉 aiVisible 过滤（Vault / 已删天然挡 + `not_found` 兜底）——入队口已把住 v20 读门禁，读取侧不复检。
3. 边界不变：Vault 条目 UI 触发即被 `_require` 拒（不可见）；MCP 发起仍守 ai_visible；`ai_editable` 写门禁与本任务无关（模板回写是 pipeline 主体）。

## 5. 详情页呈现规约（HCI 评估结论，2026-10-15）

评估基线：mymind 视觉基准（ui-design §2）、详情页 = 一篇文章而非仪表盘、chrome 极低、骑框签分区语言（`section_legend.dart` SSOT，禁止手写）。

| # | 规约 | 理由 |
|---|---|---|
| 1 | **入口降权**：模板处理入口用 18px 图标按钮（`auto_awesome`，`onSurfaceVariant`），与摘要/标签的 refresh 同权重；禁用 TextButton.icon（主色文字按钮） | 同页三张骑框签卡必须一种动作语言；橘红强调色只用于「需用户决策的动作」，不用于偶发重活入口 |
| 2 | **渐进披露**：无产出时不渲染「模板产出」卡，仅在标签卡下方留一行轻入口「按模板处理 →」；首次有产出后升级为完整骑框签卡 | 模板处理是罕见重活，恒空卡 = 每张详情页底部白挂半屏空卡，稀释正文焦点、违背「一篇文章」形态 |
| 3 | **选择器 = 定制 BottomSheet**：行 = 模板名 + 描述 + origin 徽标（AI 托管/官方）+ 行尾「预览」（接 `TemplatePreviewPage`）；底部固定「按模板处理会交由 AI 生成新内容，你的原文不会被修改」 | SimpleDialog 只有裸名列表，与 mymind 定制皮肤不协调；「原文不改」是用户核心顾虑，须在决策点明示 |
| 4 | **状态与元信息完备**：任务进行中显示「模板处理中…」；队列页/待办条可读名「模板处理·<模板名>」；产出卡显示所用模板名；`template_output_stale` 时卡内一行「正文已修改，此产出可能过期」+ 重跑图标；已有产出时重处理前确认「将覆盖当前产出」 | R1 可观测 + 单槽覆盖必须让用户知道当前产出是谁的、何时过期 |
| 5 | **保留不动**：骑框签分区语言、与摘要/标签平行并置不互斥（detail-two-zone §3）、只追加独立列结构 | 既有 SSOT 合规部分 |

## 6. 远程任务接缝（P2 用量）

- **入队**：`TemplateApplyCommand`（ui 触发）→ `template_apply:<templateId>`；校验条目/模板存在 + 正文非空（`bodyText`，图片/音视频须先 OCR/转写）；同条目同模板 active 任务在队即拒（防连点重复）。
- **认领**：`claim_ai_task` 对模板任务返回 `template_id`（宿主免解析动作串）+ `text`（条目正文 `human_md ?? raw_content`）+ `version`。
- **执行**：宿主 `resources/read goodshare://templates/{id}` 取 skill → 按模板结构处理 → `apply_ai_result{template_output, template_id, expected_version}` 回写；打码/乐观锁/note 与既有任务同口径。
- **可观测**：`get_item` 的 `template_output`/`template_output_stale`/`template_id`；`get_job_status`/`list_jobs` 的 `last_task.note`。

## 7. 验证口径

- **只追加**：apply 前后 `human_md`/`raw_content` 逐字相等（含 `human_md` 空条目）；`is_processed` 不翻动；无产出 note 收尾不写任何列。
- **授权**：`ai_visible=0` + MCP `summarize_item` → 拒（forbidden + hint）；UI 触发 → claim 成功读到 text。
- **呈现规约** 1–4 逐条落地；`flutter analyze` 0 issue / 全量测试绿。
