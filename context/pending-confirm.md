---
confirm: cleared
format: v1
---

# goodhub-local-plugin · 决策点台账

> 登记于 PoC 起手前；2026-10-13 全部确认（用户选推荐项），已落 memory.md 断点 + devlog。

- [x] [2026-10-13] DP1 Binder Service 触达 Dart：选 headless FlutterEngine（真·随调随起，~+0.5~1 天）→ 已落地 McpBinderService + lib/mcp_binder_entrypoint.dart
- [x] [2026-10-13] DP2 HTTP 回退：保留 HTTP server(:8765) 作可关闭回退（Binder 为主、HTTP 为辅并行）→ McpController 未改动，Manifest 仅新增 Service
- [x] [2026-10-13] DP3 PoC 范围：仅 #1（Binder Service + AIDL + MethodChannel + Manifest），不含 #2~#5 → 已实现 #1
