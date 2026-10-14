---
dev-loop: devlog
format: v1
epic: ai-template
total-merged: 0
---

（追加区：≥5 条自动归并进 memory.md）
- [2026-10-14] 立项 + 落点拍板：内容生产模板，body_md 单一源双派生；template_output 与 summary_md 语义分离、从首版独立（v23 迁移）。P1 数据模型开工。
- [2026-10-14] P1 数据模型 + Repository 层：db v23（templates 表 + inbox_items 模板产出三列）+ Template/InboxItem model + Repository Template CRUD（create/update 乐观锁/delete 不级联/list/byId）。设计修正：模板 CRUD 不经命令协议（同 workspace 定位）。schema 微调：template_id 松散无 FK、anchor 口径镜像 summary。数据层 analyze 0 issue。
- [2026-10-14] P1 AI 侧闭环：TemplateCommand 三件（create/update/delete，R2 写出口同 workspace）+ handler 处理 + MCP CRUD 工具（list_template 直调 repo、写走 handler、readOnlyHint 登记 list_template）+ skill resource 派生（goodshare://templates/{id} → templateSkillMd，双视图同源）+ itemToJson 暴露 template_output。analyze 0 + mcp_tools_test 35 过（工具数 38→42）。
- [2026-10-14] P1 完成：人类只读预览页 TemplatePreviewPage（按 workspace 分组、展开渲染 body_md、无编辑入口、孤儿模板兜底）+ 设置页「模板库」入口 + decisions.md ADR（模板管理权归 AI 有意不对称）+ template_test 5 例。全量 analyze 0 + test 795 全过。
- [2026-10-14] P2 完成：模板应用 = 复刻 llm_summarize 远程任务接缝。template_apply:<id> 进远程集合（isRemoteTaskAction 前缀判定 + pendingTasks 守卫 + claimRemoteTask SQL 三处同步）；TemplateApplyCommand（ui 触发，校验模板/正文后入队）+ handler._templateApply；ReconstructResult 加 templateOutput/templateId + _applyAiResult 写 inbox_items.template_output/_id/_output_anchor（打码+版本锚镜像 summary）；apply_ai_result MCP 透传 template_output/template_id；claim_ai_task 描述补 template_apply；详情页「按模板处理」选模板弹窗 + 待办条通用显示。template_test 加 3 例，全量 798 过、analyze 0。
- [2026-10-14] 真机自动化测试（P2）：新增 integration_test/template_apply_flow_test.dart，独立测试库 goodshare_itest.db 隔离真机数据（不污染 goodshare.db）；CPH2767 真机跑通——详情页「按模板处理」按钮→选模板弹窗→提交入队 template_apply 远程任务（pending、item_id 与 task_action 正确）→状态条显示「处理中」。覆盖人侧 UI 入口；AI 宿主端到端（claim→按 skill 处理→apply_ai_result 回写）由 VM 单测 template_test 覆盖。注：详情页动作按钮行既有 ~1.4px RenderFlex 溢出（非 P2、纯视觉），测试内按非致命过滤，未改动业务代码。
