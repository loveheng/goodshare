---
name: goodshare-docs
description: goodshare 的文档体系项目数据登记处：docs/ 域目录表、docs-lint 触发命令、存量例外与 AI 落笔自检三问。规范机制一律指针到全局 docs-spec，严禁复制正文。新增、修改、移动或废弃文档前先读本表与 docs/README.md。
---

# goodshare 文档体系

本 skill 是 `docs/` 的**项目数据**登记处（域目录表 / lint 命令 / 例外），不是规范机制。
规范机制（frontmatter 四字段、根目录平铺、updated 软自查、三层索引、墓碑与引用修复）一律指针到全局 skill **`docs-spec` §1–§7**，本文件不复制其正文（防双源漂移）。

## 1. 域目录表（以存量结构为准，不臆造新域）

`docs/` 现状域（与 `docs/README.md` 结构索引同源，后者为唯一事实源；本表禁记文档数/文件清单等易腐数据）：

| 域 | 路径 | 内容定位 |
|---|---|---|
| project（项目接入/工程事实） | `docs/project/` | 功能落点索引（数据）+ 编码规则契约（coding-standards）+ UI 规范 SSOT（ui-design）；索引规约 = `goodshare-index` skill |
| product（产品/跨域需求） | `docs/product/` | 全局 PRD、V2 收敛需求 |
| architecture（架构） | `docs/architecture/` | 分层总览、Human-AI 对称性（无头架构） |
| guide（接入指南） | `docs/guide/` | MCP 接入、自更新手册 |
| design（UI 设计规范） | `docs/design/` | 全部 UI/交互/媒体/AI 能力设计稿（多为 draft） |
| engineering（工程规范） | `docs/engineering/` | AI 协作开发双操作者约束 |

## 2. 机械校验与快速自测

修改任何 `docs/` 内容后，提交前单行触发：

```sh
toolbox run docs-lint   # 别名 dl；pre-commit-gate 对 docs/ 改动自动分派
```

- 脚本本体：`scripts/agent-tools/docs-lint.sh`（无 toolbox 直跑它）。
- 校验项：frontmatter `status`/`updated` 四项、根目录平铺、README 双向覆盖（链接存在性 + 孤儿检测）。细则 = `docs-spec §6`。

## 3. 操作纪律（正文机制指针 docs-spec，此处只列本项目动作）

- **新建**：frontmatter（`status` + `updated`）+ 同轮在 `docs/README.md` 加条目——**仅此一处**，不动本 skill、不动 `docs/project/index.md`（索引只登记「功能归属」，纯文档新增不回改）。
- **移动/重命名**：按 `docs-spec §5` 同步 README 索引并**全仓 grep 精确文件名修引用**（含各 skill 与代码注释）；若该文档是 index.md 归属表的文档落点，同轮修正。
- **废弃**：按 `docs-spec §4` 墓碑协议（翻 `status: deprecated` + 墓碑行），禁静默删除；被取代时在取代者处留一行指针（如 note-format-guidance-layer.md 取代 quick-note-format-dial.md 的先例）。
- **域级变迁（新增域/拆分/合并/整体迁移）**：按 `docs-spec §2` 三处同步——`docs/README.md` + `docs/project/index.md` + 本 skill 域目录表。逐篇文档操作**不触发**本条。

## 4. 写后自检（AI 落笔三问，任一命中即删/移；判据正文 = `docs-spec §7` 反模式）

1. 这句是**现行事实**，还是**关于事实的历史**（何时新增/迁入/谁拍板）？——历史移交 devlog/memory，正文删。
2. 是否写了「原没有 X」「此前缺失」「暂无 + 解释正常流程」类自证句？——删，只留结论。
3. 是否在复述另一事实源（文档数/文件清单/状态列）？——删，留指针指向唯一事实源（README / frontmatter / index）。

## 5. 本仓例外（存量与 docs-spec 的冲突；不静默改写存量）

- `docs/architecture/overview.md`、`docs/guide/self-update.md`：使用非标准 `> status:` **块引用** frontmatter，而非标准 YAML `status:` 字段。已记入 `docs/README.md` 待归一，迁移按 `docs-spec §4/§5` 墓碑与引用修复纪律执行，不属默认动作。
- `docs/design/` 大量文档 `status: draft`（未拍板设计稿）：属产品既定状态，lint 不报错；落地实现前不得视 draft 为事实源（口径见各稿头部「待拍板」声明）。

## 维护协议

- **fact-probe 底稿处置（接入/对账场景）**：项目形态先判定——非编码工作区不接入（dev-init §1 第 1 步，留一行理由）；存量项目须将 fact-probe 底稿与既有 `<repo>-workflow` skill **逐条 diff**，差异点按 **dev-init §1.5 第 1 项**核实（命令实测 ≥1 条跑通、语义命名 AI 提炼，底稿严禁直接采信）。
- 域目录表只随**域级变迁**更新（`docs-spec §2`），逐篇文档增删不回改本 skill；表内禁记文档数、文件清单等易腐数据，禁写过程叙事（何时新增/迁入/「原没有 X」）——见 `docs-spec §7` 反模式。
- 规范机制变更不回改本 skill；全局 docs-spec 升级时本文件无需改（指针即同步）。
