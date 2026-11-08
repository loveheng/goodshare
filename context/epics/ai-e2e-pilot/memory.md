---
dev-loop: memory
format: v1
epic: ai-e2e-pilot
total-merged: 2
last-merge: 2026-11-07
kind: temp
---

# ai-e2e-pilot（临时）

- [挂载] docs/design/ai-e2e-pilot.md
- [裁决] 领域校验归数据 owner：goodhub 是通用推理/任务管线能力层，不为任何单个服务写适配代码；llm_tags 标签形态校验落 goodshare 的 AI 结果回写动作层（ApplyAiResultCommand / _applyAiResult），不合规即拒绝回写并经 finishTask('failed', note) 可观测，goodhub 仓零改动。
- [准入] S2 能力补丁：摘要/分类共用编排，否决一次性脚本；分层 = 设备可测性 → 薄管道 CLI → 声明式用例 → 工具壳。
- [契约] 触发消费复用生产语义「宿主上线 catch-up」，业务管线零测试专用分支；状态观测走注入端口的结构化快照，logcat 令牌发现失败靠真正冷启动自愈。
- [验收] 断言护栏 + --repeat N 重复采样量化 AI 产出不确定性，不靠放宽断言拿绿；2026-11-06 标签领域校验落地（`lib/action/ai_tags_guard.dart` 纯函数 + `_applyAiResult` 标签并集前整批拒绝 + failed note 带具体坏标签，goodhub 仓零改动）后 tags 3/3 PASS、--case all 2/2 PASS、839 测试全绿。

## 断点
- [断点] 下一步：复跑 --case all 稳定后按 ::done 收尾并走 devlog archive（临时 epic）；跨仓两项（version_conflict 竞态、公共桥端口协商与宿主注入）保留为独立待办，goodhub 通用层零改动
