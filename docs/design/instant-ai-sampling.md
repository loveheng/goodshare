---
status: active
updated: 2026-10-17
---

# 即时 AI 摘要 · sampling 消费产品化一期

> goodshare 侧消费工具 + UI 入口设计。协议侧（sampling 反向推理）已于 M3 全线落地并真机验证（ai-app-split.md §3.11），本文只装「消费面产品化」增量，不重复协议论证。
> 跨仓改动（goodhub 配额分池）见 §5；接缝契约改动同轮回写 ai-app-split.md §3.11。

## 1. 背景与目标

M3 落地了 sampling 反向推理的最小验证（`ai_suggest_tags`：对话中即时拿标签建议，只读不落库）。本期把它产品化为**详情页即时摘要**：用户在 goodshare 点一下，数秒内拿到宿主 LLM 的摘要预览，确认后一键落库——不再只能「入队 → 打开宿主 App → 等后台轮询处理」。

目标用户场景：单条浏览中「想现在就看摘要」，不等后台管线。

## 2. 拍板记录（2026-10-17 用户四项拍板）

| # | 决策项 | 拍板 |
|---|---|---|
| D1 | 一期范围 | **仅即时摘要**（`ai_summarize_now` + 详情页入口 + 采用/忽略卡）；标签即时化与模板即时化二期再议 |
| D2 | 配额口径 | **即时工具独立池 60 次/60min**（sampling 配额按 pool 分池：交互型放宽，防滥用手感保留；见 §5） |
| D3 | maxTokens | **维持 1024 全局硬顶**（TL;DR 够用；长文详细摘要引导走 `summarize_item` 异管线，宿主按自身 ctx 处理） |
| D4 | 落库方式 | **采用/忽略确认卡**：结果先呈现，用户点「采用」才走写路径 + `expected_version` 乐观锁——与 human-ai 对称一致 |

## 3. 现状基线（代码取证）

| 事实 | 依据 |
|---|---|
| sampling 协议侧已就绪（HTTP SSE 帧内 `srv_` 回程 + Binder onEvent 双承载、90s 超时、Tier 2 降级） | `lib/mcp/mcp_server.dart:241-299`；ai-app-split.md §3.11 |
| 已有唯一消费工具 `ai_suggest_tags` 的完整模式（只读、四态降级、不 isError） | `lib/mcp/tools.dart:1391-1440` |
| Binder 长工具 `_async` 登记清单存在（sampling 90s ≫ 5s 预算，必须登记） | `lib/mcp/mcp_server.dart:307` |
| UI 摘要卡操作行现为「重新生成摘要」→ `SummarizeCommand` 异步入队 | `lib/pages/item_detail_page.dart:1965-1993` |
| `ApplyAiResultCommand` 是 UI/MCP 共用写出口，`taskAction=null` 走通用分支（summary_md 落库 + 打码 + summary_anchor），支持 `expectedVersion` 乐观锁 | `lib/action/commands.dart:1168`；`lib/action/item_action_handler.dart:1164-1194` |

## 4. 方案设计（goodshare 侧）

### 4.1 工具 `ai_summarize_now`（只读，新）

