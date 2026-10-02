---
status: draft
updated: 2026-09-28
---

# 端侧 LLM 设计（LiteRT-LM / FoundationModels）

> 通过 Google AI Edge 主线框架 LiteRT-LM 与 Apple FoundationModels 为 goodshare 接入端侧 LLM 能力（摘要 / 关键词等文本态产出）。双端各走官方方案：Android 用 LiteRT-LM + SoC 感知模型包；iOS 用系统内置模型（零下载）。评估拍板于 2026-09-28。

## 1. 选型结论

| 决策点 | 结论 | 依据 |
|---|---|---|
| LLM 推理框架 | **LiteRT-LM**（Google AI Edge 主线） | MediaPipe LLM Inference API 已 maintenance-only 并标 @Deprecated，新特性只在 LiteRT-LM |
| Flutter 接入方式 | **Dart 接口 + 双端薄原生桥**（无官方 Flutter API） | flutter_gemma 为社区包且底层是弃新中的 MediaPipe，不符合「官方方案」诉求 |
| Android 运行时 | LiteRT-LM **Kotlin API（Stable）** | 官方语言支持矩阵最高档 |
| Android NPU | SoC 感知模型包，三级降级 NPU→GPU→CPU | 一加 Ace6（SM8750/V73）+ 天玑 9400（MT6991）官方均在支持列表 |
| iOS 运行时 | **FoundationModels framework（iOS 26+）**，非 LiteRT-LM Swift | 系统 ~3B 模型零下载零管理；LiteRT-LM Swift 为 Early Preview，且 iOS 无 NPU 路线 |
| 模型 | 文本档定 **Qwen2.5-1.5B**（用户拍板；中文原生，Apache-2.0）。⚠️ 官方 `.litertlm` 目录中该模型为 **8-bit 通道量化版（~1.5GB，4096 ctx）**，无官方 int4——选包时按此现实取 8bit 档或评估社区 int4 转换包（如 litert-community 的 Qwen2.5-Coder 系先例，int4 blockwise ~1.12GB）；多模态档（图片描述）Gemma 系待选 | Qwen 中文质量优于同体积 Gemma；GPU decode ~31 tk/s 短输出 5–10s；NPU 预编译包以 Gemma 为主，Qwen NPU 档可能需自编（二阶段处理） |
| 用例 | **三个全做**：条目摘要 / 关键词提取 / 图片描述（图片描述依赖多模态，Android 侧需 Gemma 多模态包验证，排最末） | 2026-09-28 用户拍板「摘要/关键词/图片描述 这些都要」 |

## 2. 架构

跨端能力接口化（同翻译层 `TranslationEngine` 模式），UI 与动作层只依赖 Dart 接口：

```mermaid
flowchart TD
    A["UI / Command / MCP"] --> B["OnDeviceLlmEngine (Dart 接口, 后端无关)"]
    B --> C["Android 桥 (MethodChannel → Kotlin)"]
    B --> D["iOS 桥 (MethodChannel → Swift)"]
    C --> R{"LlmRouter (原生侧后端路由)<br/>SoC 命中 + NPU 包在位?"}
    R -->|8 Gen 3+ 命中| Q["QualcommQnnBackend<br/>(ExecuTorch QNN, .pte)"]
    R -->|天玑 9400+ 命中| M["MediaTeaNpuBackend<br/>(LiteRT MTK CompiledModel, 谷歌路线)"]
    R -->|未命中 / NPU 包缺| L["LiteRtLmBackend<br/>(GPU/CPU 通用包, 现状直绑收编为其中一实现)"]
    D --> J["FoundationModels (iOS 26+)"]
    J --> K{"SystemLanguageModel<br/>.availability"}
    K -->|available| L2["系统 ~3B 模型 (零下载)"]
    K -->|不可用| M2["降级: 占位 + 明示原因"]
```

