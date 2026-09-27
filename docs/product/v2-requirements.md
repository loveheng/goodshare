---
status: active
updated: 2026-09-27
---

# 拾贝（goodshare）V2 需求文档：离线双态 AI + 多源健康接入

> 版本：V2.0（承接 `product-requirements.md`）
> 范围：将 PRD §6 模块二的「AI 占位」升级为**离线端侧实现**；新增**多源健康数据接入**与**通用截图解析接口**。
> 关联文档：`../product/product-requirements.md`（全局 PRD）、`../architecture/overview.md`（架构）、`../guide/mcp-integration.md`（MCP 接入）。

## 1. 目的与范围

MVP 已跑通「数据进得来 / 双态存得下 / PC 读得到」铁三角，AI 仅占位。V2 目标：

1. **离线双态重构**：用端侧小模型替代云端兜底，完成聊天记录降噪 + 双态剥离 + 自动打标 + 隐私打码，兑现 PRD「完全离线」承诺。
2. **多源健康接入**：既走标准健康 API（Health Connect / HealthKit），也通过**截图解析接口**归一各厂商健康 App 的截图。
3. **通用截图解析接口**：一套管线解析任意厂商截图（健康 / 发票 / 名片 / 聚会计划），统一归整为人类态 `human_md` 与机器态 `machine_json`。

## 2. V2 与 MVP 的接口契约

V2 不改变 MVP 的数据模型主干（`inbox_items` 三态字段、`daily_metrics`、`ai_task_queue`），仅**扩展 machine_json 的取值**与**新增健康快照落点**。MCP 工具向后兼容，仅增量 `type` 取值。

## 3. 模块二升级：离线双态 AI 重构管线

### 3.1 技术选型（系统自带模型，零下载）

> 硬约束：V2 端侧 AI **不下载、不内置任何额外大模型**，仅调用设备厂商提供的系统级 on-device 模型。隐私与离线由系统模型原生保证。

| 平台 | 系统模型 | 接入方式 | 说明 |
|---|---|---|---|
| iOS | **Apple Foundation Models**（`SystemLanguageModel.default`，iOS 26+ / A17+） | Flutter 经 platform channel 或 `flutter_apple_foundation_models` 调用 | 完全端侧、无下载；支持 `Guide` 约束输出（类 GBNF，可锁 JSON Schema） |
| Android | **Gemini Nano via AICore**（`com.google.android.aicore`，Pixel / 部分旗舰 Android 15+） | Jetpack/ML API 或 platform channel | 系统级 on-device；**仅部分设备可用**，缺失则回退 V1（见 §3.7） |
| OCR（通用） | **`google_mlkit_text_recognition`** | Flutter 插件 | 系统模型多为**纯文本**，截图须先 OCR 出文本再喂系统模型；各厂商通用 |
| 调度 | 复用 `flutter_foreground_task` + `ai_task_queue` | — | 充电/空闲时批处理，避免前台卡顿 |

**关键约束**：系统模型普遍**仅文本、无视觉输入** → 截图解析坚持 OCR-first（§4.2/§5），不依赖 VLM。结构化输出靠 iOS `Guide`；Android 侧若无语法约束则用「提示词 + JSON 校验/重试」兜底。

### 3.2 为什么离线可行（与 PRD 风险项对应）

PRD §10 风险「完全离线 ↔ 高质量互斥」在 V2 通过**系统模型 + 约束解码 + 任务队列**缓解：系统自带模型对「结构化抽取 / 摘要 / 降噪」类任务足够，且 iOS `Guide` 等机制把输出锁进 Schema，避免幻觉导致 JSON 损坏。质量弱于云端 Haiku，但**零下载、零外泄**是核心卖点，且不受模型体积 / OOM 拖累。

### 3.3 管线流程

```mermaid
flowchart TD
    Q[ai_task_queue pending] --> O{任务类型}
    O -->|chatlog| C[LLM 降噪+议题摘要<br/>GBNF→machine_json]
    O -->|url| U[LLM 取标题+TL;DR+实体]
    O -->|screenshot| S[OCR→文本→LLM 归一<br/>见 §5]
    O -->|document| D[LLM 抽取结构化字段]
    C & U & S & D --> M[隐私打码<br/>身份证/银行卡 regex+Luhn]
    M --> T[自动打标 2-3 个]
    T --> W[写 human_md / machine_json<br/>is_processed=1]
    W --> ERR{失败?}
    ERR -->|是| F[is_processed=-1<br/>退避重试/死信]
```

