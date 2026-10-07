---
dev-loop: devlog
format: v1
epic: workspace
total-merged: 0
last-merge: 2026-10-05
---

## 进度（追加 0）

<!-- 追加区：协议见 ~/.agents/skills/dev-loop/SKILL.md §2；≥5 条自动归并 -->
- [2026-10-05] [变更]: 工作区删除守门+重命名落地（D-WS1=B快捷删/D-WS2=同守门/D-WS3=重命名随批，docs/design/workspace.md draft→active）：DeleteWorkspaceCommand 增 ackNonEmpty（toJson/fromJson 同步）；守门下沉 _deleteWorkspace——非空无 ack 拒绝 invalidRequest（计数与列表同口径排除 Vault/已删，hint 带条数与去向）、非 ui actor 携 ack 拒绝 forbidden（ack 只认人类 UI，D-WS2 对称）；MCP delete_workspace 描述同步明示。UI：工作区卡长按底部弹层（重命名/删除，仅列表层可达）；重命名复用 WorkspaceCreatePage（initialName 预填+隐藏创建定位语+「保存」钮）；删除 B 快捷删——空区轻确认、非空弹窗明示条数+「保留内容并删除」danger 主钮；Snackbar 回写 CommandResult.note（含保留条数）
- [2026-10-05] [验证]: workspace_test + action_handler_test 45/45 绿（新增守门 3 例：无 ack 拒绝含条数 / ui ack 删壳条目保留关系级联 / ai 携 ack 仍拒；delete_workspace ack JSON 往返）；docs-lint OK；ui-spec §4.11 管理入口小节回写；flutter analyze 本批 footprint 0 issue（余 10 issue 均并行会话富文本/块附件 WIP 文件，未触碰）；真机待验：长按弹层/重命名表单/非空删除弹窗/AI 删非空被拒
- [2026-10-07] [变更]: note-editor-source-of-truth.md 评审修订落地（评估三洞+措辞收口，用户拍板「与旧冲突以今天最新为准」）：① note-editor-unification §2 裁决1 加覆盖声明（线级结构以 source-of-truth 为准，updated 刷 2026-10-07）；② 新增 §2.4 有序重排归属——显示序号 L2 推导不进 buffer、落盘序列化期规整（存量字节不变），解「自动重排 vs L1 禁全篇遍历」冲突；③ 新增 §4.5 buffer↔display 偏移——单坐标系裁决、caret 由判据自保证、选择区 O(1) 钳制、零宽 IME 残留风险+占宽隐藏回退，B-2 对策重写；④ 契约5 拆「纯谓词 + 有界 latch（唯一归 L1）」，消 §3.2 冻结与「零可变状态」自相矛盾，N-1/验收3 同步；⑤ 措辞收口：§2.1 退役范围限定线级（runs 归 §8）、§2.3/§7.5 字节等价限定存量草稿、§3.1「内容为空」→「标记区之后无正文」、§1.3 补两枚 retrofit 现状注记、N-4 指向 §4.6；docs/README 索引条目同步
- [2026-10-07] [验证]: docs-lint 待跑（本轮 docs/design 两文件 + README 实质修改，frontmatter 已合规刷新）；文档纯改动无代码验证项
