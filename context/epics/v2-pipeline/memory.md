---
dev-loop: memory
format: v1
epic: v2-pipeline
total-merged: 0
last-merge: none
---

# v2-pipeline · V2 离线双态 AI 管线（R1–R5）

- [挂载] docs/product/v2-requirements.md

## 目标
- R1 摄入自动双态重构管线：chatlog/URL 摄入自动跑端侧 LLM（降噪/双态/自动打标），R2 隐私打码随 R1 上
- R3 通用截图解析（OCR → LLM 领域 Schema）；R4 便签 AI 增强；R5 温控节流
- 实施排序（2026-10-02 拍板）：R1 → R3 → 超长文本 Phase 2 → Phase 4 → 配套③② → R5 → R4

## 前置决策（2026-10-09 拍板，台账已清账）
- **D1 打码作用面=通用出口**：打码层挂 `_applyAiResult`（human_md 落库前），覆盖所有 AI 写路径含占位回退；raw_content 保留明文
- **D2 自动打标=直接进 tags**：沿用「并集只增不删」，prompt 限定 2–3 个且优先复用既有标签池
- **D3 超长超限=回退占位**：4096 ctx 放不下时占位 + note「内容超长待分块」，Phase 2 分块后解锁
- **D4 URL 自动摘要=收窄成立 + 独立开关**：抓正文后自动 LLM 摘要+打标，「自动摘要」开关默认开（与 urlFetchEnabled 同构）；关闭回退仅抓正文

## 进度
- [2026-10-09] epic 立项（::bind 自 goodshare 切出；一期已收官归并，工作树净 8eac00b）。先解决前置项 D1–D4 拍板，再开工 R1。

## 断点
- [断点] 下一步：D1–D4 拍板落盘 → 开工 R1（LlmReconstructor 认领 parse_chatlog/summarize_url，R2 打码层挂动作层）
