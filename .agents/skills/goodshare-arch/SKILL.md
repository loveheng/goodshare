---
name: goodshare-arch
description: 拾贝 goodshare（Flutter 分享收集器+MCP）分层架构与无头（Human-AI 对称性）硬约束：UI 禁内联业务、写必走 ItemActionHandler 命令入口、防呆下沉动作层、CommandResult 回最新快照、executeAll 事务、FIFO 串行锁（挂 Repository）/乐观锁 version/耗时路径 Job 化、CommandActor 主体门控、跨端能力接口化。新增或修改写路径（命令/动作层/MCP 工具/摄入链路）、新页面分层、跨端平台能力前先读；设计 SSOT 见 docs/architecture/human-ai-parity.md。
---

# goodshare 架构与写路径规范

**设计 SSOT = `docs/architecture/human-ai-parity.md`**（试金石、命令矩阵、并发机制的完整论证在那儿）。本 skill 只装三样文档里没有的东西：**落地锚点、踩坑口径、自查 / 反模式清单**。

## 用法

1. 动 `lib/action/`（命令 / 校验）、`lib/mcp/tools.dart`、摄入链路 `lib/share/`、或给页面加写操作前，先读 `docs/architecture/human-ai-parity.md`。
2. 按本文件「自查清单」逐条过。
3. 收尾跑机械护栏：`toolbox run arch-guard`（7 条规则：UI 禁直连 repo 写 / 禁内联 json / 禁 Platform 分支 / 禁裸 Image / 摄入禁直写 repo / 禁另起 WidgetsBindingObserver / 禁裸排版字面量；规则与白名单见 `scripts/agent-tools/arch-guard.sh`）。

## 分层架构（UI 与业务分离）

**UI 层只负责交互态与渲染，禁止内联任何业务逻辑**；领域规则、持久化、文件 IO、JSON 编解码一律下沉。

| 层 | 目录 | 职责 | 本层禁止 |
|---|---|---|---|
| **UI 层** | `lib/pages/` `lib/ui/` | 交互态（选中/草稿/画笔/颜色）、渲染、手势采集；读经 `Repository`、写经 `ItemActionHandler` | 文件 IO、`jsonDecode/Encode`、路径拼接、直连 `repo.add`/`enqueueTask`、领域判定 |
| **动作层** | `lib/action/`（commands.dart / item_action_handler.dart / machine_json_validator.dart） | 命令协议 + UI/MCP/管线**共用**唯一写路径 `execute`（`executeAll` 事务批量）+ `machine_json` Schema 校验 + **全部领域防呆** | 重复造写入口；把校验留在 UI / MCP 层 |
| **数据层** | `lib/data/`（db.dart / repository.dart） | `Repository`（共用查询入口）、sqflite 三表、FIFO 写锁 | 领域规则 |
| **领域 Store** | `lib/models/`（annotation.dart / draft_store.dart） | 类型专属领域数据读写落盘（标注、草稿） | UI 直接读写文件 |
| **AI 管线** | `lib/ai/` | `AiReconstructor` 抽象 / Registry / 队列消费者 | —— |
| **MCP 服务** | `lib/mcp/` `lib/service/` | 复用动作层 / 数据层 | 复制 UI 的业务逻辑 |

### 硬规则（违反即重构）

- **UI 不内联业务**：页面 / 组件 `State` 里出现 `File` / `Directory` / `writeAsString` / `json*` / `getApplicationDocumentsDirectory` / `repo.add` / 领域判定即违规。
- **写必走 `ItemActionHandler.execute`**：编辑 / 删除 / 移入保险箱 / 重分类 / 重新处理 / 速记 / 收集入库一律组装 `ItemCommand`，UI 与 MCP 调同一入口；AI 管线走 `ApplyAiResultCommand` + `actor: CommandActor.pipeline`。复合改动走 `executeAll` 事务批量，不逐步串行提交。
- **防呆不下放**：UI 按钮置灰只是快路径，**不是安全边界**——AI 是瞎子。任何「某状态禁止某操作」的领域规则必须写在动作层内部。
- **读经 `Repository`**，不绕开。
- **类型专属领域数据用 `*Store`**（`AnnotationStore`、`DraftStore`）；UI 只持交互态、调 store、painter 渲染。
- **媒体控制可留 UI**：`just_audio` / `video_player` 控制器属视图资源，但「转写 / 标注」等领域业务不得留在 UI。
- **MCP 复用而非复制**，不与 UI 各写一套业务。

### 异常出口（ActionException 契约）

动作层是领域异常的统一**出口**：校验不过 / 条目不可见统一抛 `ActionException`（消息即 UI 友好文案，如「合并条目已锁定，请先『解除编辑』」），不漏底层异常。MCP 层转 `McpRpcError`（`error.data={code,hint}`）；UI 只做极薄 `try-catch` 弹 SnackBar，禁止在 UI 解析 `FileSystemException` / `SqliteException`。**不引入 `Result<Success,Failure>` 类型**——异常链已满足，加 Result 属无谓 churn。

