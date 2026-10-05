---
name: goodshare-ui
description: 拾贝 goodshare（Flutter 分享收集器+MCP）UI 层规范事实源：视觉令牌（Insets/Radii/吸附规则）、渲染性能与生命周期、异步加载三态、沉浸式与多设备避让、交互反馈、Local-first 拉齐、导航/双态/组件硬约束。新增或改版页面、组件、BottomSheet、样式前先读本 skill + docs/design/ui-spec.md；写路径/分层/并发见 goodshare-arch，生命周期与内存见 goodshare-mobile。
---

# goodshare UI 规范

视觉 / 导航 / 组件单一事实源在 `docs/design/ui-spec.md`。本 skill 只装**文档里没有的落地口径**（令牌常量、吸附规则、性能纪律、避让与反馈），改动以该文档为权威。
**UI 侧的写路径 / 分层 / 并发不在这里** → `goodshare-arch`；**生命周期 / 内存 / Vault 不在这里** → `goodshare-mobile`。

## 用法

1. 改 / 加页面、组件、样式前，先读 `docs/design/ui-spec.md` 对应节。
2. 改完逐条过本文件末尾「自查清单」。
3. 收尾跑机械护栏：`toolbox run arch-guard`（规则口径见 `goodshare-arch`）。

## 硬约束（UI 侧，与 ui-spec 不重复的口径）

- 视觉基准 **mymind 风格**（2026-09-30 拍板「留骨头、换皮」，口径见 `ui-spec` §2 引言）：**代码层 Material 库照用**（Scaffold/Sheet/TextField 是 Flutter 地基）、**主题层 ThemeData 全量 override 为 mymind 令牌（M3 默认视觉一个像素不许露出）**、**视觉层只认 mymind 基准（「像不像 M3」不是评价维度）**。不照搬「文件极客」的**文件管理隐喻**（文件夹 / 清理）——本 App 是内容 / 时间线中枢。
- 导航固定（2026-09-29 信息结构收敛，SSOT=ui-spec §3）：底部 **3 tab（全部 / 工作区 / 设置）** + **底部常驻速记条**（仅首页，点即聚焦打字即存；导入类走顶部 `＋` 菜单）+ 侧边栏（低频/隐私入口：保险箱·最近删除·AI 任务队列）。**无悬浮球**；时光机/AI 分类已降为筛选维度、保险箱入侧边栏，`timeline_page`/`ai_tags_page`/`floating_ball` 已删除——不得复活，不得新开顶层入口（除非回写 PRD / V2 需求）。
- 详情页必须支持 `human_md`（Markdown 渲染）与 `machine_json`（可切换 JsonView）**双态呈现**；双态共享同一 `item` 数据，禁止双源。
- 详情 / 编辑采用**模板 + 按类型策略**：`ItemViewTemplate`（`lib/ui/item_view_template.dart`）+ `ItemViewRegistry` 按 `item_type` 分发；新增文件类型 = 实现模板 + 注册，框架零改动（与 `AiReconstructor` 同构，V2 §3.8）。
- **标签维度**（2026-09-29 降级，原「AI 分类」tab 删除）：标签是主列表筛选 chips 之一，按 `facets` 过滤，视觉走 ui-spec §2.3 胶囊流；依赖 AI 打标，无 `facets` 时空态，不做假数据。
- Vault 内容在 MCP 层物理隔离（`is_vault=0` 过滤），UI 进入需生物识别（`local_auth`）。
- 设置树固定 `ui-spec` §5 五分组；新增开关先在需求登记再落地。

## 交互与主题硬规则（2026-10-01 会话沉淀；案例细节 SSOT=ui-spec §2.4/§3/§4.6/§6）

