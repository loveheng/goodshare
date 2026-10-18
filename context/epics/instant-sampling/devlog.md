dev-loop: devlog
format: v1
epic: instant-sampling
---

# instant-sampling devlog

## 2026-10-17 评估→设计→契约回写（无代码变更）

- 评估四轮：用户需求「MCP 服务端调用客户端侧 AI 能力即时出结果（goodshare 套用模型即时呈现）」→ 取证确认 sampling 协议侧 M3 已全线落地（goodhub sampling.dart handler + 配额 + 围栏；goodshare SSE/Binder 双承载；ai_suggest_tags 最小验证）→ 缺口 = 消费工具仅一个 + UI 入口为零
- 路径排除：PC 中转路径（PC→goodhub→goodshare→借 PC 推理→手机转发）三轮论证排除——goodhub 网关 face 一律挂宿主引擎 handler（gateway_controller.dart:277）sampling 到不了 PC；透传有环路（loop_guard 会拦）+ 围栏缺口（不经引擎则无 PII 遮蔽）+ 价值薄弱（PC 直连 goodshare 更短）
- 用户四项拍板：D1 仅即时摘要 / D2 instant 池 60/60min / D3 maxTokens 1024 维持 / D4 采用/忽略卡
- 落地物：① docs/design/instant-ai-sampling.md 设计稿（T1-T5 施工分解）；② ai-app-split.md §3.11 契约增量（消费工具扩族 + pool 字段 + 分池配额）+ 实施状态段；③ goodhub index.md sampling 行备注；④ 本 epic 建立 + CURRENT 绑定
- 写路径取证：ApplyAiResultCommand taskAction=null 走通用分支（summary_md + 打码 + anchor），UI「采用」可安全复用 + expected_version 乐观锁（item_action_handler.dart:1164-1194）
- prompt 口径取证修正（2026-10-17）：原设计稿「与宿主异管线摘要 prompt 同风格对齐」前提不成立——宿主 llm_summarize 实走通用任务 prompt（hybrid_inference.dart:27-41，512 上限、无摘要专项约束）。修正为即时版用专用摘要 prompt（设计稿 §4.1a 全文照录），「产出一致性」目标废止；异管线 prompt 升级（按 task_action 分叉）列二期 goodhub 侧优化
- 接入点边界拍板（2026-10-17 用户）：prompt 与场景行为由调用方（摘要服务）经 sampling params 自带；goodhub host 接入点只定义通用参数和行为（配额/围栏/临时会话/回程），禁止业务名词与场景特判——已写入设计稿 §5.1 施工纪律；推论 = 二期扩场景 goodhub 零改动
- 架构拍板（2026-10-17 用户）：server 侧功能工具正常开发 + 统一代理面（AiSamplingProxy）收口 sampling 发射，与 client 统一 handler 构成多对一架构——已写入设计稿 §4.3；并发四层取证（协议 id 分派/completer 表、配额同步原子、引擎独立 HTTP、会话无共享）= 天然安全无需加锁；前置项 = 端侧接入补并发队列 + per-server 并发上限一期不加
- 防重入三层（2026-10-17 用户追问「同一方法短时间多次」）：UI 单 flight（T2）+ 代理面 in-flight 去重（指纹 = pool+prompt hash，同请求复用 Future，一次推理一次扣费一次配额，T1）+ 配额 60/60min 背线（D2）——已写入设计稿 §4.3
- 去重语义澄清拍板（2026-10-17 用户）：「短时间内不触发第二次」= **single-flight 仅在途合并**，请求完成即出表、下次同指纹 = 全新推理正常扣费；禁结果缓存/TTL/跨请求记忆（再点一次必须拿新结果）——设计稿 §4.3 已按此精确化
- 边界 review 四条拍板（2026-10-17 用户）：P1-1 乐观锁冲突分级（正文指纹 md5 同 summary_anchor 口径；未变=最新 version 自动重试一次，已变=保留预览+复制/重生成，不给强制落库）；P1-2 长文本护栏（取证：sampling 路径零输入护栏、ai_suggest_tags 同样裸奔；proxy 统一 4000 字符硬截断+注记、UI >8000 预检引导后管线、预览截断透明）；P2-3 生命周期（不 cancel，whenComplete 必出表无悬挂；UI 只做 mounted 守卫；离开即弃等待态）；P2-4 预览 transient 明确不暂存 DB/Prefs——设计稿 §4.4 + §4.1a 截断注记 + T1/T2 分解已同步
- 交互形态澄清（2026-10-17 用户问「异步出结果吗」）：UI 纯异步非模态（卡内 inline loading + 按钮禁用，页面其余可交互）；协议 = 挂起 tools/call + SSE 起始帧/心跳帧；「即时」语义 = 相对异管线分钟级后台处理的原地数秒等待（云端 5~15s 预期）。**新增验证点**：宿主退后台（进程存活）时 sampling 回程可达性未经真机验证——已补设计稿 §7 验收第 7 条
- 施工级细节两条拍板（2026-10-17 用户）：① bodyFingerprint 口径——取证发现 md5(humanMd) 已有三份复制（item.dart:228 / item_action_handler.dart:1305 / :1189），T2 将是第四份；拍板抽 `bodyMd5()` 单一出处收编（_applyAiResult 保留 effectiveBody 语义只搬表达式），指纹禁经编辑器/文件/JSON 中转（换行规范化 = 字节漂移）；② 去重指纹 = md5(pool+systemPrompt+userPrompt+maxTokens) 基于**截断/注记后最终 payload**、计算点 = pipeline 末端、非确定性成分禁入指纹——设计稿 §4.3 + P1-1 + T1 分解已同步
- UX/健壮性四条 review（2026-10-17 用户）：① TTFT 两级超时——代理层 30s 首帧超时（防 Doze/Frozen 挂起态傻等 90s；心跳帧不算数；abort 孤儿无害 + 宿主白扣 1 配额可接受）+ 契约 90s 天花板保留；② UI 等待三纪律——骨架 6 行 + AnimatedSize（防 Layout Shift）、主动「转后台处理」文字链接（控制权交还用户、不 cancel 底层）、loading 文案时间轮转（0/3/6s，纯 UI 不假装进度；真实阶段帧 = M2.5-T7 遗留不做）；编辑入口**不置灰**（并发写全集 P1-1 已兜底），补预览卡时效标注「基于 N 秒前正文」——设计稿 §4.3 + §4.2 + T1/T2 分解已同步

