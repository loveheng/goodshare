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

### [2026-10-14] 模板应用 = 复刻 llm_summarize 远程任务接缝（派发给 AI 的待办） (src: 用户+AI)
**场景/痛点**：P1 只解决了「模板管理 + 人类只读预览」。模板的真正价值是「选中存量条目 → 按模板 skill 处理 → 产出结构化内容」。若另起派发机制，会与 ai-app-split 的远程任务接缝（llm_summarize/llm_tags/block_summarize）重复造轮子——claim/心跳/回写/打码/乐观锁全要重写。
**可选方案**：
- B1 人类端本地 LLM 直接跑模板 → 否决：本机已摘除 LlmReconstructor（ai-app-split M2），且模板 skill 由 AI 托管、本地无 skill 文件
- B2 新增独立 apply 通道（单独任务表/SDK）→ 否决：与远程集合接缝重复，claim/回写/打码/乐观锁全要重造
- **采纳**：`template_apply:<templateId>` 直接复用远程任务集合——入队后由 claim_ai_task 认领（isRemoteTaskAction 加前缀判定）、resources/read goodshare://templates/{id} 取 skill（P1 已派生）、apply_ai_result 回写 template_output（ReconstructResult 加 templateOutput/templateId 两字段，落 inbox_items.template_output/_id/_output_anchor，与 summary_md 同走打码+版本锚）。
**最终决定**：TemplateApplyCommand（ui 触发，=人类消费模板，不破 ADR「管理权归 AI」——apply 是消费非管理）入队 `template_apply:<id>`；item_detail_page「按模板处理」弹模板选择 → 提交待办 → _AiTaskStatusLine 通用待办条显示「处理中…」；宿主认领后读 skill、按模板结构处理、回写。无新增独占通道、无新 schema 列（v23 已建）。
**AI 洞察**：「选模板套用」本质是「派发给 AI 的一条待办」，与「让 AI 写摘要」同构；把它塞进既有远程任务接缝，零新增基础设施即得 claim/心跳/回写/打码/乐观锁全套能力（R1 同一份可观测状态免费复用）。

## scope

### [2026-10-15] 砍除锁屏/桌面组件与健康/日历抓取（V3 两项） (src: 用户)
**场景/痛点**：PRD §3/§6/§9 将「锁屏/桌面小组件（home_widget）」与「Health/日历静默抓取（health + device_calendar）」列为 V3。用户 2026-10-15 明确放弃：app 实际发展方向已与当初蓝图不同——端侧 LLM 拆给宿主 App、内容加工走 MCP、使用重心在收集/浏览/桌面 AI 联动，Widget 快捷入口与健康数据管线不再有产品位置。
**可选方案**：
- A1 保留待 V3 排期 → 否决：无产品需求支撑，占路线图位误导后续排期
- A2 顺手删 `daily_metrics` 表与占位 → 不采纳：表无读写方、零成本，备份清单已含；删表要动 schema 版本与备份兼容，收益为零
- **采纳**：需求文档三处同步标记砍除（墓碑式注明日期与原因），代码零改动
**最终决定**：PRD（docs/product/product-requirements.md）§3 技术栈映射、§5.3 数据模型注释、§6 模块一/模块四、§7 get_timeline_context 行、§9 V3 路线图（含平台扩展轨）同步标记「砍除（2026-10-15）」；`get_timeline_context` 的 health/events 恒空口径不变（本就是占位）；`daily_metrics` 表保留作时光机上下文占位、不删。SSOT = 本决定 + PRD 对应行。
**AI 洞察**：这是产品收敛的延续——V2 已砍 R3/R4/R5、LLM 拆至宿主，V3「新数据源」轨（健康/日历）本就排在信任栅栏之后且严格晚于安全项，Widget 属「平台扩展轨（随缘）」从未排期。两项砍除后 V3 主线只剩：AI 可视性分级、MCP 客户端分域授权、Vault AES 加密、FTS 检索、NPU 后端实装。

## ai-template-p2

### [2026-10-15] P2 只追加回写 + 授权断点修复 + 详情页呈现规约 (src: 用户+AI)
**场景/痛点**：ai-template P2（存量内容按模板处理）要落地，用户明确约束「对用户的文本不做修改、只是追加内容」。对账发现两个断点：① 现行回写靠 rawEcho 间接保护（宿主回显 rawContent 判等保留 human_md），但 `human_md` 为空的条目会被填入 rawContent——「只追加」不能靠技巧，要结构保证；② LLM 迁宿主后 UI 触发的 summarize/extract_tags/template_apply 入队即被 `claim_ai_task` 的 `aiVisible:true` 过滤挡死（人类笔记默认 ai_visible=0）——功能对默认场景不可用，是 M2 后的通用断点。
**可选方案**：
- A1 模板产出物理拼进 human_md 末尾 → 否决：动用户文本，与「不做修改」直接冲突；且与 P1「template_output 独立列、语义与摘要分离」的 Schema 决策相悖
- A2 claim 侧对模板任务豁免 ai_visible → 否决：豁免放在读取侧=门禁形同虚设，MCP 发起的同类任务也能蹭豁免；防呆必须下沉写入入口
- **采纳**：① `_applyAiResult` 对 `template_apply:<id>` 分支早退（镜像 clip/块任务先例），只写模板三列（打码+版本锚），条目级字段零触碰，无产出连模板列也不写；② 授权下沉入队口——远程入队点 `actor==ai && ai_visible=0` 拒（forbidden+hint），`actor==ui`（人类显式触发）= 一次性授权；claim 信任已入队任务（byId 去 aiVisible 过滤，Vault/已删天然挡）；③ 详情页呈现规约四条（入口降权/渐进披露/选择器 BottomSheet+原文不改明示/状态与 stale 完备）
**最终决定**：SSOT = docs/design/ai-template.md（本次新建）；只追加语义以「apply 前后 human_md/raw_content 逐字相等（含空 human_md 条目）」为测试钉子。同条目同模板 active 任务在队即拒（防连点）。
**AI 洞察**：断点②的根因是「读门禁放在读取侧、而写入侧无门禁」的倒置——v20 设计时所有 LLM 都在本机管线（pipeline 主体天然可信），迁宿主后 claim 成为新的读取面，门禁位置却没跟着搬到入队口。修法不是给 claim 打补丁，而是把授权判定放回「谁发起」：人类显式触发=授权，AI 发起=守 ai_visible——与 set_vault「移出仅 UI」同款主体思想。

## misc
