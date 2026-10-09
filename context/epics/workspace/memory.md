---
dev-loop: memory
format: v1
epic: workspace
total-merged: 1
last-merge: 2026-10-09
---

# workspace · 工作区管理闭环 + 编辑器文本真相迁移（混合 epic）

- [挂载] docs/design/workspace.md

## 目标
- 工作区管理闭环：UI 删除/重命名入口、非空守门（删工作区 ≠ 删内容）、防呆下沉动作层（Human-AI 对称）
- 编辑器文本真相迁移（S0–S4）：线级标记进 buffer、坐标随动模型退役（SSOT：docs/design/note-editor-source-of-truth.md）

## 决策（已定）
- [2026-10-05] D-WS1=B 快捷删（空区轻确认、非空弹窗明示条数+「保留内容并删除」danger 主钮）/ D-WS2=MCP 同守门（ackNonEmpty 仅认 ui actor）/ D-WS3=重命名随批（复用 WorkspaceCreatePage initialName）
- [2026-10-07] 编辑器文本真相（用户拍板「与旧冲突以今天最新为准」）：S0 parseLine 单行纯解析原语 → S1 显隐谓词+冻结 latch（旗标门控）→ S2 L1 动作文本真相（enterWithMarker/backspaceOutdent/toggleTodo 纯函数）→ S3 切文本真相（唯一不可逆点，kNoteMarkerReveal→true，坐标随动退役）→ S4 引用/代码块收编；旧模型五件套（seedQuickNote 等）与 applyQuickNoteSpansInput 全删，文本真相成唯一路径
- [2026-10-08] 有序列表编辑期空洞序号：动作层 O(k) 局部重编号（renumberOrderedGroup，仅离散动作点触发，绝不进字符路径）；粘贴多段空行不再折叠（摘除 SpanPasteNormalizeFormatter 空行折叠）；B3 空列表项段首退格出列不并段

## 进度（提炼）
- [2026-10-05] 工作区删除守门+重命名落地（workspace.md draft→active）；真机待验：长按弹层/重命名表单/非空删除弹窗/AI delete_workspace 非空被拒
- [2026-10-07~08] 编辑器文本真相 S0–S4 全落地 + 输入困惑修复（#C 双回车退列/#G 标题淡显/选区套格式/软换行统一入口）+ P0 判据纯函数化（planTextEdit）+ P1a/b 段 id 化与 ComposerDoc 引擎拆解 + ops 日志化（EditOp 环形缓冲，为阶段三 CRDT 铺路）+ B/D 落地；真机 dogfood §7 验收通过（用户「ok」，2026-10-07）
- [2026-10-08] 转写产物治理：usableCues 丢纯标点 cue（修「转写产物只有一个点」）+ 空载荷清旧产物（blockResetKinds）；附件引用态可达性检测落地（uriReachable 平台桥，保守兜底）
- [2026-10-09] mermaid 在线渲染（mermaid.ink dio 直连）落地后因「加载好慢」拍板还原代码块显示，MermaidView 组件保留待复用；纯 Kotlin 渲染器 MermaidKotlin 评估否决（3 星无维护、Maven 坐标不存在）
- [2026-10-09] 详情页分享长文本截断修复：body_screenshot 重写分段滚动拼接（逐屏 toImage→Canvas 纵拼，懒加载 extent 重探有界 3 轮，超 8000px 降 PDF）

## 断点
- [断点] 下一步：真机复验两族——①工作区（长按弹层/重命名/非空删除弹窗/AI 删非空被拒）②编辑器迁移后（长文分段截图拼接/微信观感/附件引用态 lost 转换/内容:// 转写）；「移出本工作区」批量转正已落地（goodshare 10-05 批次）；editor-stage2 backlog 见 docs/design/editor-stage2-backlog.md（P0→P3 推进序）
