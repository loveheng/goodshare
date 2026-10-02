---
status: active
updated: 2026-10-02
---

# 拾贝（goodshare）V2 需求文档：离线双态 AI 管线（收敛版）

> 版本：V2.1（2026-10-02 收敛重写，承接 `product-requirements.md`）
> 本版只记录**未完成**的 V2 需求；已落地部分收敛为 §1.2 基线清单备查，不再展开设计。技术路线已对齐 2026-09-28 拍板的端侧 LLM 方案，**推翻**上一版「仅调用系统模型、零下载」路线（见 §2）。
> 关联文档：`../product/product-requirements.md`（全局 PRD）、`../design/on-device-llm.md`（端侧 LLM SSOT）、`../architecture/human-ai-parity.md`（无头架构）、`../guide/mcp-integration.md`（MCP 接入）。

## 1. 目的与范围

### 1.1 本期目标（剩余范围）

上一版 V2 的基础设施（AI 接口抽象、队列调度门控、能力探测、端侧 LLM 引擎）已全部落地，但 **AI 从未真正参与摄入后的内容重构**——聊天/URL 摄入自动入队的任务至今由占位实现消化。本期把 LLM 接进管线，完成五个需求：

| 编号 | 需求 | 一句话 |
|---|---|---|
| R1 | 摄入自动双态重构管线 | chatlog / URL 摄入自动跑端侧 LLM：降噪、双态产出、自动打标 |
| R2 | 隐私打码层 | LLM 产出必经本地规则层，身份证/银行卡默认打码 |
| R3 | 通用截图解析 | OCR → LLM 领域判定 → 领域 Schema（发票/名片/聚会计划） |
| R4 | 便签编辑器 AI 增强 | 错别字校验、Diff 高亮、一键文风切换 |
| R5 | 温控节流 | 设备过热暂停 AI 认领，降温恢复（调度门控补全） |

多源健康数据接入与 `health_record.v1` 仍推迟 V3（2026-09-27 决策），本文不再覆盖。

### 1.2 已完成基线（不在本期范围，简列备查）

以下上一版 V2 条目已落地或被后续决策覆盖，实现细节以代码与各自 SSOT 文档为准：

- **AI 接口抽象与可插拔**（原 §3.8）：`AiReconstructor` 接口 + `ReconstructorRegistry.resolve()` + `PlaceholderReconstructor` 占位回退；写路径全部收口 `ItemActionHandler` 命令化（SSOT：`../architecture/human-ai-parity.md`）。
- **设备状态感知调度**（原 §3.6 大部分）：`AiQueueService`——电量/充电门控（`canProcess`）、内存压力暂停 + processing 回滚 pending、前台服务保活、通知栏进度。
- **能力探测与门控**（原 §3.7）：OCR/转写一次性检测持久化；LLM 引擎动态探测（`isAvailable` 不持久化）+ 入队前预检；不可用回退占位、UI 明示。
- **端侧 LLM 引擎**：LiteRT-LM Kotlin 真推理（Android）/ FoundationModels 骨架（iOS），Qwen2.5-1.5B 模型下载管理，手动摘要/关键词/图片描述已可用（SSOT：`../design/on-device-llm.md`）。
- **OCR / STT**：ML Kit 中文 OCR（v1 分期调整提前）、sherpa 端侧转写 + 手动触发链路。
- **MCP `reparse_item`**（原 §6）：以 `reprocess_item` 语义落地，工具族已 16+。
- **便签编辑器非 AI 部分**（原 §5 底座）：块编辑器、块↔文本映射、行内媒体块均已落地。
- **Schema 增量登记**（原 §7 占位）：`invoice.v1` / `contact.v1` / `event.v1` 已在 `machine_json_validator` 登记必填字段。

### 1.3 范围对齐、加工主体与实施排序（2026-10-02 评估+拍板）

内容来源重心已从网页转向 **app 分享**，且**文本大头在媒体提取**：音视频转写（1h ≈ 45KB）> 图片 OCR > 网页抓取（收益下降中，维持现状不投入）> 人手写便签（最小）。OCR/转写文本已入库可搜（human_md），加工链路已全通但全手动。

