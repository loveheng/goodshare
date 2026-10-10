---
dev-loop: memory
format: v1
epic: v2-pipeline
total-merged: 1
last-merge: 2026-10-10
---

# v2-pipeline · V2 离线双态 AI 管线（R1–R5）

- [挂载] docs/product/v2-requirements.md

## 目标
- R1 URL 摘要（**二次收敛：串联式单任务**）：OcrReconstructor 抓正文后原地调 `summarizeUrlHead`——头部 1500 字符截断直出 TL;DR+2–3 标签，同一任务一次落库；无链/无闸/无开关，模型不在位静默跳过
- R2 隐私打码层（已落码，**硬编码恒开**）：AI 产出通用出口打码（D1，无开关）
- ~~R3/R4~~砍除、~~R5~~除名、~~chatlog 整理~~砍、~~D3 一刀切回退~~改头部截断、~~跨任务链+双闸~~改串联（两次收敛拍板：端侧 1.5B 只干小而稳的活，重活归桌面 MCP；分布式调度思维不上本地队列）
- 收敛后本期范围 = R1(串联摘要)+R2(打码)，均已落码；真机验证后本期收官

## 前置决策（2026-10-09 拍板，台账已清账）
- **D1 打码作用面=通用出口**：打码层挂 `_applyAiResult`（human_md 落库前），覆盖所有 AI 写路径含占位回退；raw_content 保留明文
- **D2 自动打标=直接进 tags**：沿用「并集只增不删」，prompt 限定 2–3 个且优先复用既有标签池
- **D3 超长超限=回退占位**：4096 ctx 放不下时占位 + note「内容超长待分块」，Phase 2 分块后解锁
- **D4 URL 自动摘要=收窄成立 + 独立开关**：抓正文后自动 LLM 摘要+打标，「自动摘要」开关默认开（与 urlFetchEnabled 同构）；关闭回退仅抓正文

## 进度
- [2026-10-09] epic 立项（::bind 自 goodshare 切出；一期已收官归并，工作树净 8eac00b）。先解决前置项 D1–D4 拍板，再开工 R1。
- [2026-10-09] R1+R2+D4 全量落码（privacy_mask.dart 身份证 GB11643 校验位/银行卡 Luhn 纯函数挂通用出口；QueueConsumer 抓取完成链入）；D4 链式自链死循环双闸修复（产出特征闸+轮内单链闸），后随二次收敛删除。
- [2026-10-09] V2 收敛减法：R3/R4/R5 砍除、R1 砍 chatlog 整理（长 OCR 碎片超 4096 ctx 产出不可信）；二次收敛四点——D3 改**头部 1500 截断直出**、链式改**串联式单任务**（OcrReconstructor.summarizeHead 回调原地调 LlmReconstructor.summarizeUrlHead，删跨任务链+双闸+开关）、开关收敛（自动摘要/打码开关删，打码硬编码恒开 isMaskEnabled=()=>true）。
- [2026-10-10] P0 收尾：summaryMd 打码漏洞补齐（`_applyAiResult` summary_md 直写通道绕过 D1 出口——TL;DR 是正文头部复述产物最易外露，改过 `maskSensitiveText` 与 human_md/machine_json 同口径）；v2-requirements §9 风险表 D3 行对齐二次收敛口径。
- [2026-10-10] P1 三项收编：①`get_item` 契约违约修复（itemToJson 补 `summary` 字段）；②摘要头部清洗 `_prepareHead`（剥代码围栏/Markdown 链接只留 text/段落边界贪心取 ≤1500，保真修正链接 URL 稀释头部假设）；③摘要正文版本锚 schema **v22**（`summary_anchor` 列=写摘要时 effectiveBody 的 md5 + `isSummaryStale`，itemToJson 暴露 `summary_stale`；不用 version 号做锚——tags/翻译任何写入都 +1 会假过期）。
- [2026-10-10] 真机排障定案：「模型已下载但提示未下载」根因 = release R8 混淆改 `com.google.ai.edge.*` 类名致 litertlm JNI FindMethod mid==null 直接 native abort（SIGABRT，进程被杀）；诊断路径 MCP 直连 list_jobs note → logcat tombstone；修复 = proguard keep `com.google.ai.edge.**`（注释含根因+上游 issue #2406）；arm64 拆分包（versionCode 10065 对齐设备）已装机。
- [2026-10-10] 验证：analyze 0 issue / 全量 780 绿 / docs-lint OK。

## 断点
- [断点] **P0/P1 收编 + 真机排障完成**（summaryMd 打码 / get_item summary 契约 / 头部清洗 / 版本锚 v22；「模型未下载」误报根因=R8 混淆致 litertlm JNI abort，proguard keep 已修，arm64 拆分包已装机，全量 780 绿）。下一步：**用户真机复测**（分享 URL → 摘要产出，首测引擎加载需等待）→ 收官本期。