### 3.4 数据标注与隐私打码

- **自动打标**：LLM 从内容推断 2–3 个标签写入 `tags`（JSON Array），沿用 MVP 序列化方式。
- **隐私打码**：LLM 产出后必经本地规则层——18 位身份证、银行卡号（Luhn 校验）默认 `****` 打码；打码在端侧完成，原始 `raw_content` 保留但 `human_md/machine_json` 不含明文敏感号。

### 3.5 资源预算与降级

| 维度 | 预算 | 降级策略 |
|---|---|---|
| 模型体积 | **0（不下载/不内置）**，模型由系统拥有 | — |
| 延迟 | 取决于系统模型：Apple A17+ 较快；Gemini Nano 视设备 | 队列异步，不阻塞 UI；闲时/充电批处理 |
| 内存 | App 自身常驻小；模型内存由 OS 管理，不再由本 App 持有 1–2GB | 系统模型不可用时回退 V1（§3.7） |
| 失败 | `is_processed=-1` + 指数退避重试（最多 3 次）→ 死信待人工 | 不阻塞其他队列项 |

### 3.6 移动端落地防御：内存与温控（设备状态感知调度）

> 实战问题（已发现，重构为系统模型场景）：即便不再内置大模型，系统模型推理仍可能在设备低内存 / 过热时被 OS 中断或拒答；且 Android 系统模型碎片化。需在 `ai_task_queue` 调度器中加入**设备状态感知与优雅中断**。

- **模型由 OS 持有**：本 App 不再加载/释放 2GB 权重（该 OOM 风险已消除）；但调用系统模型时应避免在内存/电量紧张时发起，降低被 OS 拒答概率。前台服务（`flutter_foreground_task` dataSync，见 `../architecture/overview.md`）防本进程被回收，与系统模型可用性互补。
- **设备状态感知调度**：充电或电量 ≥ 阈值（建议 40%）才允许加载与推理；低电量时任务停留 `pending` 等待时机；息屏 + 充电时批量处理队列，避免前台交互抢资源。
- **系统内存警告优雅中断**：监听 iOS `didReceiveMemoryWarning` / Android `onTrimMemory`(TRIM_MEMORY_RUNNING_CRITICAL) 与 `ComponentCallbacks2`；触发时：暂停当前系统模型调用 → 任务回滚 `processing→pending` → 释放本地中间缓冲 → **不抛未捕获异常（不崩溃）**；下次调度从 `pending` 续跑。
- **温控节流**：监听 Android `ThermalStatus` / iOS `ProcessInfo.thermalState`；过热（moderate+）暂停推理并提示，降温后恢复。
- **崩溃兜底**：推理外层 `try/catch` 包裹；任何异常均回滚为 `pending`（而非 `-1` 死信），保证 OOM / 中断可自愈重跑。

### 3.7 设备能力门控与 V1 回退

> 分级体验原则：AI 双态重构是**可选增强层**，而非核心依赖。App 的「吞噬口 + 存储 + MCP 网关」始终可用（即 PRD 的 V1 基线，见 `../product/product-requirements.md` §9）；端侧 AI 仅在设备**提供可用系统模型**时解锁，否则回退 V1，且**绝不内置/下载模型**。

- **能力探测（首次启动）**：判系统模型可用性，不判 RAM/存储下载——
  - **iOS**：`SystemLanguageModel.default.isAvailable` 为真（iOS 26+ / A17+ 及以上）→ 解锁；否则 V1。
  - **Android**：AICore / Gemini Nano 可用性查询（`com.google.android.aicore` 能力探测）→ 可用解锁；**不可用设备（绝大多数 Android）直接 V1**，不内置模型。
  - NPU/芯片由系统模型自身利用，本 App 不感知。
- **运行期路由**：`ai_task_queue` 消费者经 `ReconstructorRegistry.resolve()` 取首个 `isAvailable` 的实现——V2 档走 `SystemModelReconstructor`（§3.8），V1 档走 `PlaceholderReconstructor`（`raw_content` 原样入 `human_md`、`machine_json` 留空、`is_processed=1`），端到端不卡死（与 MVP 占位行为一致）。
- **优雅降级与重评**：档位持久化（`shared_preferences`），「设置」可手动覆盖（强制 V1 / 尝试 V2）；系统模型调用抛错（内存压力 / 不可用）时自动回退 `pending`（与 §3.6 崩溃兜底联动）。系统升级 / 换机后下次启动重测。
- **用户感知**：非 V2 设备，AI 相关入口展示「本机暂不支持离线 AI，已切换基础模式」，避免沉默降级。

