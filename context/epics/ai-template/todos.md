---
memo: todos
format: v3
epic: ai-template
---

# ai-template · 域内待办
- [x] (功能)(层:L2)(重:重) P1 数据模型：templates 表 + inbox_items 模板产出三列（v23 迁移）+ Template/InboxItem model → 已落地 (src: data)
- [x] (功能)(层:L2)(重:重) P1 Repository Template CRUD + TemplateCommand 三件 + handler（写走 ItemActionHandler 同出口）→ 已落地；template_output 打码归 P2 apply (src: data/action)
- [x] (功能)(层:L2)(重:中) P1 MCP 模板 CRUD 工具（create/update/delete/list_template）+ get_item 暴露 template_output → 已落地（工具数 38→42） (src: mcp)
- [x] (功能)(层:L2)(重:中) P1 skill resource 派生 goodshare://templates/{id}（templateSkillMd，双视图同源） → 已落地 (src: mcp)
- [x] (功能)(层:L2)(重:中) P1 人类只读模板预览页（TemplatePreviewPage，按 workspace 分组、渲染 body_md、无编辑入口）+ 设置页入口 → 已落地 (src: pages)
- [x] (功能)(层:L1)(重:中) P1 ADR：模板管理权归 AI 有意不对称 → 已落 decisions.md (src: docs/decisions)
- [x] (功能)(层:L2)(重:重) P2 存量内容选模板 → 入队 template_apply → 远程集合 + claim 解析 + apply 回写 template_output + 详情页入口 → 已落地（2026-10-14 初版 + 2026-10-15 只追加硬化/授权断点/呈现规约，见 devlog） (src: 全链)
- [ ] (功能)(层:L2)(重:中) P3 宿主产品化：模板作为 skill 纳入宿主消费/同步（宿主侧真机验收：选模板 → claim → apply 回写只追加） (src: goodhub)
