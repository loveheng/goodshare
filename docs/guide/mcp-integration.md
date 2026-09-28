---
status: active
updated: 2026-09-28
---

# MCP 接入指南

## 手机端准备

1. 安装 APK 后打开「MCP 服务」页，打开开关（首次会请求通知权限）
2. 记下页面上的 **局域网端点** 与 **访问令牌（X-Api-Key）**

前台通知会常驻显示服务状态；切换后台不影响服务。

## 方式 A：USB + adb reverse（推荐，不依赖网络环境）

```bash
adb reverse tcp:8765 tcp:8765
```

之后桌面访问 `http://127.0.0.1:8765/mcp` 即手机端服务。重新插拔 USB 后需重跑该命令。

## 方式 B：局域网直连

手机与电脑同一 Wi-Fi，直接使用 app 显示的 `http://<手机IP>:8765/mcp`。不通时检查：同一网段、路由器 AP 隔离、手机省电策略杀后台。

## stdio 客户端配置（Claude Desktop / ZCode 等）

仓库自带 `mcp-bridge/stdio-bridge.mjs`（零依赖，Node ≥18）：

```json
{
  "mcpServers": {
    "goodshare": {
      "command": "node",
      "args": ["/home/zzh/app/goodshare/mcp-bridge/stdio-bridge.mjs"],
      "env": {
        "GOODSHARE_URL": "http://127.0.0.1:8765/mcp",
        "GOODSHARE_TOKEN": "<访问令牌>"
      }
    }
  }
}
```

也可命令行传参：`node stdio-bridge.mjs --url <端点> --token <令牌>`。

## 直接用 HTTP 客户端调试

```bash
curl -s http://127.0.0.1:8765/mcp \
  -H 'content-type: application/json' \
  -H 'x-api-key: <访问令牌>' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
```

## 工具一览

所有写/改动作与手机 UI 走同一实现（MCP 把 JSON 反序列化成 `ItemCommand`，交给与 UI 同一个 `ItemActionHandler`），校验语义完全一致。Vault 条目对 MCP 物理不可见——仅可 `set_vault(on=true)` 移入，无法读取或移出。

写工具**返回修改后的最新条目快照**（与 `get_item` 同一形状），后续推理请以返回值而非记忆中的旧值为准；被拒时 `error.data` 带 `{code, hint}`，可据此自我纠正（如 `edit_locked` → 先调 `unlock_edit`）。详见 docs/architecture/human-ai-parity.md。

| 工具 | 参数 | 说明 |
|---|---|---|
| `list_items` | `query?` `type?` `limit?(≤100)` `offset?` | 关键词命中标题/正文/标签，时间倒序分页 |
| `get_item` | `id` | 全文（含人类态/机器态）；图片返回 base64 image 内容块（≤4MB） |
| `add_item` | `content` `title?` `tags?[]` | AI 侧写入文本/链接，自动识别纯 URL；不参与合并模式 |
| `query_machine_data` | `query?` `type?` `limit?` `offset?` | 机器态结构化数组（仅含已有 machine_json 的条目） |
| `get_timeline_context` | `date`（YYYY-MM-DD） | 当日多维上下文；健康/事件随 V3 健康接入填充，当前为空 |
| `update_item` | `id` `patch{title? tldr? tags? human_md? machine_json? item_type?}` `expected_version?` | 编辑；machine_json 须过领域 Schema 校验；合并锁定条目拒绝写入；`expected_version` 为乐观锁（见下） |
| `delete_item` | `id` | 软删除（30 天内用户可恢复），关联 AI 任务一并取消 |
| `set_vault` | `id` `on:true` | 移入保险箱（之后对 MCP 不可见）；移出仅限手机端操作 |
| `reprocess_item` | `id` | 重新触发双态重构（重置处理态并重新入队） |
| `unlock_edit` | `id` | 解除合并条目编辑锁，随后 `update_item` 方可写入 |
| `batch_items` | `commands[]`（1–20 条，形如 `{"op":"update","id":"...","title":"..."}`） | **原子批量**：全部成功才提交，任一条失败整批回滚；可用 op：update/delete/set_vault/reclassify/reprocess/unlock_edit/collect/append_segment/restore；不支持 delete_forever |
| `append_segment` | `id` `text` `source_app?` `expected_version?` | 往合并链末尾追加一段（等价于手机端连续速记自动并链）；仅合并模式条目、末段在 5 分钟窗口内可追加，超窗改用 `add_item` |

**乐观锁（`expected_version`）**：`get_item` / 写工具返回值里的 `version` 即当前版本号。多步规划时把读到的 `version` 原样带回，若期间条目已被用户或他人改动，写入会被拒绝并返回 `version_conflict`（而不是静默覆盖）——此时重新 `get_item` 取最新状态再决策即可。不传则不校验。

## 安全提示

- 令牌泄露即等同手机收集内容泄露，怀疑泄露立即在 app 内重置（旧令牌即时失效）
- 局域网直连未加 TLS，仅限可信网络；跨网访问建议走 adb reverse 或自建隧道
- Vault 条目对 MCP 物理隔离：大模型只能建议「移入」，永远读不到内容，也不能自行移出
