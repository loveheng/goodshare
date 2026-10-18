dev-loop: memory
format: v1
epic: instant-sampling
total-merged: 0
---

# instant-sampling · 即时 AI 摘要（sampling 消费产品化一期）

- [挂载] docs/design/instant-ai-sampling.md（内容 SSOT：契约/UI/降级/验收/施工分解 T1-T5）
- [背景] 2026-10-17 评估四轮收敛：协议侧 sampling 已于 M3 全线落地真机验证（ai-app-split.md §3.11），本期做消费面产品化——详情页「即时生成」→ 宿主 LLM 数秒回预览 → 「采用」落库。PC 中转/借电脑推理路径经评估排除（环路风险 + 围栏缺口 + 无价值增量）；对外不新建面，复用 McpRuntime 挂载面
- [拍板] 用户四项（2026-10-17）：D1 一期仅即时摘要；D2 instant 配额独立池 60 次/60min（默认池 20 不变）；D3 maxTokens 维持 1024 全局硬顶；D4 采用/忽略确认卡落库（ApplyAiResultCommand + expected_version，human-ai 对称）
- [接缝] 契约已同轮回写 ai-app-split.md §3.11（消费工具扩族 + pool 扩展字段 + 配额分池口径）；goodhub index.md sampling 行备注同步
- [跨仓] goodhub 侧 T3（sampling.dart 分池：pool 字段 + caps 覆盖表）随本期实施；三处挂载点共用 handler 工厂零改动继承

## 断点
- [断点] **T1 已完成（2026-10-17）**：goodshare 侧 `AiSamplingProxy` + `ai_summarize_now` 工具 + `bodyMd5` 收编 + 契约钉子（analyze 0 / 全量 30 绿）。**下一步 = T2**：详情页 UI 即时入口 + inline loading（骨架 6 行 + 文案轮转 + 主动转后台）+ 预览卡（含时效标注）+ 采用/忽略（P1-1 冲突分级）+ 降级转入队 + mounted 守卫 + 长文预检 + 截断标注 + 预览 transient。T3（goodhub 配额分池，跨仓）与 T1/T2 并行、T4（契约回写 ai-app-split.md §3.11，goodhub index.md 跨仓）随 T1/T3 同轮、T5 收尾。T3/T4 的 goodhub 侧改动需跨仓仓库就位。