- 接口方法：`isAvailable` / `generate` / `generateStream`（流式可选实现）。
- **isAvailable 语义分端**：Android = 模型包已下载且引擎初始化成功；iOS = Apple Intelligence 可用性探测。**均动态探测、不做一次性持久化**（沿用翻译层「语言包状态动态，避免 OCR 误判锁死」口径）。
- 降级链统一：不可用 → 占位完成 + 可观测反馈（沿用队列「降级不卡死」+「结果可观测」双原则——新增异步 AI 动作必须配状态反馈）。

### 2.1 原生后端路由（2026-10-02 拍板：为节能充分发挥 NPU，突破 LiteRT-LM 单栈）

**动因**：NPU 的节能收益（decode 快数倍 + 发热大降，高频短任务与后台批量的关键）要求绕开 LiteRT-LM 的 NPU 生态窄（官方 NPU 包以 Gemma 系为主、Qwen NPU 化无官方方案）的限制——**接口抽象上移到原生后端层，各厂商 NPU 方案各 自实装**。

- **Dart 层零改动**：`OnDeviceLlmEngine` 与 `goodshare/llm` 通道协议（四方法）天然后端无关；可选增补 `backendName` 字段供设置页展示与可观测。
- **原生侧抽象**：Kotlin 定义 `LlmBackend` 内部接口（同四方法语义），`LlmBridge` 改为 `LlmRouter`——按「SoC 命中 + 对应后端模型包在位」选后端，全部未命中落 `LiteRtLmBackend`（现直绑实现收编为其中一实现，GPU/CPU 行为不变）。运行时校验失败自动落 GPU（既有 LiteRT fallback 口径），不置死信。
- **两厂商后端载体（2026-10-02 拍板：按家族各用其最成熟方案，评估过程见本轮讨论）**：
  - **QualcommQnnBackend → ExecuTorch QNN backend 作载体**（Meta 官方维护的 QNN 包装层，A8W8/A16W4 量化、`.pte` 导出、LLM `--use_qnn` 导出路径齐备；1.4/1.5 版补批量调度 + off-graph KV cache）——替代原「自研 QNN C++/JNI 管线」设想，省掉最大块包装工程。已知生产坑：QNN NPU-offload LLM 在部分目标芯片有退化输出（degenerate output）社区报告，**逐芯片验证不可省**；Qwen3-4B→`.pte`→QNN 编译需自跑（AI Hub 官方示例以 Llama/Gemma 为主）。
  - **MediaTeaNpuBackend → LiteRT MTK CompiledModel API（谷歌路线）**：ExecuTorch MTK backend 存在但早期阶段，联发科自己更生产化的 NPU 路径反而是 LiteRT/MTK 协作路线（Google AI Edge 官方文档）；且 MTK 封闭、社区资料稀少（用户拍板依据之一），选谷歌协同路线文档与维护最有保障。**红利：与兜底档同属 LiteRT 栈——全项目仅两个运行时**（LiteRT 管联发科 NPU + 通用 GPU/CPU 兜底，ExecuTorch 专管高通 NPU）。
  - 共同成本：**双栈双格式**（`.litertlm` + `.pte`）、模型目录加 backend 维度、双下载管理、切换内存成本；QAIRT 运行库（`libQnnHtp*.so`）随 ExecuTorch QNN 引入，体积与再分发许可待核（§3.3）。
- **任务路由**：NPU 后端命中后优先派「高频短输出」任务（打标/分类/结构化抽取）——快且省电；长 ctx 摘要类仍可路由 LiteRT GPU 档（NPU 包 ctx 上限小）。按后端 × 任务分档，不是整体切换。
- **实施分期**：①`LlmBackend` 接口 + `LlmRouter` 骨架（架构不可逆部分先锁，LiteRT 收编）→ ②QualcommQnnBackend（ExecuTorch QNN，用户真机 8 Gen 3 优先：`.pte` 导出验证 + 跑分 + 退化输出检查）→ ③MediaTeaNpuBackend（LiteRT MTK CompiledModel，真机核实 API 可用性）。各后端独立排期，接口冻结后互不阻塞。

