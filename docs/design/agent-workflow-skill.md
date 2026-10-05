---
status: draft
updated: 2026-10-02
---

# V4 · App 内 Agent 工作流与 Skill 体系设计

> **定位**：[PRD §9 V4](../product/product-requirements.md)「app 内 agent/自动化引擎」的**工作流配置层**前置设计——Skill 库就是 agent 的工作流配置，一个体系两块拼图。协议层（模板文件格式）已随 V2 锁定：[md-template-schema.md](md-template-schema.md)。
> **拍板**：2026-10-02（用户：双轨并行——V2 锁协议，本方案归档为 V4 底层基石）。

## 1. 核心抽象：一份 md，两个视角

- **用户视角 = 模板**：看到最终文档的雏形，只在槽位处填空（Fill-in-the-Blank，确定性感知，零提示词疏离感）；
- **AI 视角 = Skill**：带一等公民约束、上下文完整的执行规范（Front Matter=槽位声明，Body=Role/Rules）；
- **闭环**：AI 自主生成 skill → 自动填槽执行 → 产出最终文档 → skill 落盘沉淀复用（Self-Improving Agent：越用越聪明的技能库）。

## 2. 双向渲染：SlotSpan AST 扩展（复用自建渲染器，零第三方依赖）

Flutter 无现成「双向 md 控件」；拾贝自建渲染器 + 块编辑器（parse↔serialize 互逆、`blockEditText`/`rebuildBlock` 纯函数映射）即现成底座，`{{slot}}` 仅需新增一种行内节点：

```
{{architecture_type}} 解析映射：
InlineSpan 家族新增 SlotSpan(
  id, label,                       // 来自 front matter slots
  state: empty | filled,
  value,                           // 已填内容
)
```

- **Empty 态**：高亮底纹占位卡，Tap-to-Edit → 底部抽屉输入（移动端主形态；内嵌高亮编辑仅备选）；
- **Filled 态**：正常文本渲染 + 轻量标记，保持「看即是全貌」；
- **Serialize**：还原为标准纯 Markdown，SSOT 不可破坏（与 §4.3 块编辑器防压平纪律同源）。

## 3. HCI 四对策（本体系成立的体验前提）

| # | 对策 | 内容 |
|---|---|---|
| 1 | **零阻力模板入口** | 速记吞噬口默认零模板元素；模板选择永远可选不挡路，仅显式 `+`/`✨` 才露出精选（个位数）；不强制首步 |
| 2 | **先猜后问** | 能从素材自动推断的槽位自动填（贴入文本自动填 raw_notes 类槽），用户只补 AI 猜不了的空——多槽位多次弹键盘是移动端体验毒药 |
| 3 | **模板生命周期** | 按最近使用排序、AI 顺手合并去重、低频自动归档——防「AI 自生成模板」把 Skill Hub 变成第二个收件箱；列表层只露精选 |
| 4 | **两段式延迟透明化** | 「生成模板→执行」比直接生成慢一拍：状态可观测沿用 R1 规则（同一份文案进 UI 与 MCP）；高频场景跳过生成直接命中已有 skill |

## 4. 三大架构决策点（2026-10-02 拍板）

1. **存储位置**：`documents/templates/` 独立目录，不进 `inbox_items`；**纳入 S3 备份**（用户/AI 共同沉淀的资产）；同格式层、不同数据层（SSOT：[md-template-schema.md](md-template-schema.md) §5）。
2. **执行引擎归属**：**默认 AI 客户端经 MCP 执行**（读 skill→填槽→生成——「繁重工作归 AI」拍板的延伸）；端侧 4B 可执行简单模板作离线档；**App 自身不做执行管线**（编排逻辑不埋业务层，与 V4 agent 引擎的独立成层纪律一致）。
3. **安全与审计**：AI 自生成模板=AI 写 prompt 给下游模型，有注入面。审计靠「看即是全貌」——模板 md 全文用户可见可删；`save_skill` 为**高权限动词**，门控挂 V3 分域授权的信任客户端档（PRD §9 V3）。

## 5. MCP 工具增量（V4 实装）

| 工具 | 语义 | 门控 |
|---|---|---|
| `read_skill(id?)` | 列出/读取模板 md（列表只回传 front matter 概要） | 读，默认开放 |
| `save_skill(content)` | AI 落盘自生成模板（Schema 校验不过即拒） | **高权限**：V3 分域授权信任档 |

## 6. 与既有体系的关系

- **协议层**（已锁）：md-template-schema.md——V2 解析容忍度基线；
- **渲染层**（本期设计）：SlotSpan 扩展复用规则层/块编辑器，新块类型走既有注册机制；
- **执行层**（V4 主体）：agent 引擎（PRD §9 V4）消费 skill 库作为工作流配置——AI 既是 skill 的创造者又是使用者；
- **数据层**：skill 沉淀的模板文件进备份、不进条目库；模板的「双视角」与 human_md/machine_json 双态、灵感区双消费者（ui-spec §4.3）同构——一份派生物，多端消费。