| 项 | 契约 |
|---|---|
| 参数 | `{id}`（条目 uuid） |
| 行为 | 读条目正文（`bodyText`，与 `claim_ai_task` text 同基线）→ sampling 反向请求宿主 LLM → **同步回预览摘要；不落库、不入队、零写路径** |
| 返回（成功） | `{status:"ok", item_id, summary_md, version}`——`version` = 读取时条目乐观锁版本，「采用」落库时作 `expected_version` |
| 返回（降级） | 四态结构化 status（不 isError，同 `ai_suggest_tags` 口径）：`no_content`（正文空）/ `sampling_unavailable`（宿主未流式声明 sampling）/ `sampling_quota_exceeded`（宿主配额，data 带 retry hint）/ `sampling_failed`（推理异常/回程超时） |
| sampling 请求 | `messages` 单轮 user（标题 + 正文）+ `systemPrompt` 摘要指令；`maxTokens: 1024`（D3）；**`pool: "instant"` 扩展字段**（goodhub 侧分池识别，见 §5） |
| prompt 口径 | **专用摘要 prompt**（goodshare 侧定义，同 `ai_suggest_tags` 模式），全文见 §4.1a。**废止项（2026-10-17 取证修正）**：原写「与宿主异管线摘要 prompt 同风格对齐」不成立——宿主 `llm_summarize` 实走**通用任务 prompt**（`hybrid_inference.dart:27-41`：摘要/标签/回答混用同一 systemPrompt + 任务类型注入，512 tokens 上限），无摘要专项约束。即时版用专用指令（质量高于现状异管线），「与异管线产出一致性」目标废止 |
| 工具描述引导 | 描述明示：「即时预览用本工具；需落库由 UI 采用按钮写回；宿主不在线/长文详摘要走 `summarize_item` 异管线」——对话中的 AI 自动选对通道 |
| 登记 | 加入 `_kBinderAsyncTools`（`mcp_server.dart:307`） |

#### 4.1a prompt 全文（施工照录）

systemPrompt：

```
你是中文摘要引擎。为给定内容输出一段直接可用的摘要正文，不要输出解释、前言或代码块包裹。
```

userPrompt（单轮 user 消息）：

```
请为以下内容生成一段简洁准确的中文摘要（200 字左右，概括核心内容与关键结论）：

条目标题：${item.humanTitle ?? '（无）'}

正文：
$body
```

依据：① 专用指令 + 单轮 + 结构化约束 = `ai_suggest_tags`（`tools.dart:1420-1427`）已真机验证的同款模式；② 标题注入消歧（正文含糊时标题定性）；③ 200 字约束对齐摘要卡 TL;DR 定位（P0-3 折叠规则），1024 tokens 空间绰绰有余；④ 临时会话语义（§15）单发无历史。

> 截断注记（P1-2）：正文 >4000 字符时，proxy 在 `正文：` 行前条件性插入「（原文超长，以下仅为前 4000 字）」行——prompt 模板本体不变，注记由代理面统一加。

### 4.2 UI 入口与交互（`item_detail_page.dart` 摘要卡）

- **入口**：摘要卡操作行（`sectionActions`）在「重新生成摘要」旁加「即时生成」动作（闪电图标 + tooltip），语义标注「即时（需 AI 宿主 App 在线）」。
- **等待态**：卡内 inline loading（`_summarizeInstantRunning`，复用 `sectionActions` running 参数）；goodshare 侧 MCP server 走 SSE 中途 progress 帧，宿主卡片同步可见（M3-T2 既有链路，本端仅呈现）。
- **等待期三条 UX 纪律（2026-10-17 用户 review 拍板）**：① **骨架预留**——loading 卡预留 6 行固定骨架高度 + `AnimatedSize` 过渡（200 字中文卡宽下 5~8 行，防摘要返回时 Layout Shift 跳帧；固定 4 行仍会抖故取 6）；② **主动转后台**——loading 旁常驻文字链接「等不及？转后台处理」→ 点即触发 `SummarizeCommand` 入队 + 清即时等待态（**不 cancel 底层请求**：single-flight 自然完成出表、结果丢弃、宿主 1 次配额认赔——用户主动选择）；控制权交还用户，不等超时被动降级；③ **文案轮转**——loading 文案按时间切（0s「请求宿主…」→ 3s「宿主推理中…」→ 6s「即将完成…」），纯 UI 零协议依赖。真实阶段帧（宿主 reading→thinking）协议上不存在（M2.5 只发起始帧，中途帧 = M2.5-T7 遗留），**一期不做、不假装进度**
- **编辑冲突不置灰（2026-10-17 review 拍板）**：等待期不禁用编辑入口——并发写不止编辑（标签/OCR/其他客户端都 bump version），单点置灰防不住全集且打扰用户；由 P1-1 分级兜底。补一条透明度：预览卡常驻「预览基于 <相对时间> 前的正文」，时效用户自知
- **预览呈现**：结果以「即时预览 · 未保存」区块插入摘要卡内——视觉与已落库摘要明确区分（虚线边/标注），防「被分析两次」双卡心智（P0-3 折叠规则同款纪律）。
- **采用**：`handler.execute(ApplyAiResultCommand(id, ReconstructResult(summaryMd: 预览文本), expectedVersion: item.version), actor: ui)` → 成功 toast「已保存」+ 预览区块转正为正式摘要；`version_conflict` → 提示「条目已变更，请重新生成」并清预览。
- **忽略**：清预览区块，无任何写入。
- **降级路径**：`sampling_unavailable` / `sampling_failed` → toast 明因 + 「转后台入队」按钮（直接触发 `SummarizeCommand`，回落现有双轨）；`sampling_quota_exceeded` → toast 带 retry hint。

