---
status: active
updated: 2026-10-04
---

# 富文本 GFM 渲染收编与 AI 写入原则设计稿

> 状态：**active**——已拍板，作为实现依据开工。
>
> 本稿自 [quick-note-format-dial.md](quick-note-format-dial.md) §3-§5 拆出（2026-10-03）：转盘输入 UI 与渲染/存储层全集解耦，各自独立演化。转盘输入全集见原稿 §2.7（维持 5 项）；本文只管**渲染/存储层收编 GFM 全量**与 **AI 写入处理**。

## 1. 背景与总原则

**场景前提**：拾贝是**知识收集工具**而非速记工具——条目大头写入方是 AI（整理、改写、结构化），人是审阅与少量补记。格式全集按这个前提定：AI 结构化输出的常用形态（表格、高亮）必须**原样精美渲染**，映射降级是信息结构损失，违背页面质量第一。

**总原则（用户拍板 2026-10-03）**：AI 能写的都要进行「翻译」，用户页面的质量放第一位，「AI 好写不好写」不放第一位。任何 AI 经 MCP 写入的文本，到达用户界面时必须是干净且精美渲染的——**用户永远不看到语法残壳**。

**两层全集**：

- **渲染/存储全集（拍板：对齐 GFM 全量）**：GitHub md 语法全都要——CommonMark 基础 + GFM 官方扩展全收：**表格**（`\|…\|` 对齐行）、**任务列表**（`- [x]`，已有）、**删除线** `~~text~~`、**自动链接**（裸 URL/`www.`/`mailto:` 自动成链）、**围栏代码块语言标注**（```` ```lang ````，解析已有 language 字段，渲染补语言徽标）。AI 写这些格式**零映射、零损失**。`==高亮==` 为 GFM 之外的追加项（Pandoc 事实标准，一并收编）。
- **转盘输入全集（对人）**：维持 5 项——人手输复杂格式低频，结构化编辑走详情页；输入 UI 与渲染全集解耦。

## 2. AI 写入三层处理链

```mermaid
flowchart LR
    A["AI 经 MCP 写文本"] --> B["层1 · 工具描述引导<br/>声明支持格式全集"]
    B --> C["层2 · 命令入口语义映射<br/>ItemActionHandler 唯一收口"]
    C --> D["层3 · R1 告知<br/>映射结果回传 AI 可感知"]
    D --> E["存储层恒为子集内 md<br/>用户界面恒无残壳"]
```

| 层 | 策略 | 说明 |
|---|---|---|
| 1 引导 | MCP 工具描述声明支持全集（标题/粗体/斜体/下划线/行内码/链接/删除线/表格/高亮） | AI 第一次就写对，零损耗 |
| 2 映射 | 入口对**全集外**语法做**语义映射**（找最接近的子集形式降级），不做「剥成纯文本」 | 例：脚注→括号注、引用链接 `[text][id]`→`[text](url)`（见 R3 两遍扫描）或纯文本；`==...==` 跨多个比较 `==`（如 `a == b == c`）按纯文本 + R1 note「疑似比较式未高亮」；禁止把 `~~x~~` 甩给用户看，也禁止静默丢格式 |
| 3 告知 | 映射即降级，须在命令返回体/MCP 响应带 note（「表格已转为分行文本」） | R1：AI 可感知，下次直接用支持格式。当前 **仅脚注、引用链接、以及检测到的子集外结构（数学式 `$$`、HTML 标签，跳过敏感代码围栏与角括号自动链接 `<https://…>`）** 发 R1 note；子集外结构命中即告知「已降级为普通段落」，其余全子集内语法零映射零告知 |

