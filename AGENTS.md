# AGENTS.md（跨 IDE 兜底）

本仓库的 AI 协作体系在 `.agents/skills/`（随仓库版本化），**按需读取对应 SKILL.md**，不要凭记忆猜项目约定：

- **工作流事实源（构建/测试/运行命令唯一出处）**：`.agents/skills/goodshare-workflow/SKILL.md`
- **功能落点索引（改前先定位）**：`.agents/skills/goodshare-index/SKILL.md`
- **记忆与日志体系（dev-loop）**：`context/`——会话开始先读 `context/CURRENT`，再只读对应 epic 的 `memory.md` 恢复上下文；代码变更须按协议追加 devlog
- **脚本工具箱（agent-toolbox）**：全局池 `~/.agents/toolbox/`，项目池 `scripts/agent-tools/`

冲突裁决链：`context/epics/<epic>/memory.md` 显式决策 ＞ 项目 skill ＞ 通用规约（详见全局 dev-loop skill）。

项目一句话：**拾贝（goodshare）**——Flutter 分享收集器（Android 首发，预留 iOS/鸿蒙），内嵌 Streamable HTTP MCP 服务，桌面 AI 客户端经 `mcp-bridge/stdio-bridge.mjs` 或直连读取收集内容。