## 3. Android 侧：SoC 感知模型包

### 3.1 包矩阵

文本档模型已定 **Qwen2.5-1.5B**（中文原生；官方 `.litertlm` 下载为 8-bit/4096ctx/~1.5GB 档，Apache-2.0 再分发宽松）。**LiteRT-LM 官方模型目录当前仅 ~10 个模型**（Gemma 系为主 + phi-4-mini + Qwen2.5-0.5B/1.5B + Qwen3-0.6B + FunctionGemma），这是平台现状硬约束：新模型需走 litert-torch 自行转换（社区有 Qwen2.5-Coder int4 先例，~1.12GB）；模型多档目录（`LlmModel`）按此现实设计——目录条目=「官方直下包优先，缺档再评社区包/自编」。

| 设备 SoC | `ro.soc.model` | 模型包 | 来源 |
|---|---|---|---|
| 骁龙 8 Elite | SM8750 | **官方 NPU 包在列**：Gemma3-1B 4bit 1280ctx **~658MB**（SM8750 专包直下）；Qwen NPU 档二阶段 | **官方预编译直下** |
| 天玑 9400 | MT6991 | **官方 NPU 包在列**：Gemma3-1B 4bit 1280ctx ~986MB；Qwen 档二阶段 | **官方预编译直下** |
| 其他 | — | **Qwen2.5-1.5B 8bit 通用 `.litertlm`**（GPU/CPU，4096 ctx） | HuggingFace LiteRT 社区（国内走 R2 自托管镜像） |

### 3.1a 设备基线与分档拍板（2026-10-02，覆盖上表分档策略）

讨论链（4B 能力评估 → NPU 生态核实 → 用户划基线）收敛出的最终模型策略：

1. **设备基线**：SoC ≥ **高通 8 Gen 3（SM8650，支持 QNN 构建——用户确认）/ 天玑 9400（MT6991）**，RAM ≥ **12GB**（与 minSdk=34 同级的兼容基线决策）。
2. **基线内设备**：**4B 档为默认**（Qwen3-4B/3B int4 GPU 包，~2-2.5GB 权重 / 3-4GB 内存峰值，12GB 从容）——OCR 修正、结构化抽取（R3）、翻译润色的可靠执行者；QNN/NPU 后端可行（目标芯片只剩高通/联发科两家族，NPU 档从碎片化彩蛋变为两条编译管线可覆盖的规划项），定位为同模型的加速后端，适合高频短输出任务。
3. **基线下设备**：**本地不再维护 1.5B 兜底档，LLM 重能力全部交给外部 AI 客户端经 MCP 跑**（「MCP 优先」拍板的自然延伸）——模型路线收敛为「4B 单档 + QNN 后端演进」；1.5B 条目可留目录作轻任务/省电可选档，不再是兼容性负担。
4. **ML Kit / Sherpa 确定性能力**（OCR / 翻译 / 分类 / 条码 / 转写）不受基线约束，所有设备保留。
5. **待实测（定 R1/R3 实现深度）**：Qwen 4B int4 GPU 包在 8 Gen 3 真机跑分（decode tk/s、内存峰值、发热）+ OCR 修正小样评估（命中率/误改率）。
6. RAM 档位检测：`ActivityManager.MemoryInfo`（MethodChannel 一条），并入 `AiQueueService` 门控体系，基线下设备 LLM 入口预检直接不可用。

### 3.1b 模型能力门槛与任务分档（2026-10-02 拍板：起步即 4B）

**决策**：4B 为可用模型的起步档——主档 4B 不留兼容性妥协；实测加 Qwen3-1.7B 对照位（达标则设「省电轻任务档」）；0.6B/1.5B 旧代际档正式出局，不再投入兼容。

**决策说明**（为什么 4B 是门槛、以及为什么这么表述）：