- **二级页无返回箭头**：出口=系统手势/返回键。三层落法——①路由页 `automaticallyImplyLeading: false`；②状态层级视图（同页状态切换的上下级，如保险箱视图/工作区进入态）**必须先补 `PopScope` 接管手势返回再摘箭头**（此类视图不是路由，裸摘箭头=困住用户）；③画布类手势密集页绘制中 `canPop:false` 兜底。例外（语义非导航返回，保留按钮）：Sheet/Dialog 关闭/取消、速记面板收起。
- **主题槽位覆写核对**：`ColorScheme` 30+ 槽位，**用未覆写槽位即漏 M3 基线紫白系**（实证事故：outlineVariant 漏浅薰衣草白=便签白边、secondaryContainer 漏紫灰=保存钮撞色）。新用任何槽位前先核对 `lib/main.dart` 已覆写清单，缺则先补主题层；主按钮 tonal/填充色已映射暖棕系（对齐 primaryContainer）。
- **装饰不走橘红**：glyph/插画/品牌符号取 `onSurfaceVariant`/`onSurface`/surfaceContainer 槽位；橘红仅动作与选中（CTA 点亮、选中态）。
- **矢量资产入库前色板重映射**：源图彩色按亮度映射进主题槽位值、删除背景板/白底；源图彩色不落一色进代码（`assets/glyphs/nautilus.svg` = 3 主题值为范本）。
- **交叉淡化「先死后生」**：两态树叠放做形变时，同名元素（提示语等）禁止同屏并存——先现者提前退场（更早的进度窗口淡出），后现者原窗口浮现。
- **CTA 内容感知**：写动作按钮（保存/创建类）空态=实色禁用（`disabledBackgroundColor` 给实色，**禁 M3 默认半透明罩**——onSurface@12% 罩叠深底即脏），有内容=橘红点亮；判据用 `ListenableBuilder` 订阅输入 controller 实时响应。主按钮一律 FilledButton；裸 AlertDialog 仅限快速确认，低频重要动作走整页仪式或 BottomSheet。
- **常驻捕获入口不随滚动隐显**：chrome 是否随滚动隐藏按**任务生命周期**判断——消费时用不着的（搜索栏）随滚动让位，创作/捕获类入口的触发时机在浏览中途，恒常驻。两者不共用同一滚动行为。
- **滚动布局陷阱**：`Center`/`Align` 直接套 `SingleChildScrollView`（纵向）拿不到有界高度 → 内容顶到上沿；须 `LayoutBuilder` 取可视高 + `ConstrainedBox(minHeight)` 撑满再居中。
- **按压反馈分级（禁面积型反馈）**：M3 半透明状态层叠暗底即「灰泥」（与禁用罩同源）。图标钮=图标本身变色（onSurfaceVariant→onSurface）、底板罩透明；CTA=底色实色加深一档（禁罩）；文字钮=文字实色加深。已全局收口在 `main.dart` 主题（`splashFactory: NoSplash` + 三类 ButtonTheme 的 resolveWith），新按钮零成本继承；**非按下态 resolveWith 必须返回 null 回落 M3 默认**，否则 selected 橘红等状态丢失；tonal 按钮的按压深棕须局部样式（全局 pressed 色是橘红系）。
- **全系统去胶囊（2026-10-01 拍板）**：胶囊（Stadium/half-height 圆角）不再是任何组件的合法形态——按钮 Filled/Outlined/FAB 主题收口 `Radii.lg`，chips/标签 `md`，搜索输入框 `xl`，工具栏 `lg`（lib 内 Stadium 归零）。新组件按尺寸取档：小件 md、按钮/工具栏 lg、卡片/输入框 xl；**禁止手写 StadiumBorder 或半径 ≥ 高度一半的伪装胶囊**，按钮不要单独加 shape（继承主题）。

## 视觉令牌（单一事实源；2026-09-30 起 mymind 基准，口径 SSOT=ui-spec §2）

- **取色 / 圆角 / 间距一律走令牌**：颜色用 `Theme.of(context).colorScheme.*` / `surfaceContainer*`；**唯一硬编码处是主题层**（`lib/main.dart` 的 `ColorScheme.dark` override——恒定暗色三阶底/卡/浮 + 橘红强调，`dynamic_color` 已废弃）。
- **字号 / 行高映射 M3 `textTheme` 槽位**（槽位是工程接口，视觉值由主题层定）：`textTheme.*.copyWith(...)`，禁止裸 `fontSize:` / `FontWeight.bold` 字面量；等宽 `fontFamily: 'monospace'` 仅用于机器态；**文章类详情正文走衬线阅读态**（`'serif'`，ui-spec §2.2）。
- **间距 / 圆角常量化**：`lib/ui/tokens.dart` 提供 `Insets`（xs4 / sm8 / md12 / lg16 / xl20 / xxl24）与 `Radii`（sm8 / md12 / lg16，**视觉基准改版后卡片类用 lg16→xl20 档**，令牌值以主题改版落地为准）；Padding / Margin / 圆角禁止 13、17 之类非规范魔术数字。
  - **吸附规则（Snap to Token，渐进迁移）**：① 标数（8/12/16/20/24）直接替换为 `Insets.sm/md/lg/xl/xxl`、`Radii.sm/md/lg`；② 非标数字（10/14/15）在不破坏视觉层级前提下就近取整（10→`Insets.sm`、14→`md` 或 `lg`）；③ `0` 与**组件 / 内容专属尺寸**（`width/height:48` 缩略图、`height:160` 播放器区、`Divider(height:32)`、图标 `size`）**不**走 Token，保留字面量。
  - **控制范围**：顺手吸附只对高频文件动手，**不扫荡全仓**；已迁移示范 `lib/ui/item_view_template.dart`、`lib/ui/content_card.dart`（新代码强制、旧代码留缓冲）。

## 渲染性能与生命周期

