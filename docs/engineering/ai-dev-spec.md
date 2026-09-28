---
status: active
updated: 2026-09-28
---

# AI 协作开发规范（engineering/）

> 定位：约束**人 + AI 双操作者**的工程规范。以通用前端团队规范为底本改造——立法原则从「人类读散文、靠自觉」换成「机器读断言、靠工具执行」。架构与写路径的完整论证见 [human-ai-parity.md](../architecture/human-ai-parity.md)（SSOT），本文不重复其论证，只装约束清单与判定方法。

## 0. 立法三原则

1. **可判定**：每条规则 AI 必须能在写完代码后自查「违没违反」。无法自查的散文规则（"尽量""避免"）必须改写成可判定内核或删除。
2. **带意图**：每条硬规则配「规则 + 为什么 + 检查器」三件套——「为什么」是 AI 遇到未覆盖新场景时泛化的依据。
3. **防过度**：AI 默认倾向是过度服从（把鼓励执行成教条）与过度工程（提前建框架）。反模式与「明确不做」清单比正面清单更重要。

## 1. 架构与目录

- **目录分层**（落点与各层禁止项见 `goodshare-arch` skill 的分层表）：新文件必须落对应层目录，禁止在根目录或业务目录平铺临时文件。检查：arch-guard + review。
- **全局/局部状态边界**：全局数据源唯一（`Repository extends ChangeNotifier`），页面交互态（选中/草稿/画笔）留页面 `State`。新增全局状态先问「多页面共享吗」——否即留局部。
- **写路径唯一入口**：所有写（UI/MCP/管线）一律组装 `ItemCommand` 经 `ItemActionHandler.execute`/`executeAll`；摄入链路走 `CollectCommand`/`AppendSegmentCommand`。**为什么**：校验必须下沉唯一入口，每多一个入口漏一遍校验（历史教训：set_vault(off) 曾漏在 MCP 层）。检查：arch-guard R1/R5。
- **网络请求集中**：本项目 local-first 几乎无网络；仅有的 HTTP（模型下载 `lib/ai/model_manager.dart`、自更新 `lib/update/`）按域归位，禁止在页面/组件层出现 `http`/`Dio` 调用。检查：grep 页面层 import。

## 2. 编码与工程化

- **静态检查即交付线**：`flutter analyze` 0 issue；`prefer_const_constructors` 已升为 error（`analysis_options.yaml`）。
- **命名**：Dart 官方风格——文件 snake_case、类型 PascalCase、成员 camelCase、布尔 is/has 前缀。检查：analyzer 自带。
- **依赖准入**（可量化，替代"评估活跃度"的散文）：新依赖须在提交说明附——① 与现有依赖功能重叠检查（pubspec 全文 grep）；② 维护状态（最近发版 ≤12 个月）；③ 平台覆盖（Android 必须支持，iOS/鸿蒙预留）。评估结论沉淀进 `goodshare-workflow` 的插件 API 口径表（版本号锁定），不重复评估。
- **提交门禁**：改动 `lib/` 后与提交前跑 `toolbox run arch-guard`（7 条规则，白名单只减不增）。

## 3. 跨平台与性能

- **布局**：长列表/滚动内容必须 `ListView.builder`/`Sliver` 族；底部弹层必须 `isScrollControlled` + `viewInsets.bottom` 避让；悬浮/底部元素 `SafeArea`。绝对定位仅限贴边悬浮件（悬浮球模式）。检查：goodshare-ui 自查清单。
- **平台分支收敛**：`if (Platform.isX)` 只许出现在工厂/DI 或平台实现内部，禁止外溢到页面/组件/State；跨端能力一律抽象接口 + 平台实现。检查：arch-guard R4。
- **图片与内存**：图片渲染一律 `GoodshareImage` + 显式 `cacheWidth`，禁止裸 `Image.file`/`Image.network`（同图双缓存陷阱）；imageCache 已限额 100MB/500 张，勿调高。检查：arch-guard R3。
- **排版自适应**：全局 textScaler 钳制 1.0~1.5；固定高度容器必须自适应，防大字号 overflow。

## 4. AI 操作者专章（对人类规范的本质增量）

### 身份与权限

