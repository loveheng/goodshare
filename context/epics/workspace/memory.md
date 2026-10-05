---
dev-loop: memory
format: v1
epic: workspace
total-merged: 0
last-merge: 2026-10-05
---

# workspace · 工作区管理闭环（删除守门与清空链路）

- [挂载] docs/design/workspace.md

## 目标
- 补齐工作区管理缺口：UI 删除/重命名入口（现状 UI 无入口，仅 MCP 可删）
- 交互原则：删工作区 ≠ 删内容（条目保留回「全部」）；非空守门给具体条数与行动出口；列表层单删不做多选；防呆下沉动作层（UI/MCP/AI 同守门，Human-AI 对称）

## 进度
- [2026-10-05] epic 立项（::bind 自 goodshare 切出，冷 bind）：交互评估完成落底子文档 docs/design/workspace.md（draft）——列表层长按单删/非空守门两出口候选（A 强守门深链清空 / B 保留内容快捷删）/进区多选移出转正/计数口径同源排除 Vault、防呆下沉 `_deleteWorkspace`。待拍板 D-WS1（出口策略）/D-WS2（MCP 同守门）/D-WS3（重命名是否随批）。

## 断点
- [断点] 下一步：待装机真机复验（工作区卡长按弹层/重命名表单/非空删除「保留内容并删除」弹窗/AI delete_workspace 非空被拒）；「移出本工作区」批量转正为独立候选待排期（workspace.md §3.3）
