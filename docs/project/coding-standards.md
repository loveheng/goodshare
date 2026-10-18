---
status: active
updated: 2026-10-17
---

# goodshare 工程规范（编码规则契约）

> 本文是工程编码的**结构立法 SSOT**——分层依赖矩阵、机械护栏映射、新功能落点决策、质量门禁。只写规则，不写论证；**功能落点现状数据住 [`index.md`](index.md)**，本文按节引用。
>
> 规则 landscape 分工（防双源，各管一段互不复制）：
>
> | 层面 | 事实源 |
> |---|---|
> | **结构立法**（分层矩阵 / 护栏映射 / 落点决策 / 门禁） | 本文 |
> | **写路径行为规则**（七条硬规则 / 三套机制 / 自查清单） | `goodshare-arch` skill（论证 SSOT = [`human-ai-parity.md`](../architecture/human-ai-parity.md)） |
> | **立法原则 / AI 操作者专章 / 反模式 / 明确不做** | [`../engineering/ai-dev-spec.md`](../engineering/ai-dev-spec.md) |
> | **命令 / 环境 / 插件口径 / R1–R5 项目硬规则** | `goodshare-workflow` skill |
> | **功能落点数据** | [`index.md`](index.md) |
>
> 冲突裁决：`context/epics/<epic>/memory.md` 显式决策 ＞ 项目 skill ＞ 本文与 ai-dev-spec（互补不重叠）＞ 通用惯例。

## 1. 分层依赖矩阵（权威）

拓扑 = **分层目录**（UI / 动作 / 数据 / 领域 Store / AI 管线 / MCP / 摄入 / 媒体接口），写路径**严格单向**：UI 与 MCP 是两个平等客户端，均经动作层触达数据层，无旁路。

| 层 | 目录 | 角色 | 允许出向 | 本层禁止 |
|---|---|---|---|---|
| **UI 层** | `lib/pages/` `lib/ui/` | 交互态（选中/草稿/画笔）、渲染、手势采集 | 读经 `Repository`、写经 `ItemActionHandler`、生命周期经 `AppLifecycleManager` | 文件 IO、`jsonDecode/Encode`、路径拼接、直连 `repo.add`/`enqueueTask`（R1）、`Platform.isX` 分支（R3）、裸 `Image`（R4）、裸排版字面量（R7）、领域判定 |
| **动作层** | `lib/action/` | 命令协议 + UI/MCP/管线**共用**唯一写路径 `execute`/`executeAll` + `machine_json` Schema 校验 + **全部领域防呆** | `data` | 重复造写入口；把校验留在 UI / MCP 层 |
| **数据层** | `lib/data/` | `Repository`（唯一查询入口 + ChangeNotifier + FIFO 写锁）、sqflite 十表 | ——（叶子） | 领域规则 |
| **领域 Store** | `lib/models/` | 类型专属领域数据读写落盘（标注、草稿） | —— | UI 直接读写文件 |
| **AI 管线** | `lib/ai/` | `AiReconstructor` 抽象/Registry/队列消费者、端侧翻译/转写/媒体派生 | `action`（回写命令）、`data` | 在 `Repository.synchronized` 锁内 await 重活 |
| **MCP 服务** | `lib/mcp/` `lib/service/` | 复用动作层/数据层的对外工具面与前台保活总控 | `action`、`data` | 复制 UI 业务逻辑；自建校验 |
| **摄入** | `lib/share/` | 系统分享接收、归一、附件落盘 | `action`（`CollectCommand`/`AppendSegmentCommand`） | 直写 `repo.add`/`repo.update`（R5） |
| **媒体接口** | `lib/media/` + `MediaBridge.kt` | 原生媒体能力抽象（探测/解码/切片/导出） | —— | 业务层散写 MethodChannel |

`main.dart`（装配入口）可 import 任意层——装配唯一例外，收敛纯装配职责（主题 / `ColorScheme` override / 生命周期枢纽挂载 / imageCache 限额 / textScaler 钳制），**业务逻辑不得回灌 `main.dart`**。

**结构判据**（新增代码必过）：① 新消费点不就地构造共享底座——`Repository` 等经装配/构造注入单一实例；② 领域态与视图态不同居一个 `State`——页面 `State` 只持交互态；③ 平台差异收敛到接口实现，`if (Platform.isX)` 只许出现在工厂/DI 或平台实现内部。

## 2. 机械护栏映射（规则正文 → 检查器）

凡本文明确规定的红线，必须有机械拦截；规则正文在本文与对应 skill，**脚本只镜像不立法**。

| 规则项 | 检查器 | 拦截时机 | 规则正文 |
|---|---|---|---|
| R1 UI 层禁直连 Repository 写方法 | `arch-guard.sh` | pre-commit（`toolbox run arch-guard`，别名 ag；聚合门禁 pcg 自动分派） | 本文 §1 矩阵 + `goodshare-arch` |
| R2 UI 层禁内联 JSON 编解码 | 同上 | 同上 | 同上 |
| R3 UI 层禁 `Platform` 分支 | 同上 | 同上 | 同上 |
| R4 禁裸 `Image.file`/`Image.network` | 同上 | 同上 | `goodshare-mobile`（cacheWidth 陷阱） |
| R5 摄入路径禁直写 Repository | 同上 | 同上 | `goodshare-arch` 硬规则 1 |
| R6 禁另起 `WidgetsBindingObserver` | 同上 | 同上 | `goodshare-mobile`（AppLifecycleManager 枢纽） |
| R7 排版禁弃用 `textScaleFactor` + 裸 `fontSize` 字面量 | 同上 | 同上 | `goodshare-ui`（视觉令牌） |
| 对外契约（MCP 返回结构） | `test/mcp_server_test.dart` | `flutter test` | `goodshare-arch`「跨域隐式契约」 |
| 静态检查 | `flutter analyze` | 质检流水线 | —— |