### 4.3 服务端统一代理面（2026-10-17 用户方案拍板）

**架构**：功能工具正常开发（各自组装 prompt）+ 新增 `lib/mcp/ai_proxy.dart` 统一代理层收口所有 sampling 发射——与客户端统一面（goodhub `samplingRequestHandler`，M3 已落地，单一入口按 method 分派）构成「server 代理 ↔ client 统一 handler」的多对一架构。

```dart
// server 代理面形态（施工件）
class AiSamplingProxy {
  // 功能工具只提供 prompt + pool + maxTokens；代理管发射与降级
  Future<AiReply> run({
    required String systemPrompt,
    required String userPrompt,
    required String pool,          // 'instant' | 默认池
    int maxTokens = 1024,
  });
  // 内部单点：sampling==null → sampling_unavailable；
  // McpRpcError → quota_exceeded(-32000)/failed 映射；params 组装（pool 字段）
  // in-flight 去重（single-flight 语义，2026-10-17 用户澄清拍板）：
  // 在途表 Map<指纹, Future>——指纹 = md5(pool + systemPrompt + userPrompt +
  // maxTokens)，**基于截断/注记后的最终 payload**（计算点 = pipeline 末端、
  // sampling() 调用前一步——指纹直接对应网络层将发内容；非确定性成分
  // （时间戳/traceId 等）禁止入指纹输入，否则去重静默失效）；
  // **仅在途期间合并**：同指纹第二个调用复用同一 Future（一次推理 = 一次
  // 扣费/一次配额，两调用方同结果）；**完成即从表中移除**（whenComplete
  // 内 remove，先于外部 await 恢复，单线程无竞态）——下一次同指纹请求是
  // 全新推理，正常扣费。禁结果缓存 / TTL 复用 / 跨请求记忆（用户「再点
  // 一次」必须拿到新结果；缓存失效是自找的复杂度）
}
```

