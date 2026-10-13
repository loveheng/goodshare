---
dev-loop: devlog
format: v1
epic: goodhub-local-plugin
total-merged: 0
last-merge: none
---

（追加区：≥5 条自动归并进 memory.md）

- [2026-10-13] [变更]: goodshare→goodhub 本地 Binder 插件 PoC（改造清单 #1）落地：新增 AIDL(IMcpChannel/IMcpCallback, com.zzh.goodhub.mcp)、McpBinderService(headless FlutterEngine + IMcpChannel.Stub)、Dart 后台 entrypoint(lib/mcp_binder_entrypoint.dart → McpServer.handleJsonRpc)、McpServer.handleJsonRpc/answerReverse Binder 入口；AndroidManifest 声明 exported Service + action + SERVER_ID=goodshare/SERVER_TITLE=GoodShare + <queries>；HTTP server(:8765) 保留作回退（DP2）
- [2026-10-13] [验证]: flutter analyze → No issues found；flutter build apk --debug → ✓ Built app-debug.apk（AIDL+Kotlin+Dart 全编译通过）；goodhub 真机联调待排（需 goodhub 侧构建+设备）
- [2026-10-13] [决策]: DP1=headless FlutterEngine（随调随起）、DP2=保留 HTTP 回退、DP3=PoC 仅 #1（见 pending-confirm.md，已确认）
- [2026-10-13] [变更]: goodhub 侧评估回填落地 B1/B2/B3/R2（见 eval §7）：call 加 per-call 5s 超时（TimeoutException→-32000，避免 Dart 不回挂死 Binder 线程）；errorJson 改 org.json.JSONObject 构造并经 extractId 回显请求 id；ready 等待 10s→5s 对齐 goodhub 冷启；Manifest 加 `<permission com.zzh.goodhub.permission.MCP_SERVER protectionLevel="signature">` + Service `android:permission`
- [2026-10-13] [验证]: flutter analyze → No issues found；flutter build apk --debug → ✓ Built app-debug.apk
- [2026-10-13] [决策]: R1（双 isolate WAL 并发写）评估为部分成立、PoC 接受——联调期 Binder 路径读为主，后续按需 busy_timeout/单 actor（eval §7.2）；R3 确认范围极小（仅 ai_suggest_tags）；R4 确认破坏性
- [2026-10-13] [变更]: R1 缓解落地（goodhub 交接文档要求）：`db.dart` onOpen 加 `PRAGMA busy_timeout=5000`（rawQuery，主/binder 双连接同时生效）；`main.dart` import `mcp_binder_entrypoint.dart`（否则该库不进 app kernel，release 下 `mcpBinderMain` 不可达——已标 @pragma vm:entry-point 防 tree-shake，import 加 `// ignore: unused_import`）；新增 `test/wal_two_conn_test.dart`（两 Isolate 双原生连接并发写实证）
- [2026-10-13] [验证]: `flutter test test/wal_two_conn_test.dart` → All tests passed：默认态双连接并发写确实触发 SQLITE_BUSY（R1 风险**实证**成立），busy_timeout=5000 + 单事务批量写后 600 行全落库无 BUSY（缓解**实证**有效）。另 flutter analyze → No issues found；flutter build apk --debug → ✓ Built
- [2026-10-13] [lint]: WAL 测试收口 0 问题——`sqlite3: ^3.5.2` 补入 dev_dependencies（原为间接依赖）、`dispose()`→`close()`、for 体补花括号、`// ignore_for_file: avoid_print`