### 响应式数据流（写→读 触发）

`Repository extends ChangeNotifier`，所有写路径（含 `QueueConsumer` 经 `_repo.update` 的 AI 回写）均 `notifyListeners()`；读页经 `addListener` 订阅自动重绘。**双态一致性由该机制保证，不依赖 Riverpod**。

- **结构性约束**：新读页一律 `with RepoAutoReload`（`lib/ui/repo_auto_reload.dart`），由 mixin 托管 `addListener` / `removeListener`，杜绝漏退订；已有读页（inbox/vault/detail/timeline/recent_deleted）均已迁入。
- **例外**：`ai_tags_page` 为静态空态占位（`StatelessWidget` 不读实时数据），V2 接 `facets` 后再订阅。
- **Riverpod 定位**：V2 可选优化（包成 `StreamProvider` / `Notifier`），**非正确性前置**。

## Human-AI 对称性（无头架构）

**核心主张**：App 是「无头」系统，**UI 与 AI 只是两个平等客户端**，不存在「只有 UI 才懂」的逻辑。试金石（删掉 Flutter UI、接微信机器人能否不改核心代码跑通）与三条自测见 `docs/architecture/human-ai-parity.md` §0。

### 七条硬规则（违反即重构；展开论证见 docs §1–§4）

1. **命令模式统一入参**：动作层**只接收** `ItemCommand`。禁止 `handler.edit(id, xxx:)` 散参方法。新增动作 = `commands.dart` 加命令类 → `execute` 的 sealed switch 加分支 → 同步 `supportedOps` → 需要时补 MCP 工具。UI 组装对象、MCP 用 `ItemCommand.fromJson`、管线构造 `ApplyAiResultCommand`、**摄入（`ShareIntake` / `TextCollector`）走 `CollectCommand` / `AppendSegmentCommand`**。
   - **摄入禁止直连 `Repository`**：`lib/share/` 不得出现 `repo.add` / `repo.update`（历史教训：裸 SQL 完成「合并追加」，AI 无法并链且无防呆）。
   - **策略与约束分离**：客户端只决定「做不做 / 选哪条链」，**模式、窗口、锁定态的约束一律在动作层判定**。
2. **防呆绝对下沉**：可见性 / 编辑锁 / 重分类白名单 / `machine_json` Schema / 主体越权全在动作层内部；**禁止**只在 UI `onPressed` 或 `tools.dart` 参数校验里拦（历史教训：`set_vault(off)`、`add_item` 非空、`applyAiResult` 门控三条曾漏在 MCP 层，换个入口即绕过）。
3. **写后必回最新状态**：所有命令返回 `CommandResult`（含落库最新快照），序列化统一 `itemToJson`（与 `get_item` 同形状，AI 上下文里只有一种 item 形状）。条目移出可见域（如被 AI 移入保险箱）后 `item` 置 `null`，**不回传内容**。
4. **复合操作走事务**：多步改动一律 `executeAll`（`Repository.transaction`，全成功或全回滚）。**不可逆副作用（`delete_forever` 会删附件文件）禁止混入批量**——文件删除不随 SQLite 事务回滚。批量同样**逐条过 `execute`**，不因「批量」放宽任何领域规则；MCP 工具描述须写明「多步改动优先 `batch_items`」，主动引导 AI 别连发 5 个独立 `update_item`。
5. **写路径必须串行化**：所有写经 `Repository.synchronized` 排成 FIFO。**锁必须挂在 `Repository`**（所有客户端共享）——挂在 `ItemActionHandler` 上会**失效**：MCP 每次调用都 `new ItemActionHandler(repo)`，实例锁各锁各的。**读查询不得入队**（否则 MCP 写阻塞 UI 刷新）；**锁内禁止重活**（大文件 IO / 网络堵死全局写队列）。
6. **跨秒级改动必须带乐观锁**：凡「读 → 思考 → 写」的长窗口场景（UI 编辑器保存、AI 多步规划）必须携带 `expectedVersion`，否则就是**静默覆盖**（无报错、无痕迹）。冲突码 `version_conflict` + `hint` 引导重读最新 `version` 重试。
7. **耗时路径必须 Job 化**：预计超数百毫秒的路径（抓网页、解析 Markdown、OCR / 转写重试、外部模型调用）不得做成同步 Action。动作层只插 `ai_task_queue` 并**立即返回**（`CommandResult` 带 `job_id`），`QueueConsumer` 后台跑并更新 `pending → processing → completed/failed`；UI 经仓库通知 / `pendingCount()` 显示进度，AI 按 `job_id` 查状态。**耗时推理绝不能在 `Repository.synchronized` 锁内 `await`**。现状：底座已在，**仍缺**「`job_id` 回传 + `get_job_status` 查询工具」，等真实长任务场景再补，不提前建框架。