**引用链接处理（R3）**：入口 `parse` 第一遍扫描全文引用定义 `^\[([^\]]+)\]:\s+(\S+)$`，收集 `Map<String,String> refDefs`（键小写归一）；定义行（`[id]: url`）视为 meta，**不渲染为段落残壳**，从可见输出剥离。第二遍行内映射：`[text][id]` 命中 refDefs → 重写为 `[text](url)` 走正常链接解析（零残壳）；孤立 `[id]` / 缺定义 → 上标或纯文本 + R1 note「引用链接未找到定义，已转为纯文本」。此机制是「永远无残壳」总原则的硬保障。

## 3. 格式全量镜像对照表（枚举全部语法，与代码同源）

三类语法的**全集**——每行与 `lib/doc/rich_text.dart` 实际代码逐支对齐（行内分支顺序即 `_pattern` 分组 1-9；块级即 `_parseBlocks` 判序）。三类镜像关系：

```mermaid
flowchart LR
    M["md 语法<br/>(存储/交换格式)"] -- "解析 inlineSpansOf / parseBlocks" --> R["内存模型<br/>(runs/levelRuns/blocks)"]
    R -- "渲染 buildTextSpan / switch(TextStyle)" --> A["安卓原生<br/>(Flutter TextStyle)"]
    R -- "序列化 serializeInline" --> M
```

### 3.1 块级语法（`MarkdownSubsetParser._parseBlocks` 全集，10 行）

| # | md 语法 | 解析产物（RichBlock） | 安卓原生渲染 | 速记转盘输入 |
|---|---|---|---|---|
| 1 | ```` ```lang ```` … ```` ``` ```` 围栏代码块（lang 可空） | `CodeBlock(code, language?)`（围栏内原样保留，不解析行内；未闭合按到文末） | 等宽字体块 + 代码底色容器 | 不提供（详情页块编辑） |
| 2 | `---` / `***` / `___` 分隔线 | `DividerBlock` | 水平细线（Divider） | 不提供 |
| 3 | `#{1,6} 文本` 标题（1-6 级） | `HeadingBlock(level, inline)`（行内仍解析） | 标题字号阶梯（headlineSmall 24sp → titleSmall 14sp，见 §3.5 视觉规格）+ w600 | 二级直选（H1/H2/正文） |
| 4 | `> 文本` 引用（可多行聚合，内部递归 `_parseBlocks`） | `QuoteBlock(children)` | 左竖线缩进容器 + 弱化色 | 不提供 |
| 5 | `- `/`* `/`+ ` 无序列表（连续项聚合） | `ListBlock(ordered: false, items)`；ListItem 加 `indentLevel`（`^\s*` 长度/2 计算，嵌套不拍平） | 缩进层级 + 层级符号（• → ○）；indentLevel>0 左缩进 | 不提供 |
| 6 | `1.`/`1)` 有序列表（连续项聚合） | `ListBlock(ordered: true, items)` | 数字编号列表 | 不提供 |
| 7 | 列表项 `[ ]`/`[x] ` 前缀待办 | `ListItem(todo: bool, done: bool)` | 复选框（CheckboxListTile 形态） | todoMode 逐行转 `- [ ]`（已有） |
| 8 | 整行 `![alt](url)` / `[label](url)`（后缀白名单） | `ImageBlock` / `AudioBlock` / `VideoBlock`（不命中白名单落回普通段落不丢内容） | 媒体卡（图片封面/播放器形态） | 拍照/相册/录音/视频就地插图（已有，非语法输入） |
| 9 | `| 列1 | 列2 |` + `|---|---|` 对齐行（**收编**——知识收集场景 AI 结构化输出基本盘，GFM 官方扩展） | `TableBlock(header, rows, align)`（待加块级分支） | Table/DataTable 卡片（待加渲染分支，滚动适配窄屏） | 不提供（渲染收编，输入不扩；**AI 写零映射零损失**） |
| 10 | 裸 URL / `www.` / `mailto:` 自动链接（**收编 GFM**） | `InlineRun(mark: link, url)`（渲染层 url 检测已有等价物，编辑层补 run 化） | 主题色 primary + tap 手势（同链接） | 不提供（渲染收编） |

### 3.2 行内语法（`_pattern` 分组 1-9 全集，5 种 mark + 转义）

