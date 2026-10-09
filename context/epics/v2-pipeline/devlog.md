---
dev-loop: devlog
format: v1
epic: v2-pipeline
total-merged: 0
last-merge: none
---

（追加区：≥5 条自动归并进 memory.md）
- [2026-10-09] [决策]: D1–D4 四项前置拍板全清（pending-confirm 台账 D1-D4 → [x]）：D1 打码=通用出口（挂 _applyAiResult，占位回退也打码）/ D2 自动打标=直接进 tags（并集只增不删 + prompt 限 2–3 复用标签池）/ D3 超长=回退占位（不截断照跑）/ D4 URL 自动摘要=收窄成立+独立开关默认开。R1/R2 设计输入全齐。
- [2026-10-09] [变更]: ::bind v2-pipeline 落盘（memory/devlog 骨架 + 挂载 v2-requirements.md + 断点）。SSOT 修正：v2-requirements.md §9 开放问题④（URL 自动摘要）随 D4 拍板关闭；「摘要不自动入队」（2026-09-28）收窄为「仅 URL 摄入自动摘要，其余手动任务不自动入队」。
- [2026-10-09] [验证]: docs-lint OK（v2-requirements 开放问题④划线+拍板记录回写）；context-lint 0 违规（GROOM 48 条存量/SIZE goodshare 198 行为已登记残留，无新增）；纯文档+context 轮无代码验证项。
- [2026-10-09] [变更]: **R1 摄入自动双态重构 + R2 打码层 + D4 自动摘要开关 全量落码**（D1-D4 拍板兑现）：①R1——`LlmReconstructor` 增认领 `parse_chatlog`/`summarize_url`：chatlog 降噪改写 human_md + TAGS 尾行解析进 tags（D2 并集只增不删，take(3) 兜底）；URL 摘要叠加层不改写抓取正文（summary_md 并列）+ 打标；D3 超 3000 字符回退占位 + note 明示（不截断照跑）②R2——新文件 `lib/ai/privacy_mask.dart`（身份证 GB 11643 校验位 + 银行卡 Luhn 纯函数，边界守卫防误伤长编号），挂 `_applyAiResult` 通用出口（D1：human_md/machine_json 落库前必经，raw_content 保留明文；keepHuman 判定先于打码语义不变）③D4——`AiCapabilities` 增 autoSummarizeEnabled/maskEnabled 两开关（默认开）+ 设置页两 SwitchListTile；`QueueConsumer` 抓取任务完成后链入 summarize_url（onEnqueued 回调 kick）④main 装配：handler.isMaskEnabled / consumer.isAutoSummarize+onEnqueued。
- [2026-10-09] [排错]: **D4 链式自链死循环两轮**——第一版只查 pending 防重，链任务在 pollOnce 同一 while 轮内即被消费再次满足链条件 → 无限链（debug 打印复现上百次 chained）。修复双闸：①产出特征闸（链只由无 summaryMd 的抓取产出触发，LLM 摘要产出带 summaryMd 天然终止）②轮内闸 `_chainedThisPoll`（每轮最多链 1 次，绝对封闭防异常实现自链）。次生教训：`repo.add` 裸方法不入队（入队只在 CollectCommand），测试必须走真实摄入路径；链任务同轮消费完，断言查 `recentTasksOf` 任务历史而非 pending。`recentTasksOf` 为本次新增 Repository 出口。
- [2026-10-09] [验证]: analyze 0 issue；新增 privacy_mask_test 9 例 + llm_reconstructor_test R1 组 5 例 + action_handler_test 打码组 2 例 + queue_consumer_test D4 链 1 例；全量 772 绿。
- [2026-10-09] [拍板/变更]: **V2 收敛减法（用户提出战略-设计割裂评估，AI 对账确认全盘采纳）**——①砍 R4 便签 AI 增强（1.5B 中文校对误报海量、Diff+CAS 协同级管线过度工程；ai_revisions 写回快照属 AI 写回可逆地基保留）；②砍 R3 截图结构化（OCR 可搜可复制已够，发票/名片归桌面 MCP 批处理，validator 登记零成本保留）；③收窄 R1 砍 chatlog 整理（长 OCR 碎片超 4096 ctx 产出不可信；已落码的 chatlog 分支删除、taskActionFor(chatlog) 回归 null、超长闸保留服务 URL）；④R5 温控除名（电量门控+超时熔断+串行队列已闭环，不逐 ROM 死磕）。文档 §1.1/§1.1a/§3-§8/§10 全量收敛改写，开放问题四项全关。本期范围=R1(URL)+R2，均已落码。
- [2026-10-09] [验证]: analyze 0 issue；chatlog 分支删除后全量 771 绿（chatlog 认领测试改写为「不再认领」钉子，D3 超长测试改走 summarize_url）；docs-lint OK。
