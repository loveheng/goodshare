---
name: goodshare-docs
description: 拾贝 goodshare 的文档体系归属索引——只登记三项项目数据：docs/ 域目录表、本仓 docs-lint 脚本路径、存量与 docs-spec 的例外。规范机制一律指针到全局 docs-spec，严禁复制正文。改/增/移动/废弃文档前先查本表与 docs/README.md。
---

# goodshare 文档体系

本 skill 是 `docs/` 的**项目数据**登记处（域目录表 / lint 脚本路径 / 例外），不是规范机制。
规范机制（frontmatter 四字段、根目录平铺、updated 软自查、三层索引、墓碑与引用修复）一律指针到全局 skill **`docs-spec` §1–§7**，本文件不复制其正文（防双源漂移）。

## 1. 域目录表（以存量结构为准，不臆造新域）

`docs/` 现状域（与 `docs/README.md` 结构索引同源，后者为唯一事实源）：

| 域 | 路径 | 内容定位 | 文档数 |
|---|---|---|---|
| product（产品/跨域需求） | `docs/product/` | 全局 PRD、V2 收敛需求 | 2 |
| architecture（架构） | `docs/architecture/` | 分层总览、Human-AI 对称性（无头架构） | 2 |
| guide（接入指南） | `docs/guide/` | MCP 接入、自更新手册 | 2 |
| design（UI 设计规范） | `docs/design/` | 全部 UI/交互/媒体/AI 能力设计稿（多为 draft） | 28 |
| engineering（工程规范） | `docs/engineering/` | AI 协作开发双操作者约束 | 1 |

## 2. 本仓 lint 脚本路径

- 机械校验：`scripts/agent-tools/docs-lint.sh`（项目 toolbox 工具 `docs-lint`，pre-commit 门禁）
- 校验项：frontmatter `status`/`updated` 四项、根目录平铺、README 双向覆盖（链接存在性 + 孤儿检测）。细则见 `docs-spec §6`。

## 3. 本仓例外（存量与 docs-spec 的冲突；不静默改写存量）

- `docs/architecture/overview.md`、`docs/guide/self-update.md`：使用非标准 `> status:` **块引用** frontmatter，而非标准 YAML `status:` 字段。已记入 `docs/README.md` 待归一，迁移按 `docs-spec §4/§5` 墓碑与引用修复纪律执行，不属默认动作。
- `docs/design/` 大量文档 `status: draft`（未拍板设计稿）：属产品既定状态，lint 不报错；落地实现前不得视 draft 为事实源（口径见各稿头部「待拍板」声明）。

## 维护协议

- 域表禁止一次性铺满（project-index「表格式规范」「维护协议」）；新增域/大文档时同步更新 `docs/README.md` 与 `goodshare-index` 的「文档落点」列（三处同步）。
- 规范机制变更不回改本 skill；全局 docs-spec 升级时本文件无需改（指针即同步）。
