# 拾贝 · goodshare

**日常分享收集器 + 个人 MCP 服务**（Flutter 一套代码：Android 首发，预留 iOS / 鸿蒙移植）。

在任意 app 里看到好东西，点「分享 → 拾贝」即可收集；app 内嵌 **Streamable HTTP MCP 服务**，桌面 AI 客户端（Claude Desktop / ZCode 等）可以直接检索、读取、写入你的收集。

## 功能

- **一键收集**：接收系统分享（文本 / 链接 / 图片 / 视频 / 文件），自动识别纯链接与「标题+链接」；附件复制进 app 私有目录，不怕源 app 撤销
- **浏览检索**：列表按时间倒序，关键词搜索命中标题/正文/标签；详情页可复制、再分享、删除
- **MCP 服务**：内嵌 HTTP 服务（默认 `0.0.0.0:8765`，端点 `/mcp`），前台服务保活；X-Api-Key 令牌防护
  - 工具：`list_items`（搜索/过滤/分页）、`get_item`（全文+图片内容块）、`add_item`（AI 代写入）
- **桌面接入**：USB（`adb reverse`）或局域网直连；stdio 型客户端用仓库自带桥 `mcp-bridge/stdio-bridge.mjs`

## 快速开始（桌面连手机）

1. 手机安装 APK（见下），打开 app →「MCP 服务」→ 打开开关，记下 **访问令牌**
2. 电脑执行（USB 方式）：

   ```bash
   adb reverse tcp:8765 tcp:8765
   ```

3. MCP 客户端配置（Claude Desktop / ZCode 等）：

   ```json
   {
     "mcpServers": {
       "goodshare": {
         "command": "node",
         "args": ["<仓库路径>/mcp-bridge/stdio-bridge.mjs"],
         "env": {
           "GOODSHARE_URL": "http://127.0.0.1:8765/mcp",
           "GOODSHARE_TOKEN": "<app 内显示的访问令牌>"
         }
       }
     }
   }
   ```

   之后就可以问 AI：「我最近收集了什么」「找一下我存过的 xx」「把这段也存进去」。

> 局域网方式：手机与电脑同一 Wi-Fi，直连 app 内显示的局域网端点即可，无需 adb。
> 注意：iOS / 鸿蒙端 MCP 常驻受系统后台策略限制（iOS app 进后台即挂起），Android 前台服务是三端中最可靠的形态。

## 构建与自检

```bash
flutter pub get          # 依赖
flutter analyze          # 静态检查
flutter test             # MCP 协议 / 文本归一 单测
flutter build apk --debug  # 构建（release 需自行配置签名）
node mcp-bridge/e2e-check.mjs  # 桥接端到端自检
```

环境要求：Flutter stable 3.47+、JDK 17+、Android SDK（platform/build-tools）。

## 目录

| 路径 | 内容 |
|---|---|
| `lib/data/` | sqflite 存储与 Repository（UI/MCP 共用入口） |
| `lib/mcp/` | JSON-RPC、工具集、Streamable HTTP 服务 |
| `lib/share/` | 系统分享接收与归一 |
| `lib/service/` | MCP 总控（token/开关/前台保活） |
| `lib/pages/` | 列表页与 MCP 设置页 |
| `mcp-bridge/` | 桌面 stdio↔HTTP 桥接器（含 e2e 自检） |
| `context/` | AI 协作记忆体系（dev-loop），`.agents/skills/` 为项目事实源 |

更多设计说明见 [docs/architecture/overview.md](docs/architecture/overview.md)、接入细节见 [docs/guide/mcp-integration.md](docs/guide/mcp-integration.md)。