## 2026-10-17 T1 落码（goodshare 侧，无真机变更）

- `lib/mcp/ai_proxy.dart` 新：AiSamplingProxy 收口 sampling 发射——single-flight 去重（指纹=md5(system+user+pool+maxTokens)，基于截断后末端 payload；在途期间同指纹复用 Future，whenComplete 出表）+ 4000 字符硬截断（注记前置「（原文超长，以下仅为前 4000 字）」）+ TTFT 30s 超时（挂在 `sampling()` future；协议层无中间帧可见性，等价首帧；超时 abort→sampling_failed、底层成孤儿静默丢弃、无 unhandled）+ 降级映射（McpRpcError -32000→quota_exceeded / 其他→failed）；SamplingReply 四态（ok/quota/failed）。
- `lib/mcp/tools.dart`：`ai_summarize_now` 工具（§4.1 契约 + §4.1a prompt 照录，经 `_samplingProxy.run(pool:'instant')` 发射，只读不落库，回传 status+summary_md+version）；`_kReadOnlyHints` 登记；新增 schema；模块级 `_kInstantSummarySystem` + `_instantSummaryUser` + `_samplingProxy` 单例。
- `lib/mcp/mcp_server.dart`：`_kBinderAsyncTools` 增 `ai_summarize_now`（Binder `_async` 终帧不超时）。
- `lib/models/item.dart`：新增 `bodyMd5()` 单一出处 + isSummaryStale/isTemplateOutputStale 改用；`lib/action/item_action_handler.dart` 三处锚写入改用 `bodyMd5`（删 crypto 冗余 import）。
- 测试：test/ai_proxy_test.dart（8：ok/quota/failed/截断/single-flight 同指纹×1发射/异指纹×2/TTFT/bodyMd5 等价）+ test/mcp_server_test.dart（+4：流内 ok+version/非流 unavailable/空正文 no_content/只读不变）。analyze 0 / 全量 30 绿。
- 遗留：① `ai_suggest_tags` 迁代理面等价重构暂缓（其 pool=默认池，迁入会改 goodhub 配额 key 派生，属行为变更，非阻塞 T1 核心）；② TTFT 真·首帧（非回程）需帧可见性 plumbing，现行协议等价实现已满足行为意图；③ T3 goodhub 配额分池为跨仓改动，本工作树无 goodhub 仓，待跨仓实施。

## 2026-10-17 goodhub 半边就绪 · T5 启动（跨仓对帐）

- **跨仓状态**：goodhub 侧 T3（配额分池 `pool` 字段 + `caps` 覆盖表 instant 60/60min + 单测）+ T4 goodhub 半边（index.md sampling 行补 pool 分池备注）经用户确认就绪。至此 T1/T2/T3/T4 全数完成，仅剩 T5 验收。
- **T5 本机前置自检（2026-10-17）**：① `flutter analyze` → No issues found（0 issue，交付线达标）；② `flutter test test/mcp_server_test.dart --timeout 60s` → All tests passed（含 instant 族钉子 +18 流内 ok+version / +19 非流 unavailable / +20 空正文 no_content / +21 只读不变）。T1/T2 落地无回归，goodshare 侧就绪。
- **T5 剩余项（依赖物理设备，本机止步）**：真机联调（含 Binder 路径 `_async` 终帧回注无 ANR）+ 宿主退后台回程可达性（设计稿 §7 第7条）+ 双仓联调四态降级/version 回传端到端验证。设计稿 T3/T4/T5 状态行已同步（T3/T4 goodhub ✅、T5 🟡 进行中）。
- **全量测试回归修正（2026-10-17，T5 前置）**：`flutter test --timeout 60s` 全集初跑暴露 **2 条 instant 相关陈旧期望**——T1 新增 `ai_summarize_now` 后 `mcp_tools_test.dart` 仍写死「清单 42 个」「readOnlyHint 只读清单不含 ai_summarize_now」。已修正（`test/mcp_tools_test.dart`：期望 42→43、readOnlySeven 增 `ai_summarize_now`，注释补 instant-ai-sampling T1 出处）。修正后全集剩 **1 条非相关 flaky**：`long_text_phase_test.dart`「Phase 3 Isolate 异步解析 RichTextView 回填渲染」在全集并行负载下偶挂、单独复跑 11/11 全过——属长文本 epic 既有时序 flaky（isolate+FakeAsync 调度竞争），与 instant-ai-sampling 无关、不在本 epic 范围，不阻塞 T5，建议另行挂 long-text epic 跟踪。生产侧 `ai_summarize_now` 的 `_kReadOnlyHints` 登记 T1 已正确，无需改码。
- **跨仓对帐注记**：goodhub 侧 `pool` 口径须与 goodshare `ai-app-split.md` §3.11 完全一致——默认池 20/60min、instant 池 60/60min、内存态不落盘、Tier 1 私有扩展字段；§5.1 红线（host 禁业务名词、pool 不承载场景语义）须守住，二期扩即时标签/模板时 goodhub 零改。