1. **参数量的悬崖不在「聪明度」，在「稳定性」**。对管线而言，模型产出格式的稳定性比智能水平更重要——结构化 JSON 坏了（漏字段/类型错/夹带解释文字）整条链白跑，OCR 修正误改比不改更糟。小模型的典型失败模式正是格式漂移与幻觉改写，而非「不会做」。
2. **按任务圈定门槛，不搞一刀切**：

| 任务圈 | 参数量门槛 | 说明 |
|---|---|---|
| 关键词 / 打标 / 简单分类 | ≥1.5B 可用 | 输出短、容错高（现有 1.5B 真机已在做） |
| 摘要 / 聊天降噪（R1） | ≥3B 稳 | 需理解上下文组织段落；1.5B 会丢要点、口语化漂移 |
| 结构化 JSON 产出（R3 发票/名片） | **≥4B 可靠** | 悬崖所在：格式漂移是主要失败模式 |
| OCR 修正 / 翻译润色 | **≥4B** | 需「判断对错但不越界改写」的精细控制力 |

3. **4B 之上收益骤减**：对拾贝任务圈，8B 相对 4B 的增益远小于 1.5B→4B 这一跳，且内存翻倍、速度减半——12GB 基线下无必要上探。
4. **参数量不是唯一标尺，代际同样重要**：Qwen3-1.7B（新代际）的指令遵循与格式稳定性大概率好过 Qwen2.5-1.5B（旧代际）——小模型天花板随训练数据质量上移。「低于 4B 不行」是当前代际的现实，不是物理定律；故留 1.7B 实测对照位，数据达标则多一档省电选择，不达标不影响主线。
5. **与既有拍板的衔接**：4B 起步依赖 §3.1a 设备基线（12GB RAM 从容承载 4B int4 峰值 3-4GB）；agent/工具调用编排即使 4B 仍不可靠，V4「固定工作流起步」的结论不因此改变。

### 3.2 分发与下载

- 复用 `lib/ai/model_manager.dart`「下载 → 校验 → 解压/落盘」链路与 `AsrModel` 目录结构模式；新增 `LlmModel` 目录条目。
- 下载源：Cloudflare R2 自托管（同 ASR R2 迁移待办，域名 `r2.oklhj.eu.org`）；Wi-Fi 限制 + 断点续传。
- 选包逻辑：启动下载前读 `Build.SOC_MODEL`（原生层回传），查映射表命中 NPU 包；未命中落通用包。
- 内存水位：Gemma3-1B 峰值 ~700MB–1.7GB，下载/初始化前检查 goodshare-mobile 富媒体内存水位机制。

### 3.3 注意事项

- QAIRT 运行库（`libQnnHtp*.so`）为 NPU 档依赖：二阶段评估「打进 APK vs 首启动下载」；MVP 通用包无此依赖。
- MTK 包 context 仅 1280 token：摘要任务需先按句切分（复用 `splitSentences`）做分段截断策略。
- NPU 包与 SoC 严格绑定，运行时校验失败自动落 GPU（LiteRT 内建 fallback），不置死信。

## 4. iOS 侧：FoundationModels

- iOS 26+ 的 `FoundationModels` framework 调系统内置 ~3B 模型，官方定位即「摘要 / 抽取 / 分类」，与本项目用例对口。
- 桥层只做三件事：① 可用性探测（`SystemLanguageModel.availability`：设备资格 + 地区门控）；② `LanguageModelSession` 调用与流式回传；③ 错误映射（guardrail 违规 / 语言不支持 / 上下文超限 → 友好降级文案）。
- **不下载任何模型**：模型管理、SoC 感知逻辑均只存在于 Android 桥。
- 内置 content-tagging adapter（打标签/实体抽取/主题检测）可用于关键词提取用例的 iOS 加成。
- 风险：**国内行货 iPhone 的 Apple Intelligence 可用性未确认**——若国行为主则 iOS 桥可能长期降级，届时再评估「补 LiteRT-LM Swift 通用包」双层方案。

## 5. 与队列 / 命令链路整合