- 收益：消 N 工具重复样板（`ai_suggest_tags` 现存 ~50 行）/ 降级超时口径单点 / 二期扩工具零成本 / §5.1 边界纪律天然兼容（代理在 server 侧，host 只认协议）
- **同一方法短时间多次请求（2026-10-17 用户追问，三层防线）**：① UI 单 flight——`_summarizeInstantRunning` 运行中按钮禁用 + 忽略重复触发，同卡同时仅一预览在飞（T2）；② 代理面 in-flight 去重（上方）——误触/并发同请求不产生第二次推理与扣费，配额只扣 1 次（T1）；③ 配额背线——绕过前两层的脚本场景由 instant 池 60 次/60min 拒绝 + retry hint（D2 已拍）。协议层无需处理：每请求独立流/id/completer，数据不串
- **并发语义（已逐层取证）**：HTTP 每 tools/call 独立流、sampling 帧按 `srv_<n>` id 夹带各自流内、回程按 id 唤醒各自 completer（`mcp_server.dart:241-299`）；Binder `_runAsyncTool` 独立 completer 同机制；`SamplingQuota.tryConsume` 同步方法原子扣减（`sampling.dart:29-38`）；`CloudSamplingEngine` 每次独立 HTTP 请求无共享态（`sampling_engine.dart:27-35`）——**协议/配额/引擎/会话四层天然并发安全，无需加锁**
- **前置项（非阻塞）**：① 端侧引擎接入时大概率串行 → 端侧解冻检查项 = 补引擎级并发队列或明示串行降级（端侧已推迟，m3 遗留）；② BYOK 云厂商限流 → 云 API 报错走 `sampling_failed` 降级，语义正确；③ server 代理面 per-server 并发上限（gateway_backpressure 同款）一期不加——去重 + UI 单 flight 后人类场景并发 ≤3，PC 批处理场景出现时再补
- **TTFT 两级超时（2026-10-17 用户 review 拍板）**：① **TTFT 首帧超时 30s**（代理层新增）——发射后无 progress 业务帧/回程帧即 abort，抛 `sampling_failed` + hint「宿主后台响应超时，建议前台运行」并引导转后台管线。防 Android Doze/Frozen 挂起态（socket 不断但写入被挂起，傻等契约 90s = 用户早流失）；**心跳 comment 帧不算数**（M2.5 拍板口径：心跳不重置卡死计时）；② 契约 90s 总超时（既有，`mcp_server.dart:286-296`）= 已收首帧但后续卡住的天花板；③ abort 语义 = 仅放弃 proxy 侧等待，底层请求成孤儿（回程时 completer 已出表，帧静默丢弃，无害），代价 = 宿主白扣 1 次配额（低频可接受）；④ OOM kill 场景由 ECONNRESET/DeadObjectException 秒级捕获归 `sampling_unavailable`，无需本机制

### 4.4 边界细节与风险处置（2026-10-17 用户 review 拍板）

#### P1-1 乐观锁冲突分级（「采用」命中 version_conflict 时）

- 预览时同存 `{version, bodyFingerprint}`——`bodyFingerprint` 必须与 `summary_anchor` **同一口径单一出处**：抽纯函数 `bodyMd5(String? humanMd) => md5.convert(utf8.encode(humanMd ?? '')).toString()`（`item.dart`），收编三处既有复制（`item.dart:228` isSummaryStale / `item_action_handler.dart:1305` summary_anchor 写入 / `:1189` template_output_anchor）；`_applyAiResult` 收编时**保留 effectiveBody 语义**（`keepHuman ? item.humanMd : maskedIncoming`——打码层差异是既有契约，只搬表达式不改口径）；T2 预览态 = `bodyMd5(item.humanMd)`
- **附加纪律**：指纹只能从 `InboxItem.humanMd` 直接算，不经编辑器/文件读回/JSON 中转（换行规范化 = 字节级漂移 = 假失配）
- 冲突时读最新 item 比对正文指纹分级：
  - **正文未变**（tags/元数据 bump 了 version）→ 摘要仍有效，用最新 version **自动重试一次** `ApplyAiResultCommand` → 成功即采用
  - **正文已变** → 摘要基于旧正文 = 潜在脏数据：保留预览不抹杀 + 明示「正文已变更，摘要可能过期」+ 提供「复制文本」「重新生成」；**不提供强制落库**（human-ai 对称原则：不设制造脏数据的捷径）
- 自动重试限一次（防循环）

#### P1-2 长文本 Context 护栏（proxy 硬截断 + UI 预检）

- **取证缺口**：sampling 路径当前零输入护栏——宿主 6000 字符截断仅存在于异管线（`hybrid_inference.dart:35-38`），`sampling.dart` handler 原样透传 messages；`ai_suggest_tags` 同样裸奔
- **proxy 统一截断**：`body.length > 4000` → 取前 4000 + prompt 注记「（原文超长，以下仅为前 4000 字）」——禁静默截断，与宿主异管线口径同款；阈值依据 v2-requirements D3 拍板（头部截断覆盖 80% 场景）+ TL;DR 200 字定位
- **UI 预检**：bodyText > 8000 字符 → 「即时生成」置灰/引导「长文详摘要请走后台管线」（TL;DR 价值递减区）
- **预览透明**：本次若发生截断，预览区标注「基于正文前 4000 字」
- Binder 90s 超时：截断后 input 小，正常 <30s；极端网络走 `sampling_failed` 既有降级

