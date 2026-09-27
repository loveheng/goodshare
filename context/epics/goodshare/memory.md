---
dev-loop: memory
format: v1
epic: goodshare
total-merged: 1
last-merge: 2026-09-27
---

# goodshare · Android 分享收集器 + 内嵌 MCP 服务

## 目标
- 手机使用过程中，通过系统分享菜单把「好东西」（文本 / 链接 / 图片 / 视频 / 文件）一键收集进 app
- app 内可作为 MCP 服务（Streamable HTTP）运行，供桌面 AI 客户端（Claude Desktop / ZCode 等）检索与读取收集内容
- 链路：采集（分享菜单）→ 存储（sqflite）→ 浏览检索（Flutter UI）→ MCP 对外（tools）

## 技术决策（已定）
- [2026-09-27] 技术栈：Flutter (Dart) 一套代码——Android 首发，iOS 官方支持，鸿蒙走华为社区 OHOS 适配（Gitee flutter_flutter）；包名 com.zzh.goodshare，应用名「拾贝」（working title，可改）。动因：用户明确「以后移植 iOS + 鸿蒙」，三端选型经用户确认（2026-09-27）
- [2026-09-27] 存储：sqflite 单表 items + path_provider；图片/视频/文件复制进 app 私有目录（documents/shares/），不依赖源 app 的 content URI（防撤销/失效）
- [2026-09-27] MCP 传输：dart:io HttpServer 内嵌监听 0.0.0.0:8765，手写 Streamable HTTP + JSON-RPC 2.0（initialize / tools/list / tools/call / ping）；支持协议版本 2025-06-18 与 2025-03-26；GET/DELETE /mcp 返回 405（v1 无服务端主动推送）
- [2026-09-27] MCP 工具集 v1：`list_items`（分页/类型过滤/关键词）、`get_item`（全文；图片返回 base64 image 内容块，超大文件只给路径）、`add_item`（AI 侧写入文本/链接）
- [2026-09-27] 关键插件：receive_sharing_intent（分享接收）、flutter_foreground_task（前台保活，若接入受阻两轮即降级为「app 存活期可用」并记待办）、shared_preferences（设置/token）、share_plus（再分享）
- [2026-09-27] 服务防护：简单 token（X-Api-Key 头，默认开启、安装时随机生成）用于 LAN 暴露场景
- [2026-09-27] 桌面接入双通道：USB 用 `adb reverse tcp:8765 tcp:8765`；Wi-Fi 用手机局域网 IP 直连；仓库自带 Node stdio↔HTTP 桥（`mcp-bridge/stdio-bridge.mjs`）供 stdio 型 MCP 客户端使用
- [2026-09-27] 弃用项：Kotlin 原生（Compose/Room/Ktor）方案整体作废；ACTION_PROCESS_TEXT 采集移入后续待办（Flutter 端需插件/自定义通道）

## 进度
- [2026-09-27] dev-init 接入完成：git 仓库 + context/ 记忆体系 + 白名单骨架 + 项目池（首次 scaffold 因 cwd 漂移落到了 workspace 根，已整体迁回——教训：Bash 一律显式 cd）
- [2026-09-27] 环境就绪：Android SDK（platform-36/37.0 + build-tools 36，~/android-sdk）+ Flutter 3.47.5 stable（~/flutter）；工程最终落位 ~/app/goodshare（用户指定，从 ZCode 默认工作区迁入）
- [2026-09-27] v1 代码全量落地并四项验证通过：analyze 0 issue / test 6/6 / bridge e2e 5/5 / assembleDebug ✓（app-debug.apk 165MB，在 build/app/outputs/flutter-apk/）。构建踩坑：receive_sharing_intent 1.9.0 要求 compileSdk ≥37（高于 flutter 默认 36，已提为 37）；pub 下载偶发停滞（清 _temp 重跑可解）
- [2026-09-27] 真机验证（分享接收/前台服务存活/MCP 实连）未做——本机无设备

## 断点
- [断点] 下一步：真机侧载 app-debug.apk 验证分享接收/前台服务/MCP 实连；随后按 todos.md 推进（PROCESS_TEXT、标签管理、iOS/鸿蒙）