| # | md 语法（分组号） | 解析产物 | 安卓原生渲染（TextStyle 增量） | 速记转盘输入 |
|---|---|---|---|---|
| 0 | `\X` 转义（分组 1）→ 字面 X | 纯文本 | 原样显示 X，无样式 | 自动（serializeInline 对 `\` `*` `_` `[` `` ` `` 反向转义） |
| 1 | `**粗**` / `__粗__`（分组 2,3） | `InlineRun(mark: bold)` | `FontWeight.w700` | 行内子盘「加粗」 |
| 2 | `*斜*` / `_斜_`（分组 4,5） | `InlineRun(mark: italic)` | `FontStyle.italic` | 行内子盘「斜体」 |
| 3 | `` `码` ``（分组 6） | `InlineRun(mark: code)` | fontFamily: monospace + 代码底色 | 不提供（输入不扩充；AI 可写，入口不映射——已在全集内） |
| 4 | `<u>下</u>`（分组 7，HTML 子集扩展） | `InlineRun(mark: underline)` | `TextDecoration.underline` | 行内子盘「下划线」 |
| 5 | `[文本](url)`（分组 8,9） | `InlineRun(mark: link, url)`（plain 只含 label，url 载荷保全） | 主题色 primary + tap 手势（launch） | 不提供（AI 可写） |
| — | `~~删除~~`（收编，**尚无分组**） | `InlineMark.strikethrough`（待加枚举） | `TextDecoration.lineThrough`（待加分支） | 不提供（渲染收编，输入不扩） |
| — | `==高亮==`（**收编**——知识收集场景 AI 标注高频，非 GFM 但 Pandoc/Obsidian 事实标准） | `InlineMark.highlight`（待加枚举） | 背景色高亮（待加分支） | 不提供（渲染收编，输入不扩；AI 写零映射零损失） |

### 3.3 叠加语义与解析边界（同源单测锁定的实证行为）

1. **渲染优先级**：bold > italic > code > underline > link（`inlineNodesOf` 嵌套优先级）；Flutter TextStyle 各属性天然可并存——粗+斜 = fontWeight+italic 同时生效。
2. **档位 × 行内互斥**：标题行（levelRun）不吃行内 run，落库恒为 `# 标题` 而非 `# *标题*`（交互规则见转盘稿 §2.7）。
3. **`***粗斜***` 现状**：现行解析器实证为字面（`*粗斜*`）——但该实证是**子集现状**而非**设计意图**，AI 大头写入前提下必须压制：新增**独立粗斜体分支**，处置为 bold+italic 双激活（零新枚举、渲染层天然并存），正则**插在粗体分组之前**（最长匹配优先）——见 §3.5 收编代码块，插错顺序则 `***x***` 永远先命中粗体分支，粗斜体分支成死代码。
4. **行内码含反引号**（`` ``a ` b`` ``）：现行 `` `([^`]+)` `` 遇内容内反引号即断，AI 解释代码场景真实存在——升级方案见 §3.5。
5. **引用链接 `[text][id]` / `[1]`**：入口 `parse` 两遍扫描收集引用定义（见 §3.6 ⑥ / §2 R3）；行内 `[text][id]` 命中定义 → 重写为 `[text](url)`，孤立 `[id]` → 上标或纯文本，R1 note 告知。

### 3.4 视觉规格（现状快照 · legacy）

> 本节为**开工前 App 实际值的快照（legacy 基线）**，仅作对照；**所有新语法（删除线/高亮/表格/自动链接/粗斜等）一律以 §3.5 为准**，不另起与 §3.5 冲突的「待定/升级」措辞，避免双源漂移。

**现有语法视觉规格（真实值，源 `rich_text_view.dart` `_headingStyle`/`_bodyStyle`/块渲染分支；App 未自定义 textTheme = M3 默认字号）**：

| md 语法 | App 视觉（阅读态） | 字号 | 字重/行高 |
|---|---|---|---|
| `# 一级标题` | headlineSmall | **24sp** | w600，行高 1.35，块后距 lg |
| `## 二级标题` | titleLarge | **22sp** | w600，行高 1.35，块后距 lg |
| `### 三级标题` | titleMedium | 16sp | w600，行高 1.35，块后距 lg |
| `####`–`######` 四至六级 | titleSmall | 14sp | w600，行高 1.35，块后距 lg |
| 正文段落 | bodyLarge（阅读态）/ bodyMedium（详情编辑态） | **16sp / 14sp** | 常规，行高 1.65（衬线 1.75） |
| `**粗**` | 同基样式 + 加粗 | 继承所在块 | FontWeight.w700 |
| `*斜*` | 同基样式 + 斜体 | 继承 | FontStyle.italic |
| `` `码` `` | monospace 字体 + 代码底色 | 继承 | — |
| `<u>下</u>` | 同基样式 + 下划线 | 继承 | TextDecoration.underline |
| `[文本](url)` | 主题色 primary + 可点 | 继承 | — |
| `> 引用` | 左 3dp 竖线（outlineVariant）+ 左缩进 md(12)，内部递归渲染 | 继承 | — |
| ` ``` 代码块 ` | surfaceContainerHighest 底色圆角块（Radii.md），monospace，行高 1.5 | 继承 | — |
| `---` 分隔线 | Divider，outlineVariant 色，高 1，块后距 lg | — | — |
| `- 列表` | 无序 • / 有序数字，项间距 xs(4)；`[x]` 复选框形态 | 继承 | — |
| 编辑态标题（速记/详情块编辑） | titleLarge（H1）/ titleMedium（H2+），w600；正文回落 bodyMedium | 22/16/14 | 同上 |

> 衬线开关：serif 路径标题与正文同切衬线字体，行高 1.75。

### 3.5 渲染标准（每语法「视觉+交互」完整定义；§3.4 为现状快照 · legacy，新语法一律以本节为准）

**11 类语法清点（用户分类法 × 落点核对，逐类一条不缺）**：

| # | 语法类 | 视觉+交互规格落点 |
|---|---|---|
| 1 | 标题 | §3.1 块级表「标题」行 + §3.5（24/22/16/14sp w600） |
| 2 | 段落 | §3.1 块级表「段落」行（连续非空行聚合，软换行连接） |
| 3 | 换行 | §3.1 块级表「换行」行（段内单换行=软换行直显，空行=分段；行尾双空格无特殊分支） |
| 4 | 强调 | §3.2 行内表（粗/斜/粗斜/删除线/高亮）+ §3.5 视觉规格 |
| 5 | 引用块 | §3.1 块级表「引用」行（主题色竖线+背景填充+嵌套递进） |
| 6 | 列表 | §3.1 块级表（无序/有序/待办 + indentLevel 层级 bullet + Checkbox 一期只读） |
| 7 | 代码 | §3.1 块级表「代码块」行（卡片+语言微标+一键复制）+ §3.2 行内表「行内码」行（圆角 Tag） |
| 8 | 分隔线 | §3.1 块级表「分隔线」行（1dp 柔和实线，margin lg） |
| 9 | 链接 | §3.2 行内表（显式链接 primary+下划线+外部浏览器）+ §3.1 块级表「自动链接」「音视频链接行」 |
| 10 | 图片 | §3.1 块级表「图片」行（max-width 100% + 点击大图） |
| 11 | 转义字符 | §3.2 行内表「`\X` 转义」行 + serializeInline 反向转义清单（`\` `*` `_` `[` `` ` ``） |

**块级元素（10 项全量）**：

| 语法 | 视觉规格 | 交互规格 |
|---|---|---|
| `> 引用`（现行→升级） | 左侧**主题色**（primary）3dp 竖线 + 浅色背景填充（surfaceContainerLow，圆角右侧 Radii.sm）；内文字颜色略浅于正文（onSurfaceVariant）；多层嵌套：每层再缩进 + 竖线色深浅递进 | 无特殊交互；内部递归渲染任意块（引用里可以有列表/代码） |
| ```` ```lang ```` 代码块（现行→升级） | 独立卡片：跟随系统主题的深色/浅色底（surfaceContainerHighest），圆角 Radii.md，monospace 行高 1.5；右上角**语言微标**（labelSmall 胶囊） | **右上角「一键复制」IconButton**（刚需）：点击复制代码本体 → SnackBar「已复制」；长按选择复制保留 |
| `- / * / +` 无序列表 | 层级 bullet：一级实心 •、二级空心 ○、三级实心小方块 ▪（定标），缩进 16dp/层 | — |
| `1. / 1)` 有序列表 | 数字编号 + 缩进同无序 | — |
| `- [ ] / - [x]` 待办清单 | **真实 Checkbox UI**（M3 Checkbox，紧凑形态） | **一期只读**：勾选状态随文本渲染，点击不响应（打勾需反向更新原始文本，二期做） |
| `--- / *** / ___` 分隔线 | 占满容器宽 1dp 柔和实线（outlineVariant），上下 margin lg(16) | — |
| 表格（定标） | 圆角卡片（Radii.md）内：**表头固定样式**（surfaceContainerHighest + w600），**斑马纹**数据行（奇偶行 surfaceContainerLow 交替），行分隔细线 outlineVariant；列按对齐行左/中/右 | **容器内横向滑动**（横向 ScrollView，表头随动）；超宽不挤压换行 |
| `![alt](url)` 图片 | max-width: 100%（不超容器），圆角 Radii.md | 点击看大图（详情页媒体查看器）；长按能力页（既有） |
| 段落 | 连续非空、非块起始的行聚为一个段落（行间以软换行 `\n` 连接，源码实测 `ParagraphBlock(parseInline(buf.join('\n')))`）；段间无额外样式 | — |
| 换行 | **段内单换行 = 软换行**：保留 `\n` 渲染为直接换行（不合并空格）；**空行 = 分段**（新 ParagraphBlock，块间视觉间距）；行尾双空格硬换行无特殊分支（同软换行效果，不丢失） | — |
| `[label](url)` 音视频链接行 | 白名单命中→播放器形态卡；未命中→普通段落 | 点击播放/预览（既有） |
| `# `~`###### ` 标题 | 同 §3.5（24/22/16/14sp w600） | — |

**行内元素（8 项全量）**：

| 语法 | 视觉规格 | 交互规格 |
|---|---|---|
| `**粗**` / `***粗斜***` | w700；粗斜体双激活（§3.3-3 分支） | — |
| `*斜*` | FontStyle.italic | — |
| `<u>下</u>` | TextDecoration.underline | — |
| `` `码` ``（定标） | **浅色背景圆角 Tag**（surfaceContainerHighest，圆角 4dp，水平内边距 3dp），monospace，**字体颜色微调偏主题色**（primaryContainer 系）突出专业感 | 无 tap（区别于链接）；长按选择复制 |
| `~~删除~~`（定标） | 标准中划线（lineThrough，线随文字色） | — |
| `==高亮==`（定标） | 文本背景高亮：**半透明主题黄/secondaryContainer**，文字颜色不变，圆角 2-3dp | — |
| `[文本](url)` 链接（升级） | **主题色 primary + 单下划线**（定标：下划线明确化，弱视可辨） | 点击调起外部浏览器/WebView；长按选择复制 |
| 自动链接（定标） | 与显式链接完全同款（primary + 下划线） | 同链接 |

### 3.6 代码层实现契约（实现定义前置——动工即按此落，实现与本节不符 = 缺陷）

**现有语法（rich_text.dart 实测引用）**——定义已存在于代码，行号随迭代漂移，以符号名为准：

```dart
// lib/doc/rich_text.dart —— 行内标记枚举（5 种，现行全集）
enum InlineMark { bold, italic, code, underline, link }

// 行内 run：纯文本坐标 [start, end)，link 携带 url 载荷
class InlineRun {
  const InlineRun(this.start, this.end, this.mark, {this.url});
  final int start, end;
  final InlineMark mark;
  final String? url;
}

// 行内解析：_pattern 分组 1-9（分支顺序 = 解析顺序 = 镜像契约）
final pattern = RegExp(
  r'\\([\\`*_\[])'          // 1 转义 `\X` → 字面 X
  r'|(\*\*|__)(.+?)\2'      // 2,3 粗体 **x** / __x__
  r'|(\*|_)(.+?)\4'         // 4,5 斜体 *x* / _x_
  r'|`([^`]+)`'             // 6 行内码 `x`
  r'|<u>(.+?)</u>'          // 7 下划线（HTML 子集扩展）
  r'|!?\[([^\]]*)\]\(([^)]*)\)', // 8,9 链接/图片 [l](u)
  dotAll: true,
);

// 块级正则（_parseBlocks 判序：fence → divider → heading → quote → list → media）
_fence   = RegExp(r'^```(\w*)\s*$');                    // 围栏 + 语言标注
_divider = RegExp(r'^\s*(?:---|\*\*\*|___)\s*$');       // 分隔线三写法
_heading = RegExp(r'^(#{1,6})\s+(.*)$');                // 标题 1-6 级
_quote   = RegExp(r'^\s*>\s?');                         // 引用（多行聚合递归）
_bullet  = RegExp(r'^\s*[-*+]\s+(.*)$');                // 无序列表
_ordered = RegExp(r'^\s*\d+[.)]\s+(.*)$');              // 有序列表
_todo    = RegExp(r'^\[([ xX])\]\s+(.*)$');             // 裸待办行专用（[ ] xxx 不带 -）；
                                                        // "- [ ] x" 在无序列表聚合循环内先命中
                                                        // _bullet → _listItem 剥前缀，勿混
```

**收编语法（GFM 全量，动工即按此落）**：

```dart
// ① 枚举扩展（2 个新值；粗斜体走 bold+italic 双激活，零新枚举——§3.3-3）
enum InlineMark { bold, italic, code, underline, link,
                  strikethrough /*~~x~~*/, highlight /*==x==*/ }

// ② 行内正则插入（分组顺延；插分支必同步分组号——lesson）
//    ⚠ 插入位置：粗斜体必须插在粗体分组**之前**（最长匹配优先），
//    否则 ***x*** 先命中粗体分支、粗斜体分支成死代码。
//    收编后分支顺序：转义 → 粗斜体 → 粗体 → 斜体 → 行内码 → 下划线 → 删除线 → 高亮 → 链接
r'|\*\*\*(.+?)\*\*\*'  // 粗斜体 ***x***（AI 高频；处置：bold+italic 双激活）
r'|\~\~(.+?)\~\~'      // 删除线 ~~x~~
r'|==([^\s=]+(?:\s+[^\s=]+)*)=='  // 高亮 ==x==：成对且两侧非空白非=（防 a==b 误判）；
                                  // 组内含空格允许、禁=；层2 兜底见 §2（R3/R2）
r'|(https?://[^\s<>()]+|www\.[^\s<>()]+|mailto:[^\s<>()]+)' // ⑤ 自动链接（裸 URL run 化，
                                                          // 在转义之后、粗斜体之前试匹配；
                                                          // url 即 label 即载荷）

// ③ 渲染分支（TextStyle 增量）
InlineMark.strikethrough => TextDecoration.lineThrough,
InlineMark.highlight     => 背景色（secondaryContainer 系，浅晕不抢字）

// ④ 表格块级模型 + 判序位（divider 之后、quote 之前试匹配）
class TableBlock implements RichBlock {
  final List<String> header;        // 首行拆列
  final List<List<String>> rows;    // 数据行（行内仍 parseInline）
  final List<int> align;            // 对齐行 `:---/:---:/---:` → 0/1/2
}
// 正则：连续 ≥2 行且第 2 行匹配 ^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$

// ⑥ 引用定义两遍扫描（R3）：parse 第一遍收集 refDefs，定义行作 meta 不渲染残壳
//    正则：^\[([^\]]+)\]:\s+(\S+)  收集 Map<String,String>（键小写归一）
//    定义行从可见输出剥离；行内 [text][id] 命中 refDefs → 重写为 [text](url)
```

**行内码含反引号的升级方案（⚠ 不用正则——防灾难性回溯）**：

Dart RegExp 遵循 ECMA-262，支持反向引用，但「嵌套量词 + 反向引用」形态（如 `` r'(`+)([^`]|`(?!`))+?\1' ``）对长文本存在**灾难性回溯风险**（指数级回溯，卡 UI 线程）。行内码改为**解析前预处理**（在 `_pattern` 匹配之外、inline 解析入口最先执行）：

```dart
// 双扫描：先找连续反引号定界符（`+），再找同长度闭合——线性时间，无回溯
// 输入 "``a ` b``" → code run 内容 "a ` b"（定界符长度配对，GFM 语义）
List<CodeSpan> extractCode(String text); // 返回 [start, end, content] 列表，
// 主 _pattern 匹配时跳过 code 区间（命中区间与 code 区间重叠则丢弃该 match）
```

实现期用 `` ``let a = "x"`` `` 类用例锁定 + 超长文本（>10KB 连续反引号）性能用例锁定。

**序列化契约（seed ↔ serialize 双向，新语法强制项）**：

| 语法 | serialize 形态 | 说明 |
|---|---|---|
| `~~x~~` | `~~` + inlineToPlain(x) + `~~` | 双向；行内照常 parseInline |
| `==x==` | `==` + inlineToPlain(x) + `==` | 双向；遵守 R2 收紧规则（两侧非空白非 `=`） |
| 表格 | `| h1 | h2 |` + 对齐行（`| :-- | --: |`，按 align 0/1/2）+ 数据行；单元格内 `\|` 转义，行内换行转 `<br>` | 往返锁：seed→serialize→parse 无残壳 |
| 自动链接 | 裸 `url`（不包 `<>`） | run 化后序列化回原文 |
| `***x***` 粗斜 | `***` + inlineToPlain(x) + `***` | 双激活 → `***` 形态，匹配 ② 分支 |

**规约**：新语法的落点恒为「枚举/模型 + 正则分组 + seed/serialize/渲染分支 + 单测」四件套；**serialize 分支为强制项**（见上方序列化契约），杜绝实现期各自为政。

### 3.7 解析器扩展机制（职责链形式化路线）

> 设计决策（2026-10-04 评审）：现状块级解析为 `MarkdownSubsetParser._parseBlocks` 内 `if` 级联（fence→divider→heading→quote→list→media→裸待办→段落），逻辑上即一条职责链，但未抽象为 handler 对象；行级用单条合并正则 `allMatches` 单次线性扫描。以下为「何时、为何形式化」的路线记录，**现状不重构**。

**为什么现状不采用流式 / 对象化职责链**

1. **流式（逐行 token 流）不采纳**：输入量级（AI 产出几百行 md）无需分块进内存；围栏/引用/列表等**多行块**需状态/游标，纯流式反而引入状态机与缓冲，复杂度上升而延时无收益——当前「全量 `split('\n')` + 单次线性扫描」在延时上等价于流式。
2. **对象化职责链延后到扩展期**：现状 if-cascade 已是 CoR 的行为语义（能处理即 `continue` 下沉），缺的只是可插拔形态。形式化为 handler 注册表的**唯一真实收益**是「加新块类型 = 写一个 handler + 注册进 `const` 列表，核心 `_parseBlocks` 不动」，适配 §3.6 收编路线（strikethrough/highlight/table/自动链接）。代价是每行多一次虚分发 + 段落聚合需反向咨询各 handler「下一行是否块起始」（见下），样板增多。

**形式化契约（草案，仅扩展期启用）**

```dart
abstract class BlockHandler {
  bool canHandle(String line);
  (RichBlock, int) handle(ChainParser parser, List<String> lines, int i); // 块 + 消费行数
}
// 注册表顺序须与原 _parseBlocks 判序严格一致：
// const [Fence, Divider, Heading, Quote, List, Media, BareTodo, Paragraph]
// handler 列表与 RegExp 仍 static final / const —— 延时基本不变。
```

**CoR 相对原 cascade 的额外耦合点（落地前必读）**：段落聚合需「连续非块起始行」，须由 `ParagraphHandler` 反向问 `parser.isBlockStart(line)`（遍历所有 handler 除自身），无法完全独立；且 `bareTodo` / 原 `_isBlockStart` 边界须显式对齐，否则易漂移。对比草稿（注册式 `ChainParser` + 各 `BlockHandler`）在本评审中已给出骨架，未落地；现状保持 `_parseBlocks` 内 if-cascade。

## 4. 实现落点（GFM 收编件）

| 件 | 落点 | 说明 |
|---|---|---|
| 删除线+高亮收编 | `lib/doc/rich_text.dart` | 解析器加 `~~`/`==` 分组 + `InlineMark.strikethrough`/`highlight` 枚举 + seed/serialize/渲染三处同源 + 单测（`==` 收紧规则见 §3.6 ②） |
| 粗斜体分支 | 同上 | `***x***` 分支插在粗体之前（§3.3-3、§3.6-②），bold+italic 双激活，单测锁定 |
| 行内码反引号配对 | 同上 | §3.6 预处理双扫描方案（弃正则，防回溯），单测含超长文本性能用例 |
| 表格+自动链接收编 | `lib/doc/rich_text.dart` + 渲染层 | 块级 `TableBlock(header, rows, align)` 分支 + Table/DataTable 卡片渲染（窄屏滚动适配）；自动链接 run 化；单测 |
| 渲染标准落地 | `rich_text_view.dart` 等渲染层 | 按 §3.5 定标落：引用升级、代码块复制按钮+语言徽标、Checkbox 只读、链接下划线、行内码 Tag |
| AI 写入归一层（含 R3 引用链接） | `lib/action/`（命令入口） | 仅**罕见结构**（脚注→括号注、引用链接等，§2 R3 / §3.6 ⑥）走语义映射 + R1 note 告知；表格/高亮/删除线已收编不再映射；MCP 文本写入工具前置依赖 |

量级：**独立估算**（GFM 收编 + 渲染标准 + 归一层，与转盘 2-3 天分开计——粗估 3-5 天，实现前按件复核）。

## 5. 验收口径（GFM 收编）

1. `~~删除~~`/`==高亮==` 渲染符合 §3.5 定标；serialize 往返（seed→serialize→parse）无残壳。
2. `***粗斜***` 渲染为粗+斜双激活，非字面残壳；单测锁定分支顺序。
3. 行内码含反引号（`` ``a ` b`` ``）正确解析；超长文本性能用例无卡顿（无灾难性回溯）。
4. 表格：对齐行生效、斑马纹、窄屏横向滚动；表格内行内格式仍解析；serialize 往返无残壳。
5. 裸 URL/`www.`/`mailto:` 自动成链，交互与显式链接同款。
6. 代码块语言徽标 + 一键复制可用；Checkbox 一期只读不崩。
7. AI 写入归一层：全集外语法映射后有 R1 note 回传；全集内语法零映射；`==` 收紧规则生效——`a == b`、`== a==`（左侧空格）不触发高亮，`x==y==z`（`==y==` 合法）命中；引用链接 `[text][id]` 经 refDefs 重写零残壳。
8. `flutter analyze` 0 issue；解析器单测全绿（四件套同步锁定）。
