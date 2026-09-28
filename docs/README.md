---
status: active
updated: 2026-09-28
---

# docs/ 结构索引

> 工程文档纯结构索引（域 → 文档 → 一句话定位）。状态以各文档 frontmatter 为唯一事实源，此处不重复。

## product（产品 / 跨域需求）

- [product-requirements.md](product/product-requirements.md) — goodshare 全局 PRD：愿景、已确认架构决策、数据模型、五大模块需求、MCP 接口规范与分期路线图。
- [v2-requirements.md](product/v2-requirements.md) — V2 需求：离线双态 AI 重构（调用系统自带模型，零下载）+ 通用截图解析接口（OCR→LLM 归一截图）；多源健康接入已推迟 V3。

## architecture（架构）

- [overview.md](architecture/overview.md) — 架构总览：分层、关键决策（传输/鉴权/保活/桥接）、测试与已知边界。⚠️ 该文档使用非标准 `> status:` 块引用 frontmatter，待归一为 docs-spec。
- [human-ai-parity.md](architecture/human-ai-parity.md) — Human-AI 对称性（无头架构）：命令模式统一入参、防呆下沉、写后回状态、原子批量；主体×命令权限矩阵与试金石。

## guide（接入指南）

- [mcp-integration.md](guide/mcp-integration.md) — MCP 接入指南：手机端准备、USB/局域网连接、stdio 客户端配置、工具一览与安全提示。
- [self-update.md](guide/self-update.md) — 自更新手册：更新源配置、清单/下载/校验/安装流程与 Shorebird 受阻记录。⚠️ 同上，frontmatter 待归一。

## design（UI 设计规范）

- [ui-spec.md](design/ui-spec.md) — UI 设计规范：Material You/M3 视觉系统、5 底 tab + FAB 导航、页面清单、设置树、组件库与双态呈现；配套约束见项目 skill `goodshare-ui`。
- [asr-subtitle.md](design/asr-subtitle.md) — 音频转写与字幕生成设计：VAD 分段取时间戳的可选下载资源 `silero-vad-v5`、文本与 SRT/VTT 双产物、无 VAD 时降级为纯文本的门控。