**加工主体拍板（2026-10-02）**：人类端只做**当前需要**的即时操作（读、搜、单条处理、人工修订）；**繁重加工（转写/OCR/摘要/打标/结构化）交给桌面 AI 客户端经 MCP 驱动**——Human-AI 对称性（`../architecture/human-ai-parity.md`）的产品化推论：AI 是「头」，UI 是按需入口。

> 范围边界（2026-10-02 拍板）：MCP 客户端分域授权（按客户端发 token + 工具/数据/内容形态三维 scope，processed 档与 R2 打码层协同）经评估成立但**划入 V3**——V2 维持单 token + Vault 隔离的信任模型，先把 MCP 加工链路走通。SSOT：PRD §9 V3 行。

| 分享内容 | 理解层现状 | 对应需求 |
|---|---|---|
| 视频/音频（转写=文本大头） | 链路全通但 UI 手动；**MCP 无 transcribe 工具** | 配套④ + R1 |
| 图片/截图（OCR 次大头） | OCR 仅 UI 手动；**MCP 无 ocr 工具** | 配套④ + R3 |
| 聊天截图（→chatlog） | `parse_chatlog` 落占位 | R1 |
| PDF/文档 | 抽取器已建、未接队列 | 配套① |
| 公众号等真网页链接 | 离线抓取正文有效 | R1（叠加摘要） |

**配套销项**（不占 R1–R5 编号，追踪于 `context/todos.md`）：

1. **document 归一化接线**：`taskActionFor(document)` 由 null 接上队列，文件类分享自动出可读正文（content-pipeline §9 既有 Phase，接口位已存在，半天级）。
2. **预置链实施**（ui-spec §4.3/§4.4 拍板）：**随加工主体拍板降级**——人类端只保留按需轻量入口，排序殿后；预置内容仍建议含「转写并摘要」「OCR 并打标」。
3. **图文同分享文案修复**：receive_sharing_intent 只取 URI 丢文案；需 fork 插件或自写 intent 解析（原 misc 低优，随 app 分享为主升级）。
4. **MCP 媒体加工工具补齐**：新增 `transcribe_item` / `ocr_item`（动作层 `TranscribeCommand` / `OcrCommand` 已在，仅补工具定义与 CommandActor 门控核查）——最大两块文本来源当前 AI 够不着，是「MCP 优先」的前置条件。AI 编排无需新增链式基建：命令入队 + `get_item.last_task` 轮询闭环已具备（R1 可观测规则）。

**实施排序**：配套① → 配套④ → R1（LLM 通用重构器，第一消费者=媒体链：转写/OCR 产出 → 摘要+打标；R2 打码随 R1 上）→ R3 → 超长文本 Phase 2 分块 → Phase 4 向量（触发条件=媒体条目量）→ 配套③ → 配套② → R5 → R4。

## 2. 技术路线（现行口径）

**上一版「不下载、不内置任何大模型，仅调用系统级 on-device 模型」的硬约束已废止**（2026-09-28 拍板）。现行路线：

- **Android**：LiteRT-LM Kotlin 运行时 + Qwen2.5-1.5B（q8，~1.5GB）模型包，设置页按需下载；SoC 感知 NPU/GPU/CPU 降级为二阶段目标。
- **iOS**：FoundationModels framework（iOS 26+ / A17+）系统模型，零下载；不可用降级。
- 双端接口契约、模型目录、下载管理、推理桥细节以 `../design/on-device-llm.md` 为唯一事实源，本文不重复。

由此派生的口径修正（覆盖上一版对应条目）：

- 「断网验收」= **模型包在位后**断网完成全部管线（下载是一次性设置动作，不参与验收断言）。
- 「不触发任何大模型下载」验收项作废，替换为「模型未在位时全链路回退占位、不卡队列、UI 明示」。
- 系统模型碎片化风险（原 §8）随 LiteRT-LM 路线消解：Android 不再依赖 AICore/Gemini Nano。

## 3. R1 · 摄入自动双态重构管线

### 3.1 现状与缺口

摄入链路已按类型自动入队（`Repository.taskActionFor`）：chatlog → `parse_chatlog`、url → `summarize_url`。现状分两类：

- **url**：`OcrReconstructor` 已按 `itemType == 'url'` 认领，自动离线抓取网页正文写入 `human_md`（保结构 Markdown）——**不是占位**，但止步于正文抓取，无 LLM 摘要/实体/打标。
- **chatlog**：无实现认领，落 `PlaceholderReconstructor`（原样复制 raw → human_md）。且 chatlog 条目本身来源有限：聊天截图经 OCR + AI 重分类（image→chatlog）或 MCP `add_item` 指定；**纯文本 TXT 分享归 document、不进本管线**。

