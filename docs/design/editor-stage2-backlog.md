---
status: draft
updated: 2026-10-08
---

# 阶段二编辑器开发 Backlog（剩余项与路线图）

> 本文件是阶段二编辑器开发的剩余项清单与推进路线，**纯规划、零代码改动**。
> 阶段三（统一自研画布）按战略评估暂不启动；本 backlog 只覆盖阶段二范围内剩余功能。
> 来源：context/epics/workspace/devlog.md（2026-10-07/08）、note-editor-source-of-truth.md、
> rich-text-gfm.md、ui-spec.md §2.2。

## 0. 定位与现状

- **goodshare 当前 = 阶段二**：多 `TextField` 渲染（`ListView.builder` 装载 `_doc.segs`，每段一个 `EditableText`）+ 统一文本真相模型（`ComposerDoc` 纯 Dart 引擎 + `seedTextTruth`/`deriveLineRuns`/`serializeTextTruthSpans`/`enterWithMarker`/`backspaceOutdentAt`/`toggleTodo`/`EditOutcome`）。IME/光标/无障碍仍免费。
- **已交付（2026-10-07）**：S0–S4 文本真相迁移（净删数百行坐标同步层）、B3 用户走查修复、C/G 中困惑修复、D 粘贴空行修复、P0/P1a/P1b 编辑器拆解（段模型 `NoteSeg` + `ComposerDoc` 引擎）。真机 dogfood §7 验收通过（B-1 观感 / B-3 IME / 列表缩进 / 围栏质感四项无异常）。
- **并行会话约束已解除（2026-10-08）**：此前标注的「富文本/块附件」并行会话 WIP 经确认已结束，工作区即当前基线、无他人并发改动。**约束解除**——可直接按 backlog 推进，无需等合入。各代码项状态已在下方「状态」列更新为实测结论。

## 1. 剩余项清单

| ID | 描述 | 来源 | 涉及文件 | 依赖 | 优先级 | 状态 |
|----|------|------|----------|------|--------|------|
| **B1** | 占宽缩进回退：标记区隐藏态改「占宽隐藏」（透明渲染保留宽度），IME 安全优先，代价为标记区占位缩进参差（已知取舍） | §4.5.5 / devlog 23,31 | `span_text_controller` / `composer_doc` | — | P1 | **已完成**（代码 §194 落地 + §4.5.5 回写；757 测试绿） |
| **A1** | 空项保存蒸发：文本真相模型下标记本就在文本，敲首字只是 `- `→`- 字`，旧坐标蒸发路径已删 | devlog 31 | 编辑器输入路径 | — | P1 | **已完成**（文本真相下已不存在；全量测试验证） |
| **A2** | `# ` 打字无反应：S3 文本真相后 `# ` 直接写文本、`deriveLineRuns` 实时派生标题，已解决 | devlog 31 | 编辑器输入路径 | — | P2 | **已完成**（随 S3 文本真相；待真机复验） |
| **A6** | 勾选撤销步：`toggleTodo` 已 `beginStructuralStep` 进撤销栈 | devlog 31 | `ComposerDoc` | — | P1 | **已完成**（代码落地；全量测试验证） |
| **GFM-表** | 表格 `TableBlock` 收编：解析 + 序列化 + 渲染分支（横向滚动 Table）+ 窄屏适配 | rich-text-gfm §表9 | `package:rich_text` + `rich_text_view` | — | P1 | **已完成**（全链路落地；757 测试绿） |
| **GFM-链接** | 自动链接 `InlineLink(autolink)` 渲染收编：行内裸 url/www./mailto: 识别 | rich-text-gfm §表10 | `rich_text` | — | P2 | **已完成**（行内 link autolink 已支持） |
| **GFM-码** | 行内码 run 化：行内 `` `code` `` 在编辑层提升为 `InlineRun(code)` | rich-text-gfm §3.2 | `span_codec` / `rich_text` | — | P2 | **已完成**（`inlineSpansOf` 已含 code 分支） |
| **富文本/块附件** | 行内富文本（粗/斜/下划线/行内码）+ 媒体块（图/音/视）编辑能力 | 并行会话 WIP | 多文件 | — | P0 | **已完成**（WIP 已落地；757 测试绿） |
| **ops 日志化** | 蓄力项：把 `ComposerDoc` 编辑动作显式化为 `InsertText(pos,'a')` / `FormatRange(start,end,Bold)` 等 op，为阶段三接 CRDT/OT 铺路，零行为变更 | 架构评估 | `ComposerDoc` | — | P2 | **已完成**（2026-10-08 落地；composer_doc_op_log_test 6 例绿） |
| **跨块选区** | 轻量版：多 `TextField` 间选区桥接，全局划词/删除/加粗原子操作 | 阶段二体验缺口 | 编辑器 + 选区桥接层 | — | P3/暂缓 | **待评估**（大工程，阶段二体验短板但投入高） |

## 2. 依赖与冲突规避

- **约束解除（2026-10-08）**：并行会话已结束，原「冲突区」文件不再被他人占用，可直接开发。
- **可先行项**：纯文档回写、新增隔离测试（纯函数测试）均可直接做。
- **推进顺序**：P1（B1/A1/A6/GFM-表）与 P2（ops 日志化/GFM 收编）均已实测完成；剩余真实工作仅 **跨块选区**（P3/暂缓，大工程，按战略评估）。

## 3. 优先级与推进顺序建议

1. **P0**：富文本/块附件——已完成。
2. **P1**：B1 占宽缩进回退、A1 空项蒸发、A6 勾选撤销、GFM-表格——均已完成（代码 + 全量测试验证）。
3. **P2**：A2（随 S3 已修）、GFM-自动链接、GFM-行内码、ops 日志化蓄力——均已完成。
4. **P3/暂缓**：跨块选区轻量版（先评估投入产出，阶段二定位下优先级低；若要做优先「轻量版」而非统一画布）。

## 4. 阶段三触发线（回顾，不在此 backlog 范围）

仅当满足以下之一才启动：① 产品定位正式转型协作文档（对标飞书/Notion/Craft）；② 有 2+ 人客户端基建团队且核心体验经市场验证；③ 站巨人肩膀（桥接 AppFlowy-Editor / flutter_quill）而非纯自研。当前三条件均不满足，阶段二为长期正路。

## 5. 来源索引

- context/epics/workspace/devlog.md（2026-10-07 S0–S4/B3/C/G/D/P0/P1a/P1b；2026-10-08 B/D 落地 + A/E/F 归档）
- docs/design/note-editor-source-of-truth.md（文本真相模型、§4.5.5 占宽回退、§8 未决）
- docs/design/rich-text-gfm.md（表 9 表格 / 表 10 自动链接 / §3.2 行内码）
- docs/design/ui-spec.md §2.2（阶段二排版令牌：标题映射 textTheme、行内 rich text）
