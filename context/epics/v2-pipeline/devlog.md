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