- 操作主体（`ui`/`ai`/`pipeline`）**由传输层注入，禁止从命令载荷读取**——否则模型可在 JSON 里自称 `"actor":"ui"` 越权。
- 主体 × 命令矩阵见 `goodshare-arch`（不可逆操作仅 `ui`、管线回写仅 `pipeline`）；新增命令时同步矩阵与 `supportedOps`。

### 写路径契约

- 写后**必回最新快照**（`CommandResult.item`，与 `get_item` 同形状）；移出可见域置 `item:null`。禁止回 void/纯成功文案——调用方（尤其大模型）上下文必须与库内状态对齐。
- 多步改动走 `executeAll` 事务批量（全回滚）；不可逆副作用（`delete_forever` 删文件）禁止混入批量。禁止为批量开绕过校验的快车道。

### 错误契约

- 拒绝统一抛 `ActionException(message, code, hint)`：`code` 机器可读（`edit_locked`/`version_conflict`/…），可纠正分支**必须带 hint**（告诉调用方下一步）。禁止底层异常（Sqlite/FileSystem）漏出到调用方。

### 并发

- 写路径经 `Repository.synchronized` FIFO 串行；读查询不入队。锁挂 `Repository` 不挂 Handler（MCP 每次 new 实例，实例锁无效）。
- 「读→思考→写」长窗口必须带 `expectedVersion` 乐观锁，否则即静默覆盖。
- 耗时（>数百 ms）路径转 Job（入队即返 `job_id`），禁止在串行锁内 await 重活。

### 工具描述引导（给 AI 的"接口文档"）

- MCP 工具描述必须主动引导正确用法（如"多步改动优先 batch_items，别连发独立 update_item"）——这是防 AI 低效/危险操作的主动防线。
- 新增命令必须同步：`commands.dart` → `execute` switch → `supportedOps` → MCP 工具表 → `test/mcp_server_test.dart` 契约测试。任一缺失即不合格（自查清单第 1 条）。

## 5. 测试与可持续交付

- **单测交付线**：`flutter test` 全过；对外契约（MCP 工具返回结构）改动必须同步 `test/mcp_server_test.dart`。
- **组件沉淀**：可复用 UI 碎片抽独立 Widget / 模板（`ItemViewTemplate` + Registry 模式，新增类型零改框架）；**但仅单处使用者不抽库**（见 §6）。
- **异常出口**：领域异常统一 `ActionException`；UI 只做薄 try-catch 弹提示。不引入 `Result<T,E>`。

## 6. 反模式（见到即改）

- 动作层里判断「这次调用来自 UI 还是 AI」→ 校验面被切成两半。
- 在 MCP 层补「UI 已判过」的校验 → 该校验没下沉。
- 写操作返回 void / 只回成功文案 → 调用方无法对齐状态。
- 为「AI 批量方便」另开绕过校验的通道 → 批量也要逐条过 execute。
- 把耗时推理在 execute（尤其串行锁内）同步 await → 转 Job。
- 读查询进写锁队列 → MCP 写阻塞 UI 刷新。
- 只用一次的东西抽成"基础组件库" → 过度抽象，YAGNI。

## 7. 明确不做（防过度工程）

- 不引入 `Result<Success,Failure>` 类型——ActionException 链已满足。
- 不引入 Riverpod 作正确性前提——ChangeNotifier + RepoAutoReload 已够；V2 仅作可选优化。
- 不提前建无真实场景的框架（如 job_id 查询工具等真实长任务出现再补）。
- 可推导信息（目录清单/文件触点）不写进规范/索引——现场 derive。
- 纯 Dart 跨端能力（sqflite 等）不封装平台接口——只封装真有平台差异的。

## 8. 规范自身维护协议

- **时效标注**：随版本变化的事实（依赖 API 口径、SDK 约束）落 `goodshare-workflow` 并带实测日期；升级插件必须同步核实对应行。
- **裁决链**：`context/epics/<epic>/memory.md` 显式决策 > 项目 skill > 本规范 > 通用惯例。规则冲突时按此序取用。
- **白名单只减不增**：arch-guard 等检查器的豁免清单是历史例外，迁移一个删一行，禁止新增。
- **本文件修改即刷新 frontmatter `updated`**（实质修改）；废弃走 docs-spec 墓碑协议。

