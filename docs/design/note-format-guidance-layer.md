---
status: active
updated: 2026-10-08
---

# 编辑器格式引导层（侧轨语义角标 + 贴键浮层打样面板）

> 2026-10-08「问题#1」：格式选择入口由**悬浮球三级径向转盘**切换为**聚焦段侧轨语义角标 + 贴键浮层打样面板**。
> 转盘稿件已墓碑化（见 [quick-note-format-dial.md](quick-note-format-dial.md) 首行），其代码整段 `/* */` 注释保留、可一键还原。
> 本文锁定**已落地实现**的口径与落点；真机验收项见 §7（本机无设备，尚未验）。

## 1. 定位与三段结构

| 段 | 名称 | 作用 | 落点 |
|----|------|------|------|
| Step 0 | 统一排版规约 | kind→样式单一事实源，编辑/角标/浮层三处同源 | `lib/ui/theme/block_presentation.dart` |
| Step 1 | 侧轨语义角标 | **只读**：当前聚焦段是什么块类型 | `_withFocusBadge` / `_focusBadge` |
| Step 3 | 贴键浮层打样面板 | **可写**：WYSIWYG 选块并落地 | `_blockFormatPanel` / `_applyBlockKind` |

设计取向：**常驻只读角标 + 按需可写浮层**——格式状态平时只占 24dp 弱提示，改格式才临时浮起面板，浮完即收，正文宽度恒不被挤占。

## 2. Step 0 · 统一排版规约（SSOT）

`BlockPresentation`（`lib/ui/theme/block_presentation.dart`）四字段：`kind` / `badge` / `markerPrefix` / `resolveStyle`。

- `BlockKind` 六值：`plain, h1, h2, bullet, quote, todo`；badge 依次 `T / H1 / H2 / • / ▎ / ☑`。
- **三消费方同源**：正文渲染（`SpanTextEditingController` 经 `textTheme` 派生档位）、侧轨角标、浮层打样瓦片，一律取 `blockPresentationOf(kind).resolveStyle(theme, scheme)`。
- **token 纪律**：样式只从 `TextTheme` 解析（H1=`titleLarge` / H2=`titleMedium` / 正文=`bodyLarge`），**不写裸 `fontSize` 字面量**（arch-guard R7）。
- 由此得「**所见即所选**」：浮层里看到的字重/行高，与选完落进正文的逐像素一致。

## 3. Step 1 · 侧轨语义角标（只读）

- 仅当前段**获焦**时在段首呈现 24dp 弱化徽标；失焦宽度收 0。
- 绝不挤压 360dp 正文（本机逻辑宽 331dp 亦不溢出）。
- 列表/待办行已有常驻左侧凹槽（`• / ☑ / 序号`，`_withListGutter`），角标**不重复占宽**。

## 4. Step 3 · 贴键浮层打样面板（可写）

- **触发**：点 Step 1 角标（`GestureDetector`），保持段聚焦、拉起面板（`_blockPanelOpen`）。
- **5 档**：`h1 / h2 / bullet / quote / plain`（样例文字 标题一/标题二/列表项/引用文字/正文）。
- **WYSIWYG**：每档瓦片 = 22dp badge 块 + 用 `resolveStyle` 渲染的样例文字；当前档高亮 `primaryContainer`，其余 `surfaceContainerHighest`。
- **贴键不挤正文**：`Positioned(left/right: Insets.sm, bottom: kComposerToolLayerHeight + Insets.sm)`——浮在工具层上沿、软键盘上方；横向滚动容 5 档。
- **收盘**：复用既有 `_closeFormatDial` 入口（滚动/场景切换等既有调用点一并覆盖）。

## 5. 落地链路与口径

```mermaid
flowchart LR
    A["点侧轨角标"] --> B["_blockFormatPanel<br/>（WYSIWYG 5 档）"]
    B --> C["_applyBlockKind<br/>BlockKind → LineKindTarget"]
    C --> D["ComposerDoc.setLineKind<br/>（内含 IME 组合态守卫 _finalizeComposing）"]
    D --> E["_applyOutcome<br/>反射重建段与光标"]
```

- **待办不在浮层**：`LineKindTarget` 枚举仅 `plain / h1 / h2 / bullet / quote`；`todo` 走 `toggleTodo`（文本真相下改写行内 `[ ]`/`[x]` 字面），故浮层不提供 todo 档——`BlockKind.todo` 仍存在，供角标与列表凹槽使用。
- **IME 安全**：`setLineKind` 内部已挂组合态守卫，中文组合期选档不会被结构改写打断。

## 6. 代码落点

| 事项 | 落点 |
|------|------|
| 排版规约 SSOT | `lib/ui/theme/block_presentation.dart`（`BlockKind` / `blockPresentationOf` / `lineKindOf`） |
| 编辑器接线 | `lib/ui/note_composer_editor.dart`（`_focusBadge` / `_withFocusBadge` / `_blockFormatPanel` / `_blockTile` / `_blockSample` / `_applyBlockKind`） |
| 结构改写 | `lib/ui/composer_doc.dart`（`setLineKind` / `toggleTodo`） |
| 单测 | `test/block_presentation_test.dart`、`test/composer_doc_set_line_kind_test.dart` |
| 退役转盘 | 同文件内 `_hub` / `_formatDialPanel` 及 6 个辅助方法整段 `/* */` 注释保留（可一键还原） |

## 7. 验收口径

- [ ] 真机：点角标拉起面板手感；面板贴键不遮光标行
- [ ] 真机：选档后渲染与光标是否稳定（含中文 IME 组合态中途选档）
- [ ] 真机：横滚 5 档在窄屏（331dp）不溢出
- [x] `flutter analyze` 改动文件 0 issue
- [x] `block_presentation`(4) + `composer_doc_set_line_kind`(10) = 14/14 单测绿

## 8. 来源

- context/epics/workspace/devlog.md（2026-10-08 问题#1 Step 0/1/3 + 转盘注释保留）
- docs/design/note-editor-source-of-truth.md（文本真相模型，结构改写口径）
- docs/design/quick-note-format-dial.md（**已墓碑化**：被本文取代）
