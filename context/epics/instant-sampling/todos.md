---
memo: todos
format: v3
epic: instant-sampling
---

# instant-sampling · 域内待办
- [x] [2026-10-17] (功能)(层:L3)(重:中) **T1** `AiSamplingProxy` 代理面（`lib/mcp/ai_proxy.dart` 新）：single-flight 去重（指纹=md5(pool+sys+user+maxTokens)，基于截断后末端 payload）+ 4000 字符硬截断（注记「原文超长，以下仅为前 4000 字」）+ **TTFT 30s 超时**（挂在 `sampling()` future 上→sampling_failed，孤儿请求静默丢弃；协议层无中间帧可见性，等价首帧，§4.3 已记）+ 降级映射（sampling==null→unavailable / McpRpcError -32000→quota_exceeded / 其他→failed）；`ai_summarize_now` 工具（§4.1 契约 + §4.1a prompt 照录，经代理发射，只读不落库，回传 status+summary_md+version）+ `_kBinderAsyncTools` 登记 + `bodyMd5()` 单一出处收编（P1-1，替代 item.dart:228 / item_action_handler.dart:1305/1189/1316 三处复制）+ 契约钉子（四态降级/只读不变/截断注记/去重两次调用各发射一次/TTFT abort/bodyMd5 等价）。落点：ai_proxy.dart + tools.dart + mcp_server.dart + item.dart + item_action_handler.dart + test/ai_proxy_test.dart(8) + test/mcp_server_test.dart(+4)。**完成 2026-10-17**：analyze 0 / 全量 30 绿（代理单测 8 + MCP 契约 4）。`ai_suggest_tags` 迁代理面等价重构**暂缓**（其 pool 语义为默认池，迁入代理面会改 goodhub 配额 key 派生，属行为变更，非阻塞 T1 核心）(src: instant-ai-sampling.md §4.1/§4.3/§4.4/§8 T1)
- [x] [2026-10-17] (功能)(层:L3)(重:中) **T2** UI 即时入口与交互（`item_detail_page.dart` + 预览小组件按行数纪律拆）：摘要卡「即时生成」动作（闪电图标+tooltip「需 AI 宿主 App 在线」）+ inline loading（骨架 6 行 + AnimatedSize + 文案轮转 0/3/6s）+ 主动「转后台处理」文字链接（触发 SummarizeCommand 入队、不 cancel 底层）+ 编辑不置灰 + 预览卡（虚线边「即时预览·未保存」+ 时效标注「基于 N 秒前正文」+ 截断标注）+ 采用（ApplyAiResultCommand expected_version，成功转正/version_conflict→P1-1 分级：正文未变自动重试一次、已变保留预览+复制/重生成、不强制落库）+ 忽略（清预览无写入）+ 降级转入队（sampling_unavailable/failed→toast+入队按钮；quota_exceeded→retry hint）+ mounted 守卫 + 长文 >8000 预检置灰 + 预览 transient（P2-3/P2-4，不暂存 DB/Prefs）。落点：lib/pages/item_detail_page.dart (src: instant-ai-sampling.md §4.2/§4.4/§8 T2)
- [x] [2026-10-17] (功能)(层:L1)(重:轻) **T3** goodhub 配额分池：`samplingRequestHandler` 读 params 扩展字段 `pool`（缺省=默认池，key 派生 `$serverKey:$pool`）+ `SamplingQuota` 增 `caps` 覆盖表（默认 20 不变，instant 显式 60）+ 三处挂载点零改动继承 + 单测钉两池独立计数（instant 60/60min、默认 20/60min）。落点：goodhub lib/mcp/sampling.dart + test/mcp/sampling_test.dart (src: instant-ai-sampling.md §5/§8 T3)
- [x] [2026-10-17] (文档)(层:L1)(重:轻) **T4** 契约回写（随 T1/T3 同轮）：goodshare `docs/design/ai-app-split.md` §3.11 消费工具扩族（ai_summarize_now 契约 + pool 字段约定 + 配额分池口径）+ goodhub `docs/project/index.md` sampling 行备注补「pool 分池（instant 60/60min）」 (src: instant-ai-sampling.md §6/§8 T4)
- [~] [2026-10-17] (验收)(层:L2)(重:中) **T5** 验收收尾（进行中：goodshare 侧前置自检绿，真机联调待物理设备+goodhub 联调）：双仓 `flutter analyze` 0 issue + 全量测试绿 + 真机联调（含 Binder 路径：_async 终帧回注无 ANR；宿主退后台回程可达性 §7 第7条）+ 四态降级/只读不变/version 回传契约钉子齐绿。落点：— (src: instant-ai-sampling.md §7/§8 T5)

> 顺序纪律：T3 与 T1/T2 并行（接口约定=`pool` 字段先行对齐）；T4 随 T1/T3 同轮；T5 收尾。下一步=**T1**（memory.md 断点）。