### 3.8 AI 能力接口抽象与多实现（可插拔）

> 设计原则：AI 双态重构以**接口**定义能力，具体实现可插拔替换；队列 / UI / MCP 层不耦合任何单一后端。新增一种 AI 后端 = 实现接口 + 注册，消费者零改动。

- **接口契约（Dart 抽象）**：
```dart
/// AI 双态重构能力接口（V2 抽象层）
abstract class AiReconstructor {
  /// 设备是否具备运行该实现的能力（供 §3.7 门控）
  Future<bool> get isAvailable;
  /// 执行双态重构：输入脏数据，产出人类态 / 机器态 / 标签
  Future<ReconstructResult> reconstruct(ReconstructInput input);
}

final class ReconstructResult {
  final String humanMd;                     // 重构后 Markdown
  final Map<String, dynamic>? machineJson;  // 结构化 JSON（可为 null）
  final List<String> tags;                  // 2–3 个自动标签
  final bool masked;                        // 是否已执行隐私打码
}
```
- **实现清单（按优先级）**：
  | 实现 | 档位 | 说明 |
  |---|---|---|
  | `SystemModelReconstructor` | V2 | 调 iOS Foundation Models / Android AICore（§3.1），截图走 OCR-first |
  | `PlaceholderReconstructor` | V1 | 原样复制 `raw_content`→`human_md`、`machine_json` 留空，保证端到端不崩 |
  | `CloudReconstructor`（可选） | 兜底 | 仅当用户显式开启「云端兜底」开关（§8 开放问题②），否则不启用 |
- **路由**：`ai_task_queue` 消费者经 `ReconstructorRegistry.resolve()` 取首个 `isAvailable` 的实现（系统模型优先，缺失回退占位）；§3.6 的内存/温控/崩溃兜底统一在接口调用外层处理。
- **扩展点**：未来接入新后端（厂商 VLM、本地 ONNX 等）仅需新增实现类并注册，管线与 MCP 层不动。

## 4. 多源健康数据接入

### 4.1 标准 API 拉取（结构化）

- 用 **`health`** 包统一 Health Connect（Android）/ HealthKit（iOS）：步数、睡眠、心率、体重、 workout。
- 落点：聚合写 `daily_metrics`（`steps` / `sleep_minutes` / `calendar_events_json` 复用；心率/体重样本暂存 `machine_json` 或扩展列）。
- 定时/手动触发，写入即纳入 Timeline（PRD §6 模块四 V2）。

### 4.2 跨厂商截图解析接口（ScreenshotParser）

面向**不开放 API 的厂商 App**（微信运动、华为运动健康、小米运动、Apple 健康截图、Google Fit、Samsung Health、Keep、悦跑圈等）。核心思路：**不写每家的正则**，而是 OCR → 端侧 LLM 推断结构，天然跨厂商。

```mermaid
flowchart LR
    IMG[厂商健康截图] --> OCR[ML Kit OCR]
    OCR --> TXT[文本块]
    TXT --> LLM[端侧 LLM + GBNF<br/>HealthRecord Schema]
    LLM --> JSON[machine_json: HealthRecord]
    JSON --> MD[human_md 周报/日概览]
    JSON --> DM[聚合 daily_metrics]
```

### 4.3 统一健康记录 Schema（machine_json）

```json
{
  "schema": "health_record.v1",
  "source_app": "huawei_health",
  "date": "2026-09-27",
  "metrics": {
    "steps": 8421,
    "sleep_minutes": 412,
    "resting_hr": 62,
    "weight_kg": 68.5,
    "workouts": [{"type": "run", "duration_min": 32, "calories": 310}]
  }
}
```

- **落点**：截图作为 `inbox_items`（`item_type='health'`，`raw_file_path`=截图，`machine_json`=HealthRecord，`human_md`=概览）；`steps/sleep_minutes` 同步聚合进 `daily_metrics`，供 `get_timeline_context` 直接消费。

## 5. 通用截图解析接口（不止健康）

