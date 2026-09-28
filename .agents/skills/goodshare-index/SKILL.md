---
name: goodshare-index
description: 拾贝 goodshare（Flutter 分享收集器+MCP 服务）的「功能 → 代码落点 + 文档落点」归属索引。改分享接收、存储、MCP 工具/协议、桥接器、前台保活前先查本表定位，避免全仓扫描。
---

# goodshare 功能索引

机制/格式/维护协议见全局 skill `project-index`。

## 用法

1. 按归属表定位领域。
2. 以该路径为 include_pattern 限定搜索展开——展开结果只用于当前任务，禁止写回本表。
3. 定位不到时才全量 grep / find_path。

## 归属表

| 领域 | 覆盖功能 | 代码落点（锚点 · 展开命令） | 文档落点 |
|---|---|---|---|
| 采集 | 系统分享接收、文本/链接归一、附件落盘 | `lib/share/`（`find lib/share -type f`） | docs/architecture/overview.md |
| 存储 | sqflite 表结构、Repository 查询/删除 | `lib/data/`（`find lib/data -type f`） | docs/architecture/overview.md |
| 动作层 | UI/MCP/AI 管线共用写路径：命令协议（`ItemCommand`/`CommandResult`/`ActionException`/`CommandActor`）、`ItemActionHandler.execute`（编辑/软删/重分类/set_vault/reprocess/unlock_edit/collect/restore/批量事务）、machine_json Schema 校验 | `lib/action/`（`find lib/action -type f`） | docs/architecture/human-ai-parity.md、docs/product/product-requirements.md（§7 关键约束） |
| AI 管线 | AiReconstructor 接口/占位实现/Registry、ai_task_queue 消费者 | `lib/ai/`（`find lib/ai -type f`） | docs/product/v2-requirements.md（§3.7·§3.8） |
| 浏览 | 收集列表/搜索/详情/再分享 UI、导航/页面/设置树/组件规范、详情模板注册表 | `lib/pages/` `lib/ui/` `lib/main.dart`（`find lib/pages lib/ui -type f`） | docs/design/ui-spec.md |
| MCP 服务 | 端点/鉴权/版本协商、工具集、token 总控、前台保活 | `lib/mcp/` `lib/service/`（`find lib/mcp lib/service -type f`） | docs/guide/mcp-integration.md、docs/architecture/overview.md |
| 更新体系 | 应用内自更新（清单/下载/校验/安装）、配置热更（公告/MCP instructions） | `lib/update/` `lib/pages/update_page.dart`（`find lib/update -type f`） | docs/guide/self-update.md |
| 桌面桥接 | stdio↔HTTP 桥、e2e 自检、客户端接入配置 | `mcp-bridge/`（`find mcp-bridge -type f`） | docs/guide/mcp-integration.md |
| 构建发布 | manifest 权限/intent-filter、targetSdk、签名 | `android/`（`find android/app -type f`） | .agents/skills/goodshare-workflow |

跨域隐式契约：存储 ↔ MCP 工具（tools.dart 的返回结构是 list_items/get_item 的对外契约，改动需同步 test/mcp_server_test.dart）；前台保活 ↔ 构建发布（targetSdk=34 与 dataSync 绑定，联动记入两处文档）。

## 业务别名映射

- **收集器/收藏/分享箱** → 采集/存储域；**MCP 服务/服务器端点/工具** → MCP 服务域；**桥/bridge/桌面接入/Claude 配置** → 桌面桥接域

## 维护约定

- 可推导的不维护（路径/命名现场 derive），不可推导的才平时顺手登记；禁止为收集目的给文件新增元数据字段。
- 新增领域/大功能加一行；禁止写类清单/文件触点清单。
- 联动标记只记机器查不出的隐式契约；能用测试守护的优先加护栏。
