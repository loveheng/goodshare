---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 11
last-merge: 2026-10-09
---

## 进度（追加 11）

<!-- 2026-10-09 归并：20 条已提炼进 memory.md（追加 11），此处归零重开 -->
- [2026-10-15] 发布 v1.3.0(8068) 到 R2 自更新源（https://r2.oklhj.eu.org/updates/goodshare，sha256 5176499… 验证一致）。踩坑两连：①release 编译报 IntegrationTestPlugin 包不存在——f0d7f96 引入 integration_test dev 依赖后首现，非 release 上下文（pub get/analyze）把 dev 插件写进共享 src/main GeneratedPluginRegistrant，重跑 release 构建重新生成干净 registrant 即过；②沙箱内 node fetch 直连 Cloudflare 恒定 ETIMEDOUT（curl 可通），scripts/upload-r2.mjs 传输层改「curl 优先 + fetch 回退」（签名逻辑不动）。
- [2026-10-17] T2 即时摘要 UI 落地（instant-ai-sampling T2，app 侧）。详情页摘要卡操作行新增闪电图标「即时摘要」入口（`sectionActions` 加 onInstant），复用既有 SummarizeCommand 异步管线（**非流式**——按当日拍板 A：真·采样流式路径等 goodhub Binder 接好再做）。三态：①inline 骨架加载（6 行 + AnimatedSize + 文案轮转 0/3/6s + 「转后台处理」链接跳 TaskQueuePage）；②预览卡（RichTextView + 生成于 HH:mm 时效标注 + 采用/忽略）；③失败/无变化降级（转后台处理 + 重试）。「忽略」回滚经新增 UpdateItemCommand.summaryMd/summaryAnchor 通道（_update 套打码 + 重算版本锚，与 apply_ai_result 同口径）。analyze 0 issue，action_handler_test 44 全过。T3/T4 的 goodhub 半边与 T5 验收跨仓（无 goodhub 仓），待就位。