ScreenshotParser 是**通用能力**，复用同一套 OCR→LLM(GBNF) 管线，仅切换目标 Schema：

| 场景 | 目标 machine_json Schema | 人类态示例 |
|---|---|---|
| 健康截图 | `health_record.v1`（§4.3） | 当日步数/睡眠概览 |
| 发票 | `invoice.v1`（amount/date/merchant/tax/items） | 报销要点卡片 |
| 名片 | `contact.v1`（name/phone/org/title） | 联系人速记 |
| 聚会计划 | `event.v1`（when/where/attendees/action_items） | 待办 Checklist |

- **入口**：系统分享图片即触发 `task_action='ocr_and_extract'`，LLM 先判定截图领域再套对应 GBNF Schema（或并行打分取置信最高）。
- **隐私**：截图 OCR 文本与 LLM 推理全程端侧，不外传。

## 6. MCP 接口增量

| 变更 | 说明 |
|---|---|
| `query_machine_data` 扩展 `type` | 新增 `'health'`（返回 `health_record.v1` 数组） |
| `get_timeline_context` | 已含 `health`（来自 `daily_metrics`），V2 补充心率/体重样本 |
| 可选 `reparse_item(id)` | 手动重触发某条目双态重构（模型升级后重放） |

其余 MVP 工具保持不变，向后兼容。

## 7. Schema 增量（V2）

- 复用 `inbox_items`，新增 `item_type='health'`，`machine_json` 取值扩展为 `health_record.v1` / `invoice.v1` / `contact.v1` / `event.v1`。
- `daily_metrics`：V2 先复用现有三列；心率/体重样本如需持久化，V3 评估新增 `health_samples_json` 列（不阻塞 V2）。
- **无需新建表**，迁移成本最低。

## 8. 风险与开放问题

| 项 | 风险 | 缓解 |
|---|---|---|
| 跨厂商 OCR 漂移 | 个别厂商截图排版怪异 | OCR 文本 + 系统模型容错 + 人工 `reparse_item` 兜底 |
| 系统模型碎片化（Android） | 多数 Android 无统一系统模型，AI 仅 iOS/部分旗舰可用 | 明确 V1 回退基线；不内置模型；UI 明示（§3.7） |
| 系统模型能力受限 | 纯文本 / 上下文短 / JSON 约束弱于 GBNF | OCR-first 截图；提示词 + 校验重试兜底结构化（§3.1） |
| 系统模型中断 / 拒答 | 低内存 / 过热时 OS 拒答或报错 | §3.6 优雅中断 + `try/catch` 回滚 pending 自愈 |
| 能力误判 | 可用性探测不准导致误开 / 漏开 | 手动覆盖开关 + 调用失败自动降档（§3.6/§3.7） |

**开放问题（待决策）**：① Android AICore 不可用时的产品表述（仅 V1 / 提示换机）；② 是否允许「离线失败可临时回落云端」的用户开关（与隐私承诺冲突，需明示）；③ `health_record.v1` 是否纳入 Vault 默认隔离。

## 9. 验收标准

- [ ] 分享一条微信聊天 TXT → 队列离线产出 `human_md`（去噪+议题）+ `machine_json` + 2–3 标签，`is_processed=1`。
- [ ] 分享一张厂商健康截图 → OCR→LLM 产出 `health_record.v1` 且 `daily_metrics.steps/sleep_minutes` 被更新。
- [ ] 全程断网可完成上述两步，且无任何对外网络请求（隐私验证）。
- [ ] 身份证/银行卡号在 `human_md/machine_json` 中默认打码。
- [ ] AI 功能开启后，**不触发任何大模型下载**（仅调用系统模型），断网可完成双态重构。
- [ ] 推理中触发系统内存警告 → 当前系统模型调用暂停、任务回滚 `pending`、App 不崩溃，可后续续跑。
- [ ] 仅充电/电量充足时发起系统模型推理；低电量任务停留 `pending` 等待时机。
- [ ] 不支持系统模型的设备（如多数 Android）→ AI 入口提示不可用，核心收集 / MCP 网关仍正常（V1 模式不崩）。
- [ ] 支持系统模型设备（如 iOS A17+）→ 自动解锁离线 AI，双态重构生效；手动切回 V1 后可恢复基础模式。
- [ ] PC 经 `query_machine_data(type='health')` 可读到归一化健康 JSON（Vault 隔离生效）。