#### P2-3 页面生命周期（等待期退出详情页）

- **不 cancel**：代理面为 service 层长生命周期（非 widget 绑定），Future 完成/失败都触发 `whenComplete` 出表——页面退出不影响在途表，无悬挂可能
- UI 侧唯一义务：状态回调 `mounted` 守卫（防 setState after dispose）
- 离开即弃等待态——不把 Future 提升到跨页面生命周期（重试成本 = 数秒，YAGNI）
- 进程杀 = 内存全清（在途表 + 配额同为内存态，重启清零语义一致）

#### P2-4 预览态持久化（明确 transient）

- 预览 = Widget transient state：**不暂存 DB/Preferences**，离开即清
- 依据：零写路径拍板（D4）+ 预览非用户数据 + 重新获取成本低（数秒 + 1 配额）
- 与「采用/忽略」交互闭环一致：要么落库成正式数据，要么丢弃

### 4.5 不做清单（一期）

- 不做标签/模板即时化（二期）；不废异管线（宿主离线兜底 + 长文详摘要通道保留）；不做 PC 路径介入；不做同步直接落库（D4 已排除）；不新建独立 AI 开放面（复用 McpRuntime 挂载面）。

## 5. 跨仓改动（goodhub 侧，配额分池 D2）

现状：`SamplingQuota` per-key 滑动窗口，默认 20 次/60min（`lib/mcp/sampling.dart:20-38`）；`samplingRequestHandler` 以 `serverKey` 记配额。

改法（最小侵入，机制零新增）：

1. `samplingRequestHandler` 读 params 扩展字段 `pool`（String，缺省 = 默认池）：配额 key 派生为 `$serverKey` / `$serverKey:$pool`。
2. `SamplingQuota` 增 per-key 上限覆盖表 `caps`（`Map<String,int>`，按 key 后缀匹配）：默认 20 不变，`instant` 池显式 60；`snapshotHits`/`restoreHits` 随 key 自动兼容（落盘恢复无需改）。
3. 三处挂载点（`mcp_runtime.dart:553` / `gateway_controller.dart:277` / `debug_run_orchestrator.dart:297`）共用同一 handler 工厂，**零改动自动继承分池**。
4. `pool` 为 Tier 1 私有扩展约定（`x-` 前缀之外的 params 平级字段，与 `_meta.progressToken` 同思路）：Tier 2 server 不发 = 走默认池，无感。

### 5.1 接入点边界（2026-10-17 用户拍板，施工纪律）

**goodhub host 接入点只定义通用参数和行为，不写特定方法供外调用**：

- ✅ 该在 host 侧：`messages`/`systemPrompt`/`maxTokens`/`pool` 的协议语义、配额扣减、PII 围栏、临时会话隔离、回程帧/超时——全部场景通用，零场景分支
- ❌ 禁止在 host 侧：摘要 prompt 的兜底/覆写、「识别摘要场景」的特判、任何含业务语义（摘要/标签/模板）的代码——**prompt 与场景行为由调用方（摘要服务）经 sampling params 自带**
- 判据（施工自查）：`lib/mcp/sampling.dart` 及其挂载点不得出现业务名词；`pool` 只是配额 key 后缀，不承载场景语义
- 推论：二期扩即时标签/即时模板时 goodhub 侧**零改动**——新场景 = goodshare 侧新工具 + 自带 prompt，host 只认协议

## 6. 契约回写点（同轮，跨仓只读引用方同步）

| 文档 | 改动 |
|---|---|
| goodshare `docs/design/ai-app-split.md` §3.11 | 消费工具从「最小 `ai_suggest_tags`」扩为「即时摘要族」：`ai_summarize_now` 契约摘要 + `pool` 扩展字段约定 + 配额分池口径 |
| goodhub `docs/project/index.md` 代码落点 sampling 行 | 备注补「pool 分池（instant 60/60min）」 |

## 7. 验收标准

