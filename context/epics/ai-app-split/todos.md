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