### 三套机制管三个尺度（不能互相替代）

| 机制 | 时间尺度 | 防什么 | 落点 |
|---|---|---|---|
| **FIFO 串行锁** | 毫秒级并发 | `await` 处交错 → 基于过期快照校验 + 后写覆盖先写（TOCTOU） | `Repository.synchronized` |
| **乐观锁 version** | 秒～分钟级**窗口** | 人类慢速编辑期间 AI 改了条目 → 静默覆盖 | `inbox_items.version` + `expectedVersion` CAS |
| **Job 化** | 秒～分钟级**执行时长** | 长耗时同步阻塞 → MCP 超时 / UI 假死 / 堵死写锁 | `ai_task_queue` + `QueueConsumer` |

### 主体 × 命令（`CommandActor`）

`actor` **由传输层注入，不由命令载荷携带**——否则大模型可在 JSON 里自称 `"actor":"ui"` 越权。

| 命令 | ui | ai | pipeline |
|---|---|---|---|
| update / delete / reprocess / unlock_edit / collect / append_segment / restore / set_vault(on) | ✓ | ✓ | — |
| set_vault(off) 移出保险箱 | ✓ | ✗ 需生物识别 | — |
| delete_forever 彻底删除 | ✓ | ✗ 不可逆 | — |
| apply_ai_result 管线回写 | ✗ | ✗ | ✓ 独享重分类特权 |

传输层映射：Flutter UI → `ui`；MCP / 大模型 / 聊天机器人外壳 → `ai`；`QueueConsumer` → `pipeline`。完整矩阵与「pipeline 能看见 Vault 条目」的理由见 docs §2。

### 错误契约

拒绝统一抛 `ActionException(message, code, hint)`：`code` 机器可读（`edit_locked` / `not_found` / `forbidden` / `schema_invalid` / `reclassify_denied` / `version_conflict` / `invalid_request`），`hint` 给下一步建议。**新增拒绝分支必须带 `code`，可纠正的分支必须带 `hint`**——只报一句人话，大模型就只能撞墙后乱猜。

### 反模式（见到即改）

- 动作层里判断「这次调用来自 UI 还是 AI」→ 校验面被切成两半。
- 在 MCP 层补一条「UI 已经判过了」的校验 → 该校验没下沉。
- 新增写动作只改 `tools.dart` 或只改 UI → 没走命令 + `execute`。
- 写操作返回 `void` / 只回成功文案 → AI 无法对齐上下文。
- 为「AI 批量方便」另开绕过校验的快速通道 → 批量也要逐条过 `execute`。
- 把耗时推理在 `execute` 里同步 `await`（在串行锁内更是双重违规）→ 转 Job。
- 读查询进 `Repository.synchronized` 队列 → 会让 MCP 写阻塞 UI 刷新。
- 把 `Mutex` 挂在 `ItemActionHandler` 上 → 无效，锁必须挂 `Repository`。

## 多平台适配（接口 + 多实现）

跨平台差异（Android / iOS / 鸿蒙）一律走**抽象接口 + 多实现**，**禁止在业务 / UI 层散写 `Platform.isX` 决定行为**。

- **抽接口**：平台无关层定义抽象（`PlatformSharePortal` / `ForegroundKeepAlive` / `SelfUpdater` / `SecureWindow`）。
- **多实现**：Android 走既有插件 / `MethodChannel` 原生（如 `lib/service/secure_window.dart` + `MainActivity.kt`）；iOS、鸿蒙（flutter_flutter fork）各自实现同一接口。
- **分支收敛一处**：`if (Platform.isX)` 只许出现在工厂 / DI 或实现内部，不得外溢到页面 / 组件 / `State`。采纳 Riverpod 后在 `main.dart` 顶层 `ProviderScope(overrides:)` 注入。
- 当前 **Android 首发**，iOS runner 已生成未适配，鸿蒙未开始；纯 Dart / 社区插件已跨端的（sqflite、flutter_markdown 等）无需封装。

## 自查清单（改 / 加写路径时自查）

1. 新动作是命令对象吗？`supportedOps` 与 MCP 工具表同步了吗？
2. 校验在动作层内部吗？UI / MCP 是否又各拦了一遍（是则说明没下沉）？
3. 返回值带最新快照吗？移出可见域时 `item` 置 `null` 了吗？
4. 多步改动走 `executeAll` 了吗？是否混入不可逆副作用？
5. 拒绝分支有 `code`（可纠正的有 `hint`）吗？
6. 新客户端接入需要复制任何校验逻辑吗？需要即不合格。
7. 写路径在 `Repository.synchronized` 内吗？锁内有耗时 IO / 网络吗？读查询被误入队了吗？锁挂 `Repository` 上了吗？
8. 长窗口编辑（编辑器保存、AI 多步规划）带 `expectedVersion` 了吗？
9. 预计耗时 > 数百毫秒的路径转 Job 了吗？返回 `job_id` 且状态可查询吗？