- LLM 生成耗时长（首 token 0.3s + decode 数秒~数十秒）：**Job 化 + 手动触发**（沿用 OCR/转写手动化拍板口径，绝不自动入队）。
- 三个用例各对应一个命令（op 独立），全部走 ItemActionHandler 命令入口，动作层校验下沉（正文非空 + 引擎可用性预检——沿用翻译「入队前预检、不为必然无结果的任务让用户干等」）：

| 用例 | 命令 | 动作校验 | 产物落点 | 详情页入口 | MCP 工具 |
|---|---|---|---|---|---|
| 条目摘要 | `SummarizeCommand`（op=summarize） | 文本类条目且正文非空 | `summary_md`（与 human_md 并列，不覆盖） | 「摘要」按钮 | `summarize_item`（第 14 工具） |
| 关键词提取 | `ExtractTagsCommand`（op=extract_tags） | 文本类条目且正文非空 | `tags_json`（融入既有标签体系，可被筛选） | 「提取关键词」按钮 | `extract_tags`（第 15 工具） |
| 图片描述 | `DescribeImageCommand`（op=describe_image） | 仅 image 条目；需多模态模型包 | `machine_json` 描述字段 / `summary_md` | 「图片描述」按钮 | `describe_item`（第 16 工具） |

- iOS 侧关键词提取可用 FoundationModels 内置 content-tagging adapter（打标签/实体抽取）加成；摘要/描述走通用 `LanguageModelSession`。
- 图片描述的输入通道：Android 需 Gemma 多模态包（Gemma4-E2B / Gemma-3n 支持视觉输入，通用文本包不含视觉能力——选包时用多模态档，或文本/多模态双包并存）；iOS 系统 ~3B 模型原生支持图像输入（iOS 26 视觉能力随 FoundationModels 提供）。**实施顺序上排最末**：MVP 先做摘要 + 关键词（纯文本链路两端无歧义），图片描述待 Android 多模态包选型验证后再接。

- 队列超时：LLM 档超时上限单独放宽（建议 120s，或按输入 token 数动态），不与 OCR 20s / 管线 60s 共用。
- 产物一律与 human_md 并列、不覆盖原文（同翻译「译文并列、不覆盖」模式）；「静默成功=无产出」必须配状态反馈（既有两次踩坑的硬规则）。

## 6. 风险与遗留

| 风险 / 遗留 | 等级 | 缓解 |
|---|---|---|
| 首个用例未拍板（候选：条目摘要 / 关键词提取 / 图片描述） | ~~阻塞~~ **已定**：三个全做，实施顺序=摘要→关键词→图片描述（图片描述待多模态包验证） | 见 §5 用例表 |
| Gemma 再分发许可（自托管需核条款） | ~~中~~ **已缓解**：文本档定 Qwen2.5-1.5B（Apache-2.0，再分发宽松）；仅多模态档仍涉 Gemma 许可，待核 | 选 Qwen 系做文本档 |
| 国行 iPhone Apple Intelligence 可用性 | 中 | 待真机确认；不可用则评估 LiteRT-LM Swift 通用包补层 |
| 高通 NPU 包自编预期（Qwen 档） | 中 | **核实后降级**：SM8750 有 Gemma3-1B NPU 官方直下包（~658MB）；Qwen NPU 档仍需自编，二阶段处理 |
| MTK NPU 包真机稳定性（社区有 9300+ 闪退反馈） | 中 | 真机矩阵验证后再启用 NPU 档 |
| iOS 桥依赖 iOS 26+ | 低 | 老系统降级路径明示，同 Apple Intelligence 门控 |

## 7. 实施分期

1. **MVP**：Dart 接口 + Android 桥（Kotlin）+ 通用包分发（R2）+ **摘要 + 关键词提取**（命令/UI/MCP）+ iOS 桥（FoundationModels 探测与调用）。
2. **二阶段**：图片描述（Android 多模态包选型验证后）+ NPU 档（SM8750 自编/社区包 + MTK 包真机验证）+ QAIRT 库分发策略 + 用例扩展。
