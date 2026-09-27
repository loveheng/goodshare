# 架构总览

> status: stable
> updated: 2026-09-27

拾贝是一个 Flutter 单模块应用：**系统分享 → 私有存储 → 浏览检索 → MCP 对外**。Android 首发；iOS/鸿蒙迁移时本层结构可整体保留，仅平台插件层需按端适配。

## 分层

```
分享事件（ACTION_SEND / SEND_MULTIPLE）
        │
   lib/share/share_intake.dart        归一化：文本/链接判定、附件复制到私有目录
        │
   lib/data/repository.dart           Repository（ChangeNotifier，UI 与 MCP 唯一入口）
        │
   lib/data/db.dart                   sqflite 单表 items（标签/文件列表以逗号、换行序列化）
        │
   ┌──────────────┴──────────────┐
lib/pages/（列表/详情/MCP 设置页）   lib/mcp/mcp_server.dart（Streamable HTTP）
                                     ├─ jsonrpc.dart   JSON-RPC 2.0 + MCP 版本协商
                                     └─ tools.dart     list_items / get_item / add_item
lib/service/mcp_controller.dart     总控：token 持久化、前台服务（dataSync）保活、开关
```

## 关键决策

- **附件落盘**：分享进来的 content URI 是临时的，收到即复制进 `documents/shares/`，DB 只存本地路径。删除条目时同步清理文件。
- **MCP 传输**：`dart:io HttpServer` 手写 Streamable HTTP（POST `/mcp`，application/json 单响应；通知返回 202；GET/DELETE 405；batch 一律 400——2025-06-18 已移除）。v1 无会话 id、无 SSE 长连接（规范允许 MAY），换取无状态简单性。支持协议版本 2025-06-18 / 2025-03-26 / 2024-11-05。
- **鉴权**：单令牌 `X-Api-Key`（安装时随机生成，可在 app 内重置）。OAuth 过重，v1 不做；LAN 暴露场景的最低防护。
- **保活**：`flutter_foreground_task`（dataSync）。**targetSdk 固定 34**——targetSdk 35+ 的 dataSync 前台服务有 6h/24h 系统限额，与 MCP 常驻冲突（本 app 侧载分发，无商店硬约束）。开机自启放弃（Android 15 限制 BOOT_COMPLETED 拉起 dataSync 服务）。
- **桥接器**：stdio 型桌面客户端无法直连 HTTP，`mcp-bridge/stdio-bridge.mjs` 做 stdin/stdout ↔ HTTP 转发（含 SSE 解包、Mcp-Session-Id 回传、token 注入），零依赖纯 Node ≥18。

## 测试

- `test/mcp_server_test.dart`：真 HTTP 起服（端口 0）验证握手/通知/错误码/工具闭环/鉴权；VM 下用 `sqflite_common_ffi` 工厂
- `mcp-bridge/e2e-check.mjs`：mock 上游 + 真桥接进程的端到端自检

## 已知边界（后续迭代）

- v1 不做标签编辑、归档、FTS 全文索引（LIKE 检索在个人数据规模够用）
- 图片 base64 内联上限 4MB，超大文件只返回路径
- 鸿蒙端：需 flutter_flutter fork + 插件 ohos 化（receive_sharing_intent / flutter_foreground_task 均需社区版或自写）
