---
memo: todos
format: v2
---

# 待办列表

## misc
- (功能)[long] iOS 端适配：需 macOS 构建；验证 receive_sharing_intent iOS 行为与前台服务限制（预期「app 前台时 MCP 可用」）
- (功能)[long] 鸿蒙 OHOS 适配：flutter_flutter fork + receive_sharing_intent/flutter_foreground_task 插件 ohos 化
- (功能)[medium] ACTION_PROCESS_TEXT：任意 app 选中文本一键收集（需自定义平台通道）
- (功能)[medium] 标签管理（编辑/筛选）；数据量大后评估 FTS 全文索引替换 LIKE
- (风险)[medium] 国产 ROM 省电策略可能杀前台服务：真机验证华为/小米等存活情况，必要时引导加白名单
- (优化)[low] 自定义 app 图标与启动页（flutter_launcher_icons）
- (文档)[low] release 签名配置文档化（keytool + signingConfig）