端侧 LLM 目前只接了显式手动任务（`llm_summarize` / `llm_tags`）。

### 3.2 需求

新增 **LLM 通用重构档**：`LlmReconstructor`（或独立通用重构器）认领 `parse_chatlog` / `summarize_url` 两类任务动作，引擎 `isAvailable` 为真时产出，否则回退占位（与既有回退口径一致，绝不卡队列、不置死信）。

| 任务 | 产出 |
|---|---|
| `parse_chatlog` | `human_md` 降噪 + 议题整理；`machine_json` 可为空（无领域 Schema 要求）；自动标签 |
| `summarize_url` | 在既有「离线抓取正文」之上叠加 LLM：标题 + TL;DR + 关键实体；自动标签 |

- **自动打标**：管线尾段由 LLM 从内容推断 2–3 个标签并入 `tags`（复用 `ExtractTags` 现有合并逻辑——只增不删，保留人工标签）。
- **与手动任务的边界**：自动管线**只覆盖摄入时的按类型通用重构**；通用 `llm_summarize` / `llm_tags` 手动命令语义不变（2026-09-28「摘要/关键词不自动入队」决策收窄为本口径）。
- **调度纪律**：自动任务照走既有电量/内存门控（低电量停留 `pending`）；推理上下文上限 Qwen 档 4096 token，超长聊天记录的分块处理依赖超长文本 Phase 2（已登记待办），MVP 对超限内容取尾部截断并在 `note` 明示。
- **可观测**：产出/失败原因遵循既有 R1 规则——同一份文案进 UI 任务状态条与 MCP `last_task.note`。

## 4. R2 · 隐私打码层

LLM 产出后**必经本地规则层**（端侧，不外传）：

- 规则：18 位身份证号（regex + 校验位）、银行卡号（Luhn 校验）→ 默认 `****` 打码；规则可配置关闭（设置页已有占位开关「身份证 / 银行卡默认打码」，本期接线）。
- 作用面：`human_md` 与 `machine_json` 同步打码；`raw_content` 保留明文。
- 落点：管线内 LLM 产出与写库之间（动作层管辖，UI/MCP 换入口也绕不过）；`ReconstructResult.masked` 字段（已有占位）兑现为真实值。

## 5. R3 · 通用截图解析（ScreenshotParser）

面向不开放 API 的厂商 App 截图：**不写每家正则**，OCR → 端侧 LLM 推断结构，天然跨厂商。

```mermaid
flowchart LR
    IMG[厂商截图] --> OCR[ML Kit OCR 中文]
    OCR --> TXT[文本块]
    TXT --> LLM[端侧 LLM 领域判定 + 结构化归一]
    LLM --> JSON[machine_json: 领域 Schema]
    JSON --> MD[human_md 要点卡片]
```

| 场景 | Schema | 人类态 |
|---|---|---|
| 发票 | `invoice.v1`（amount/date/merchant/tax/items） | 报销要点卡片 |
| 名片 | `contact.v1`（name/phone/org/title） | 联系人速记 |
| 聚会计划 | `event.v1`（when/where/attendees/action_items） | 待办 Checklist |

- **入口**：沿用 `task_action='ocr_and_extract'`（`OcrCommand` 手动触发——保持 2026-09-28「图片摄入不自动 OCR」口径）；本需求把该任务从「仅 OCR 出文本」扩展为「OCR → LLM 领域判定 → 套 Schema → 双态产出」。
- **Schema**：`invoice.v1` / `contact.v1` / `event.v1` 登记已在 `machine_json_validator`，本期补全字段集定义并打通产出链；LLM 判定失败/置信不足 → 退回纯 OCR 文本结果，`note` 明示。
- **隐私**：OCR 文本与 LLM 推理全程端侧，不外传。
- 健康截图（`health_record.v1`）随健康接入顺延 V3，届时复用本管线扩展 Schema。

## 6. R4 · 便签编辑器 AI 增强

依赖 R1 的 LLM 档；模型不可用/调用失败时降级为纯手动编辑并在 UI 明示，不阻塞编辑。底座（块编辑器、块↔文本映射、`UpdateItemCommand`）已具备：