1. 真机：详情页「即时生成」→ 数秒出预览 →「采用」→ 摘要卡更新、`summary_md` 落库、`summary_stale` 状态正确、`expected_version` 冲突路径可复现
2. goodhub 杀死/未装 → `sampling_unavailable` → UI 提示 + 一键转后台入队成功
3. Binder 路径：即时工具 `_async` 终帧回注，无 ANR（调用预算 <5s 不被突破）
4. 契约钉子：`test/mcp_server_test.dart` 覆盖四态降级 + 只读不变条目（工具执行前后 `get_item` 摘要字段不变）+ version 回传
5. 配额语义：`instant` 池 60 次/60min、默认池 20 次/60min（goodhub 单测钉两池独立计数）
6. 回归：双仓 `flutter analyze` 0 issue + 全量测试绿
7. **宿主后台应答（2026-10-17 补）**：goodhub 退后台（进程存活、UI 不可见）时，goodshare 前台即时摘要的 sampling 回程正常到达并完成——协议上连接保活即可应答，但未经真机验证（M3 联调为宿主前台场景）；失败则降级路径（toast + 转入队）兜底，功能不瘫

## 8. 施工分解

| # | 任务 | 落点 | 量级 |
|---|---|---|---|
| T1 | `AiSamplingProxy` 代理面（§4.3，含 single-flight 去重（指纹 = md5(pool+sys+user+maxTokens)，截断后末端计算）+ 4000 字符硬截断 + **TTFT 30s 两级超时** + 降级映射）+ `ai_summarize_now` 工具（契约 §4.1，prompt 照录 §4.1a，经代理发射）+ `_kBinderAsyncTools` 登记 + `bodyMd5` 单一出处收编（P1-1）+ 契约钉子（四态降级 / 只读不变 / 截断注记 / 去重两次调用各发射一次 / **TTFT 超时 abort 路径** / bodyMd5 收编后 isSummaryStale 行为等价；含 `ai_suggest_tags` 迁代理面的等价重构） | goodshare `lib/mcp/ai_proxy.dart`（新）+ `lib/mcp/tools.dart` + `mcp_server.dart` + `lib/models/item.dart` + `lib/action/item_action_handler.dart` + `test/mcp_server_test.dart` | ✅ 已落 |
| T2 | UI：即时入口 + inline loading（骨架 6 行 + 文案轮转 + 主动转后台）+ 预览卡（含时效标注）+ 采用/忽略（P1-1 冲突分级）+ 降级转入队 + mounted 守卫 + 长文预检 + 截断标注 + 预览 transient（P2-3/P2-4） | goodshare `lib/pages/item_detail_page.dart`（+ 预览小组件按行数纪律拆） | ✅ app 侧已落（2026-10-17，按决策 A：底层接既有 SummarizeCommand 异步管线非流式；真·采样流式路径等 goodhub Binder 接好再做。截断标注/长文预检属采样态特性，异步态暂不适用） |
| T3 | goodhub 配额分池（`pool` 字段 + caps 覆盖表 + 单测） | goodhub `lib/mcp/sampling.dart` + `test/mcp/sampling_test.dart` | ✅ goodhub 半边就绪（2026-10-17 用户确认） |
| T4 | 契约回写（§6 两文档） | goodshare `ai-app-split.md`（§3.11 已含 ai_summarize_now + instant 池 60/60，✅）+ goodhub `index.md`（✅ goodhub 半边随 T3 一并就位，2026-10-17） | goodshare 半边 ✅ / goodhub 半边 ✅ |
| T5 | 验收：双仓 analyze/测试 + 真机联调（含 Binder 路径） | — | 🟡 启动（2026-10-17）：goodshare 侧前置自检 `analyze` + `mcp_server_test` 全绿（instant 族钉子 ✅）；真机联调 + Binder 路径待物理设备 + goodhub 联调 |

> 顺序纪律：T3 与 T1/T2 可并行（接口约定 = `pool` 字段先行对齐）；T4 随 T1/T3 同轮；T5 收尾。
