---
dev-loop: memory
format: v1
epic: goodhub-local-plugin
total-merged: 0
last-merge: none
---

# goodhub-local-plugin · goodshare 本地 Binder 插件改造

- [挂载] docs/design/goodhub-local-plugin.md

## 目标
goodshare 由 HTTP MCP server（`:8765/mcp`）改造为 goodhub 本地 Binder 插件：Release 零端口、系统级自动发现、同签名零弹窗、随调随起。评估 SSOT = `docs/design/goodshare-goodhub-local-plugin-eval.md`；goodhub 侧契约 SSOT = `thirdconnect.md`（TC1~TC14）。

## 断点
- [断点] 下一步：goodhub 评估回填已落地（B1 call 5s 超时 / B2 signature 权限 / B3 回显 id / R2 ready≤5s，见 eval §7.1，`flutter build apk --debug` 编译通过）；待双方真机联调——goodhub 同步带 `<uses-permission com.zzh.goodhub.permission.MCP_SERVER>` + 同签名 debug 包，只用短工具 `list_items`/`get_item`，顺带验 R1 WAL 并发与 `force-stop` 随调随起自愈。后续 #2 前台服务解耦 / #3 mcp-blob / #4 _async / #5 sampling 留「能力平移」批次；#6 SDK / #7 网关 / #10 节点卡依赖 goodhub 侧就绪。

## 显式决策
- [2026-10-13] B2 签名权限已提前至 PoC 落地（原计划上线前）：goodhub 侧同步加 `<uses-permission>`，两包必须**同签名同批**出包，否则 bind 报 SecurityException——联调排期强耦合。
- [2026-10-13] R1（双 isolate WAL 并发写）评估为部分成立、PoC 接受：联调期 Binder 路径**读为主**（写工具单并发）；后续按需 `PRAGMA busy_timeout` 或单 isolate actor（eval §7.2）。