| 能力 | 实现方式 |
|---|---|
| 离线错别字/语法校验 | 选中或保存时送 LLM 校对，返回疑似错误区间**仅高亮提示，不自动改写** |
| Diff 高亮 | 人工编辑与上版 `human_md` 逐行 diff（**本地算法，非 AI**），修改处高亮，可一键还原上版 |
| 一键文风切换 | LLM 按预设改写（口语→职场等），产出**先 Diff 预览、确认后写入**；写入走 `UpdateItemCommand`（人类干预同源，乐观锁生效） |

## 7. R5 · 温控节流（调度门控补全）

- 监听 Android `ThermalStatus`（API 29+）/ iOS `ProcessInfo.thermalState`；**moderate 及以上**暂停 AI 任务认领（任务停留 `pending`，非 failed），降温后恢复。
- 接入现有 `AiQueueService` 门控体系，与电量/内存压力信号同构（`canProcess` 新增温度维度）；过热时设置页/通知给出提示。

## 8. MCP 与 Schema 增量

- **MCP 零新增工具**：模型升级后的重放由既有 `reprocess_item` 承担；截图解析复用既有 OCR 触发链；所有产出经 `get_item` 可读、失败经 `last_task.note` 可观测（Human-AI 对称性既有规则）。
- **Schema 增量**：`machine_json` 取值扩展为 `invoice.v1` / `contact.v1` / `event.v1`（登记已在，补全定义）；**无需新建表**。

## 9. 风险与开放问题

| 项 | 风险 | 缓解 |
|---|---|---|
| 端侧 1.5B 模型质量 | 降噪/结构化抽取准确率弱于云端 | 提示词 + Schema 校验，失败回退占位；`reprocess_item` 手动兜底；note 明示原因 |
| 上下文上限 | Qwen 档 4096 token，长聊天记录放不下 | MVP 尾部截断 + note 明示；长期走超长文本 Phase 2 分块 / Phase 4 Map-Reduce（已登记待办） |
| OCR 漂移 | 个别厂商截图排版怪异 | OCR 文本 + LLM 容错 + 判定失败退回纯 OCR 文本 + 手动重触发 |
| 温控探测碎片化 | 厂商 ROM 热状态上报口径不一 | 探测失败按「不节流」处理（宁多跑不误停）；真机逐 ROM 验证 |
| Diff 还原与编辑锁冲突 | 一键还原上版可能覆盖他人/AI 更新 | 还原动作走命令层，带 `expectedVersion` CAS，冲突提示 |

**开放问题（待决策）**：① 自动打标的标签词表是否需要约束（自由生成 vs 既有标签池优先）；② chatlog 双态重构是否需要 `machine_json` 领域 Schema（当前可为空）；③ 文风预设清单；④ URL 摄入在抓取正文后是否自动跑 LLM 摘要（涉及收窄 2026-09-28「摘要不自动入队」决策，见 `context/pending-confirm.md` 台账）。

## 10. 验收标准

- [ ] 模型包在位 + 断网：一条 chatlog 条目（聊天截图经 OCR + AI 重分类，或 MCP `add_item` 指定）入队后自动产出 `human_md`（去噪+议题）+ 2–3 标签，`is_processed=1`。
- [ ] 模型包在位 + 断网：分享一条 URL → 自动产出标题 + TL;DR。
- [ ] 模型未下载/引擎不可用：同场景回退占位（原样 human_md），队列不卡、UI 明示「端侧 AI 未启用」。
- [ ] 身份证/银行卡号出现在 LLM 产出中 → `human_md`/`machine_json` 默认打码，`raw_content` 不动；设置开关关闭后不打码。
- [ ] 发票/名片截图手动触发识别 → 产出对应领域 Schema `machine_json` + 要点卡片 `human_md`；OCR/LLM 失败 → 状态条与 `last_task.note` 同文案明示原因。
- [ ] 便签编辑：错别字校验只高亮不改写；文风切换先 Diff 预览、确认后写入；diff 还原在版本冲突时正确报错不覆盖。
- [ ] 设备过热（moderate+）→ AI 任务停留 `pending`，降温自动恢复，全程不崩溃。
- [ ] 全流程端侧完成，无任何云端推理请求。