- **`prefer_const_constructors` 已提升为 Error**（`analysis_options.yaml`）：编译期固化不变 UI 树，减轻 GC、保列表滑动与动画满帧；非 const 构造（`EdgeInsets.fromLTRB` / `BorderRadius.circular`）不受约束。
- **可复用 / 有内部状态的 UI 碎片抽独立 `StatelessWidget`**（`ContentCard` 已如此）；避免在 `StatefulWidget.build` 里写大段返回 Widget 的方法，否则父重绘时子树无法 const 化、失去精准 diff。
- **纯视图控制器强绑定生命周期**：`ScrollController` / `TextEditingController` / `AnimationController` / 媒体播放器必须配对 `dispose()`（播放器已落实，新加须同等）。
- **计算密集丢 Isolate**：大体积 `machine_json` 编解码、Markdown AST 解析、AI 产出组装超过阈值（> 几十 KB / 列表滑动期间）用 `Isolate.run` / `compute`；隔离 Isolate 拿不到 `repo` / `File` / 插件句柄，只传纯数据，涉 sqflite / 插件的留在主 Isolate 调度。ML Kit OCR / Sherpa 转录已落原生线程。

## 异步加载三态（严禁红屏）

当前状态靠 `Repository` ChangeNotifier（见 `goodshare-arch`「响应式数据流」），**不用 Riverpod / `AsyncValue`**；但加载三态是硬规则：

- 任何 repo 读取 / `_reload` 的 UI 呈现必须 `try-catch` 兜错，提供 **loading（M3 骨架屏 / `CircularProgressIndicator`）** 与 **error 降级（统一「加载失败，点击重试」占位）**，绝不允许未捕获异常抛红屏。
- 精准重绘由 ChangeNotifier 通知 + 局部 `setState` 天然满足；进一步把易变子树抽独立 Widget 缩小重绘范围。

## 沉浸式与多设备避让

- 底部内容 / 悬浮元素必须 `SafeArea` 避让全面屏手势区（常驻速记条、底部操作条等以 `Scaffold` 自动避让为准）。
- **弹起输入法的 BottomSheet 必须 `isScrollControlled: true` 且内容 `Padding(bottom: MediaQuery.of(context).viewInsets.bottom)`**（`item_detail_page._edit`、`home_shell` 添加面板已示范；新增 sheet 一律照此）。

## 交互反馈（UI 必须有响应）

- 可点击卡片 / 按钮用 `InkWell` 或 M3 原生按钮（ListTile / FilledButton / OutlinedButton），保证水波纹反馈。
- **长按 / 重要分支操作（删除确认、重分类）须 `HapticFeedback.lightImpact()`**（[V3] 前瞻规则：当前无长按交互，新增长按菜单时强制执行）。

## Local-first 交互拉齐（放弃乐观更新）

架构是 local-first SQLite + 仓库通知 + `RepoAutoReload`：`add_item` 落盘即 `notifyListeners`，订阅列表页毫秒级重建。

- **不做乐观占位（半透明假数据）**：会与真数据双显并引入去重复杂度。
- 写操作「有响应感」三件套：**即时关闭输入 sheet + 一次性成功 SnackBar + 靠订阅自动刷新**。仅当未来出现「经网络同步才落盘」的路径再评估乐观更新。

## 实现指针

- 取色 ~~`dynamic_color`~~（2026-09-30 废弃 → `ColorScheme.dark` override，见 `ui-spec` §2.1）；路由 `go_router`；Markdown 用 flutter_markdown 社区维护分叉（原包已归档停更，如 flutter_markdown_plus，实现前核实 pub.dev 择优）；Json 视图 `json_view`；生物识别 `local_auth`；状态 `flutter_riverpod` 为 **V2 可选**（当前未用）。
- 平台能力（截图防护等）经接口调用，不在此散写 `Platform` 分支 → 见 `goodshare-arch`「多平台适配」。

## 自查清单（改 / 加页面时自查）

1. 间距 / 圆角 / 颜色走令牌了吗？有没有裸 `fontSize` / 非品牌硬编码色？
2. 可 const 的构造都 const 了吗？大段 `build` 方法抽成小 Widget 了吗？
3. 新增 `Controller` 配对 `dispose()` 了吗？
4. 读数据有 loading / error 两态兜底吗？会不会抛红屏？
5. BottomSheet 有 `isScrollControlled` + `viewInsets.bottom` 避让吗？悬浮 / 底部元素有 `SafeArea` 吗？
6. 图片渲染走 `GoodshareImage` 并显式 `cacheWidth` 了吗？（内存口径见 `goodshare-mobile`）
7. 新增长按 / 危险操作有触觉反馈吗？图标按钮有 `Semantics` / `tooltip` 吗？
8. 用到未在 `main.dart` 覆写的 ColorScheme 槽位了吗？（漏覆写=M3 基线紫白系露出）有没有返回箭头 / 半透明禁用罩 / 裸 AlertDialog 承载重要动作？（交互硬规则见上节）
9. SVG/位图资产做色板重映射、删背景板了吗？形变交叉淡化里有同名元素同屏并存吗？
10. 自绘交互件（转盘/放大镜/画布/图片卡）包 `Semantics` + 中文 label 了吗？触感反馈按 §6.0 触感映射表对号了吗？（取消/关闭/返回不走震动）
