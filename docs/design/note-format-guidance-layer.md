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
- **token 纪律**：样式只从 `TextTheme` 解析（H1=`titleLarge` / H2=`titleMedium` / 正文=`bodyLarge`），**不写裸 `fontSize` 字面量**（arch-guard R7）；颜色一律取 `ColorScheme`（不用裸色值）。
- **标题辨识度（2026-10-08）**：标记区改透明隐藏后，H2（`titleMedium` 16sp）与正文（`bodyLarge` 16sp）**只差字重会糊成一片**，故补 md 编辑器同款三件套——**字号档 + `w700` + 主色**：H2 取 `primary`，H1 提到 `w700`。一眼可辨，不依赖被隐藏的 `##`。
- 由此得「**所见即所选**」：浮层里看到的字重/行高，与选完落进正文的逐像素一致。

## 3. Step 1 · 侧轨语义角标（只读）

- 仅当前段**获焦**时在段首呈现 24dp 弱化徽标；失焦宽度收 0。
- 绝不挤压 360dp 正文（本机逻辑宽 331dp 亦不溢出）。
- **列表/待办段同样显示角标**（2026-10-08 拍板，推翻原「凹槽已占宽、不重复」）：待办/引用/标题档齐全后，列表行若不给角标就**没有任何改类型的出口**（凹槽只认 `•` 与 `☑`，改不回正文/标题）——入口一致性优先于省 24dp；代价是列表段左侧共 52dp（角标 24 + 凹槽 28），331dp 窄屏正文余 279dp（原 303dp），真机待验。

## 4. Step 3 · 贴键浮层打样面板（可写）

- **触发**：点 Step 1 角标（`GestureDetector`），保持段聚焦、拉起面板（`_blockPanelOpen`）。
- **档位**（2026-10-08 拍板）：结构 6 档 `plain / h1 / h2 / bullet / todo / quote`（样例文字 正文/标题一/标题二/列表项/待办项/引用文字）+ **行内 2 档 `B / I`**，行内档排在**标题二之后**（细分隔线分组，见下）。标题保留 H1+H2 两级；待办回归显式档（推翻 2026-10-03「去掉待办列表」，见 §5）。
- **行内档为开关型**：与块级档「选完即收」不同，B/I 切换后**浮层保持展开**（可连点试错 / 再点关闭）；**单选制**互斥（新选替换旧选）。语义受 `context/pending-confirm.md` D5 约束＝**先选后打**（作用于之后输入的文字），不做「给已有文字套格式」。瓦片以字母本体作样式预览（B 加粗 / I 斜体）。
- **档位序**：结构档按语义层级（正文→标题→列表→待办→引用），行内档插入标题二之后并用 1dp 细分隔线两侧分组——两类语义不同（块级=整行，行内=之后输入的文字），视觉分组防混读。
- **档位序 = 语义层级**（正文→标题→列表→待办→引用），不按频次：用户是「按语义找档」而非「按肌肉记忆找位置」，语义序可预测性更高；正文作回退档置首（错误预防）。
- **WYSIWYG**：每档瓦片 = 22dp badge 块 + 用 `resolveStyle` 渲染的样例文字；当前档高亮 `primaryContainer`，其余 `surfaceContainerHighest`。
- **贴键不挤正文**：`Positioned(left/right: Insets.sm, bottom: kComposerToolLayerHeight + Insets.sm)`——浮在工具层上沿、软键盘上方；横向滚动容 6 档（331dp 窄屏需横滚，§7 待验）。
- **收盘**：复用既有 `_closeFormatDial` 入口（滚动/场景切换等既有调用点一并覆盖）。

## 5. 落地链路与口径

```mermaid
flowchart LR
    A["点侧轨角标"] --> B["_blockFormatPanel<br/>（WYSIWYG 6 档）"]
    B --> C["_applyBlockKind<br/>BlockKind → LineKindTarget"]
    C --> D["ComposerDoc.setLineKind<br/>（内含 IME 组合态守卫 _finalizeComposing）"]
    D --> E["_applyOutcome<br/>反射重建段与光标"]
```

- **待办 2026-10-08 拍板回归浮层**（推翻 2026-10-03「去掉待办列表」）：`LineKindTarget` 增 `todo`，直设写 `- [ ] `（收集场景「待看/待买/待办」高频，此前只能手打字面或 md 导入产出）。**分工不变**：建行走 `setLineKind(todo)`，翻勾选仍走 `toggleTodo`（改写 `[ ]`/`[x]` 字面）。保存期「整段逐行转待办」的 `_todoMode` 仍不恢复入口（quick_note_bar）。
- **IME 安全**：`setLineKind` 内部已挂组合态守卫，中文组合期选档不会被结构改写打断。

## 6. 代码落点

| 事项 | 落点 |
|------|------|
| 排版规约 SSOT | `lib/ui/theme/block_presentation.dart`（`BlockKind` / `blockPresentationOf` / `lineKindOf`） |
| 编辑器接线 | `lib/ui/note_composer_editor.dart`（`_focusBadge` / `_withFocusBadge` / `_blockFormatPanel` / `_blockTile` / `_blockSample` / `_applyBlockKind`） |
| 结构改写 | `lib/ui/composer_doc.dart`（`setLineKind` / `toggleTodo`） |
| 档位枚举（含 todo） | `lib/share/quick_note_text_actions.dart`（`LineKindTarget` / `setLineKindAction`） |
| 单测 | `test/block_presentation_test.dart`、`test/composer_doc_set_line_kind_test.dart` |
| 退役转盘（编辑器侧） | 2026-10-08：`note_composer_editor.dart` 的**调用侧**全清（`_hub` / `_formatDialPanel` / 四缘吸附停靠持久化等）；**组件本体 `lib/ui/format_dial.dart` 保留**——零业务语义可复用件（菜单/几何/手感全经 `DialSpec` 注入），单测 30 条守护，待其他宿主复用；配套 `smart_floating_hub.dart` 已删 |
| 行内格式 | `lib/ui/note_composer_editor.dart`（`_toggleMark` / `_markTile`）、引擎 `ComposerDoc.applyMarkToSelection`；单测 `test/composer_inline_mark_test.dart` |

## 7. 验收口径

- [ ] 真机：点角标拉起面板手感；面板贴键不遮光标行
- [ ] 真机：选档后渲染与光标是否稳定（含中文 IME 组合态中途选档）
- [ ] 真机：横滚 6 档在窄屏（331dp）不溢出；列表/待办段角标可唤浮层且左侧 52dp 下正文仍够用
- [ ] 真机：待办档落地 `- [ ] ` 后凹槽勾选框出现并可翻勾选（与 toggleTodo 分工无冲突）
- [x] `flutter analyze` 改动文件 0 issue
- [x] `block_presentation`(4) + `composer_doc_set_line_kind`(14) = 18/18 单测绿（2026-10-08 待办档 +4）

## 8. 来源

- context/epics/workspace/devlog.md（2026-10-08 问题#1 Step 0/1/3 + 转盘注释保留）
- docs/design/note-editor-source-of-truth.md（文本真相模型，结构改写口径）
- docs/design/quick-note-format-dial.md（**已墓碑化**：被本文取代）
