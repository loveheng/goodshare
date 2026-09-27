# MCP 接入指南

> status: stable
> updated: 2026-09-27

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

| 工具 | 参数 | 说明 |
|---|---|---|
| `list_items` | `query?` `type?` `limit?(≤100)` `offset?` | 关键词命中标题/正文/标签，时间倒序分页 |
| `get_item` | `id` | 全文；图片返回 base64 image 内容块（≤4MB），超大文件返回路径 |
| `add_item` | `content` `title?` `tags?[]` | AI 侧写入文本/链接，自动识别纯 URL |

## 安全提示

- 令牌泄露即等同手机收集内容泄露，怀疑泄露立即在 app 内重置（旧令牌即时失效）
- 局域网直连未加 TLS，仅限可信网络；跨网访问建议走 adb reverse 或自建隧道
