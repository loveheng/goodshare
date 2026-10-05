---
copilot-context: devlog
format: v1
thread: misc
total-merged: 0
last-merge: none
---

## 2026-10-04 管线回写纳入人类授权（ai_process，默认关闭）

- 新增 `ai_process` 字段（inbox_items 列 + 模型 + 迁移），与 `ai_visible`/`ai_editable`
  同属「AI 可见性分层」。**状态管理集中**：`SetAiProcessCommand` 紧邻
  `SetAiVisible/SetAiEditable`；handler 内 `_setAiProcess`/`_requireAiProcess` 紧邻对应
  editable 方法；UI 三个开关在详情页 `⋯` 面板紧邻排布（`ItemActions.overflowSheet` 分组）。
- **门禁**：端侧管线（`CommandActor.pipeline`，OCR/翻译/摘要/转写/切片）回写人类笔记须
  `ai_process=1`，否则 `ItemActionHandler._applyAiResult` 抛 `forbidden`；队列侧
  `QueueConsumer` 在跑重建前 `skip` 该任务（不写库、不标失败，原因进 note）。
  **默认 0=关闭**，即「授权才处理」，推翻早前「收集即同意、管线豁免」口径。
- `SetAiProcessCommand` 仅 UI 可改（`actor==ui`），不入 `ItemCommand.fromJson`，AI 翻不动。
- 既有管线写回/队列消费测试 fixture 改为 `aiProcess:true` 表达「已授权」；新增门禁单测与
  「未授权→skip」队列单测。四个套件共 79 例全绿。