- **白名单纪律（只减不增）**：`arch-guard.sh` 内豁免清单均为「规则不适用」的性质例外，**非待迁移的违规**；迁移一个删一行，禁止新增。
- **红灯处置**：命中即改结构（下沉动作层 / 走接口注入 / 换 `GoodshareImage`），**不得申请加白名单**。
- 机械镜像缺口：goodhub 式 `test/architecture` 依赖方向测试当前**不存在**——依赖方向由本文矩阵 + arch-guard R1/R5 + Review 把守；若域间依赖膨胀再立项补镜像（先登记 `index.md`，防过度工程）。

## 3. 新功能落点决策表

| 新功能类型 | 落点 | 关键约束 |
|---|---|---|
| 新系统分享入口 / 摄入归一 | `lib/share/` | 摄入禁直写 repo，走 `CollectCommand`/`AppendSegmentCommand`；插件字段形状以 pub 缓存源码取证（勿凭记忆） |
| 新持久实体 / 查询 | `lib/data/` | `Repository` 唯一查询入口；schema 升级走版本迁移；向量类派生表不进备份、可全量重算 |
| 新写动作（UI/MCP 共用） | `lib/action/` | 命令对象 → `execute` sealed switch → `supportedOps` → 主体矩阵核对 → MCP 工具 → `mcp_server_test` 契约测试，**同轮全链接线**（自查清单 = `goodshare-arch`） |
| 新 AI 能力（重构/转写/翻译/切片） | `lib/ai/` | 队列任务化（入队即返）；降级「完成但无产出」可观测（workflow R1/R3）；心跳防僵尸回收（`goodshare-mobile`） |
| LLM 类任务 | 远程接缝 | 本地不持引擎；契约 SSOT = `docs/design/ai-app-split.md`（跨仓只读），改动同轮修该文档 |
| 新 MCP 工具 | `lib/mcp/tools.dart` | 复用动作层不自建校验；description 主动引导正确用法；错误契约 `code`+`hint` |
| 新页面 / 组件 | `lib/pages/` `lib/ui/` | 先过 `goodshare-ui` 查阅指引与自查清单；规范先行（无先例先扩 ui-design 再实现） |
| 新平台能力（跨端差异） | 抽象接口 + 平台实现 | 禁 `Platform.isX` 外溢（R3）；Android 先行，iOS/鸿蒙实现同一接口 |
| 新媒体原生能力 | `lib/media/` + `MediaBridge.kt` | MethodChannel `goodshare/media` 收口；探测失败 null 非阻断、冷门格式降级文案 |
| 新自更新 / 备份同步 | `lib/update/` `lib/sync/` | 凭证只入 `.env`（禁入库）；发布链 = `goodshare-workflow` §3；Vault 数据排除出备份 |
| 新跨域共享类型（DTO/错误枚举） | 数据层或归属域 | 纯 Dart 优先；单处使用者不抽库（ai-dev-spec §6 YAGNI） |

## 4. 新顶层域纪律

`lib/` 新增一级目录（上表 8 层之外）须**三处同步**，缺一即护栏盲区：① 本文 §1 分层矩阵（角色 + 允许出向 + 禁止项）；② [`index.md`](index.md) 归属表（落点 + 文档指针）；③ 若涉新机械规则，`arch-guard.sh` 加规则（带自测）。**拍板前禁止新增前缀**——先问「是否可落现有层的子目录」。

## 5. 质量门禁

- **交付线**：`flutter analyze` 0 issue + `flutter test --timeout 60s` 全绿 + `arch-guard` 0 红（命令原文 = `goodshare-workflow` §1，按耗时从小到大，任一步失败禁止提交）。
- **契约测试纪律**：改 `lib/mcp/tools.dart` 返回结构必须同步 `test/mcp_server_test.dart`；新增命令必须补 `action_handler_test` 写路径用例（FakeAsync 纪律 = workflow R5）。
- **测试基线纪律**：门禁 = **不劣于开工前实测基线**，**不锁死测试总数**——新增用例只增不删，删用例须在 devlog 说明理由。
- **组件沉淀**：可复用 UI 碎片抽独立 Widget / 模板（`ItemViewTemplate` + Registry 范式，新增类型零改框架）；**仅单处使用者不抽库**。

## 6. 维护协议

- **触发器**：什么信号改本文什么节，路由表 = `goodshare-workflow`「规范数据维护触发器」（本文不重复）。
- **修改即刷新**：实质修改同轮 ① 刷新 frontmatter `updated`；② 核对 §2 护栏映射与 `arch-guard.sh` 是否需同步（脚本只镜像）；③ 涉及文档归属的按 `goodshare-docs` 维护协议三处同步；④ 落点现状数据同步 [`index.md`](index.md)。
- **规范移动/改名**：全仓 grep 文件名修引用（含 arch-guard.sh 头注释、各 skill）。
- **废弃**：走 docs-spec 墓碑协议（`status: deprecated` + 转向继任文档），禁静默删除。
