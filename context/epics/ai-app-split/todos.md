---
memo: todos
format: v3
epic: ai-app-split
---

# ai-app-split · 域内待办
- [ ] [2026-10-10] (优化)(候)(层:L1)(重:轻) 候选：llm_tags 改接 ML Kit 实体提取（analyze_text 同族）保留 goodshare 本地打标——语义变更（LLM 关键词→ML Kit 实体），需单独设计拍板 (src: ai)
- [x] [2026-10-10] (功能)(层:L2)(重:重) M2 剥离：摘 LiteRT 全套（gradle/LlmBridge.kt/proguard/lib/ai/llm*.dart/设置页模型区）+ 占位守卫 + UI 双轨 → 已落地 2026-10-14（本地引擎拆除、任务契约保留，analyze 0 + test 790 全过；备份分支 keep/on-device-llm） (src: ai)
- [x] [2026-10-10] (功能)(层:L1) M1 goodshare 侧三 MCP 工具（claim/touch/apply + 测试组）→ 已落地归档 done.md 2026-10-13（d34dda5；M2.5/M3 契约扩展同批归档，详见 ai-app-split memory 进度）
- [x] [2026-10-18] (功能)(层:L2)(重:中) M4 消费闭环·goodshare 侧四项：`<queries>` 补 `<package com.zzh.goodhub/>` + 形态 B 等待徽标 + `goodshare/host_launch` 一键唤起 + `task_queued` 通知 → 已落地 2026-10-18（analyze 0 + test 830 全过；真机验收待设备） (src: ai)
- [x] [2026-10-18] (功能)(层:L1)(重:中) `task_queued` **跨 isolate 通知桥**（UI 主 isolate → 原生信号跳板 `McpCallbackHub` → goodhub `IMcpCallback`）：**坚决不认领现状**——goodhub 是 Binder-only，不补桥则「在线毫秒级即时消费」在移动端完全失效，用户每次都得看 10s 徽标再手点跳转去触发 catch-up，等于把全自动异步流退化成手工搬运、§3.12 的 `task_queued` 也会变成只对桌面有效的死接缝。已落地 2026-10-18（`compileReleaseKotlin` BUILD SUCCESSFUL + analyze 0 + test 830；详见 devlog） (src: ai)
- [ ] [2026-11-08] (功能)(候)(层:L2)(重:中) 端侧路径「宿主离线」状态记录与补发：`complete()` 环境态失败当前**即丢**（OnDeviceHostUnavailable → 失败注记，无本地登记、宿主上线不自动补发，重试=页面内人工按钮）；细分环境态不可辨——未安装 / 已装未启动 / 已启动未绑定（freezer/竞态）UI 全收敛为「宿主未连入」同一文案。方向：失败登记（复用 OnDeviceTaskRecord 表扩状态）+ 宿主可达性探测（queries 包可见性 + bind 态）+ 可辨识文案与对应出口（未安装→引导安装；未启动→一键唤起复用 host_launch） (src: 2026-11-08 双向状态统计)
- [ ] [2026-11-08] (功能)(候)(层:L2)(重:轻) 云端任务链路「宿主长期不在线」无终态：DB pending 无限悬挂（等待徽标 10s 后永久停留），无过期/用户取消出口；对比端侧路径已有 24h 本地过期清账 (src: 2026-11-08 双向状态统计)
- [ ] [2026-11-08] (功能)(候)(层:L3)(重:轻) (proj: goodhub) 宿主侧 pendingDelivery 积压无清账：消费端不取则条目永久保留（仅 512 行滚动截断兜底），无积压告警/对账事件；宿主对消费端在线性无结构化状态出口（仅日志） (src: 2026-11-08 双向状态统计)
- [ ] [2026-11-08] (工具)(候)(层:L2)(重:中) W6-a 联调自动化六缺口：① /debug/state 无端侧登记表快照（goodshare）+ 任务池无结构化查询端点（goodhub，现只有 pool-dump 日志）；② ai-e2e 无 on-device 用例（现有 summary/tags 仅覆盖 M4 云端链路，验收 5/6 全手工 CLI）；③ 无 drain 调试动作（消费触发只能借聊天 Run，goodhub 侧 simulate_deferred/purge 有而 drain 无）；④ freezer 解冻/保前台无工具化手段；⑤ 双 App 同窗口联采缺失（goodshare capture 转发 goodhub 统一入口但默认单 App，跨仓对账靠手工 grep 时间戳）；⑥ 宿主离线态不可注入（S1-S3 场景测试需真实卸载/停止 goodhub） (src: 2026-11-08 验收 5/6 联调实证)
- [x] [2026-11-08] (缺陷)(层:L2)(重:中) (proj: goodhub) **on-device executor 空产出异常（新 e2e 设施首捕）——诊断定音 + 缓解层落地，e2e 门保持红跟踪**：litertlm 0.16.0（NPU·Gemma3-1B）SDK 层间歇性零产出/异常（同 epoch 同内容数秒内 executor 恒空 700ms prefill 零 token / debug 路径 97 字成功相邻发生，同 prompt 相邻两次调用一次异常一次正常）——调用侧变量全排除（载荷指纹/prompt 对账/装载窗/后端/采样/requestId/收尾-cancel），归 SDK 内部 Conversation 时序缺陷，**修复候选 = 升级 AAR 0.16.0→0.18.1（R4 待用户拍板）**。缓解层已落地（completeInterruptible 空产出单次重试 + onCancel 完成态守卫 + traceId 唯一化 + 载荷指纹诊断）；e2e --case ondevice 机制断言全通、保持红作回归门 **方案求索已挂 goodhub context/epics/misc/todos.md 2026-11-08 条（SSOT，含三方向与验收口径）**；（src: 2026-11-08 修复授权轮；**2026-11-08 续：用户切换 Qwen3.5-2B（llama_cpp→GenieSession 栈，262K ctx）后 e2e 3/3 全绿**——缺陷归属收窄 = Gemma3-1B × litertlm 0.16.0 NPU 栈特有，Qwen/llama_cpp 栈无此现象；缓解层保留，Gemma3 档恢复使用前需升 AAR；**会话对照轮补强：聊天持久会话 5/5 正常 vs 原语一次性会话 4/4 空（同 epoch 同模型），但沉降闸/延后关闭两轮生命周期修复实验均证伪——缺陷深于会话生命周期（内容敏感非确定：同族内容输出 0/4/97B 乱跳），终态归 SDK 内部，宿主无可修缝位**）
