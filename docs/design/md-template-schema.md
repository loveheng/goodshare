---
status: draft
updated: 2026-10-02
---

# Markdown 模板文件格式约定（模板/Skill 资产协议）

> **定位**：V2 资产协议预留——**纯数据格式约定，不含任何 UI 渲染与执行逻辑**（渲染/执行见 [agent-workflow-skill.md](agent-workflow-skill.md)，V4）。目的：V2 阶段用户随手创建、粘贴含 Front Matter 或 `{{slot}}` 占位符的 Markdown 时，解析引擎优雅兼容、不崩溃不乱码。
> **拍板**：2026-10-02（用户：双轨并行——V2 锁协议，V4 立项完整方案）。

## 1. 文件形态

一份模板 = 一份纯 Markdown 文件（**SSOT 零冗余**）：

- **YAML Front Matter**：给渲染层看——声明元数据与槽位（几十字节，不含样式）；
- **Markdown Body**：给 AI 看——Prompt 结构（Role/Rules）或最终文档骨架，槽位以 `{{slot_id}}` 行内占位。

同一个文件，**用户视角是「模板」，AI 视角是「Skill」**——只是不同消费端的表现形式。

## 2. Front Matter Schema

```yaml
---
id: weekly_report_v1          # 全局唯一，kebab-case + 版本后缀
name: 极速周报整理             # 展示名
category: 工作协同             # 分类（自由文本）
icon: 📝                      # emoji 字符，非资源引用
summary: 一句话说明（列表卡片摘要）
slots:                        # 槽位声明，可空数组
  - id: raw_notes             # 槽位标识，body 中以 {{raw_notes}} 引用
    label: 笔记/语音记录       # 用户可见标签
    type: textarea            # input | textarea（仅数据类型，非样式）
    description: 粘贴乱序的讨论记录或语音转写文本
---
```

**字段纪律（防臃肿铁律）**：Front Matter 只描述**数据元信息与槽位类型**，**严禁任何 UI 样式字段**（color/font_size/border_radius…）——控件样式 100% 由 App 本地 Theme/设计系统决定（2026-10-02 拍板）。

## 3. 槽位占位符

- 语法：`{{slot_id}}`，行内占位；body 中引用的 slot_id 必须在 front matter `slots` 有声明（未声明视为普通文本）；
- 序列化纪律：渲染态（无论空/已填）反序列化后必须还原为标准纯 Markdown——**纯文本 SSOT 不可破坏**；
- 槽位值本身是纯文本（V2 预留；多模态素材引用的编排在 V4 定义）。

## 4. 解析容忍度（V2 行为基线）

现行自建渲染器对模板文件的**不识别即兼容**口径：

- **Front Matter**：`---` 围栏内容未识别时按普通块渲染（分隔线 + 文本），不崩溃、不吞内容；
- **`{{slot}}`**：未识别时按字面文本渲染，不得吞字符或触发解析异常；
- 满足以上两条即 V2 合规——**不做任何主动的模板识别/高亮**（那是 V4 的 SlotSpan 扩展）。

## 5. 存储边界（2026-10-02 拍板）

- 模板独立存放 **`documents/templates/`**，**不进 `inbox_items`**（模板不是收集内容，混入列表污染吞噬口）；
- **纳入备份**（S3 备份白名单新增 templates 目录）——模板是用户/AI 共同沉淀的资产；
- 同格式层（都是 md）、不同数据层（与条目库隔离）。

## 6. V2 红线

**速记吞噬口永远是最高优先级**：用户点开 App 输入时，默认零模板元素（无选择器、无提示）；仅当用户显式点击工具行 `+` / `✨ 模板` 时才露出精选模板（个位数，防爆炸——完整生命周期管理 V4 落地）。

## 7. 分期

| 期 | 内容 |
|---|---|
| V2（本期） | 锁定本协议（Schema + 存储边界 + 解析容忍度）；**零代码**（现行渲染器已满足容忍度基线，实施前以用例验证一次） |
| V4 | SlotSpan AST 扩展（双向渲染）、执行引擎、MCP `read_skill`/`save_skill`、模板生命周期——SSOT：[agent-workflow-skill.md](agent-workflow-skill.md) |
