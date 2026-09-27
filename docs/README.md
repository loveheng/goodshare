---
status: active
updated: 2026-09-27
---

# docs/ 结构索引

> 工程文档纯结构索引（域 → 文档 → 一句话定位）。状态以各文档 frontmatter 为唯一事实源，此处不重复。

## product（产品 / 跨域需求）

- [product-requirements.md](product/product-requirements.md) — goodshare 全局 PRD：愿景、已确认架构决策、数据模型、五大模块需求、MCP 接口规范与分期路线图。
- [v2-requirements.md](product/v2-requirements.md) — V2 需求：离线双态 AI 重构（llama_cpp_dart + GBNF 约束解码）、多源健康接入、通用截图解析接口（OCR→LLM 归一各厂商截图）。

## architecture（架构）

- [overview.md](architecture/overview.md) — 架构总览：分层、关键决策（传输/鉴权/保活/桥接）、测试与已知边界。⚠️ 该文档使用非标准 `> status:` 块引用 frontmatter，待归一为 docs-spec。

## guide（接入指南）

- [mcp-integration.md](guide/mcp-integration.md) — MCP 接入指南：手机端准备、USB/局域网连接、stdio 客户端配置、工具一览与安全提示。⚠️ 同上，frontmatter 待归一。
