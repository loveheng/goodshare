---
memo: todos
format: v3
---

# 待办列表

<!-- 格式约定 v3 · SSOT = 全局 skill memo-collector（~/.agents/skills/memo-collector/SKILL.md §0）
- 每条：`- [ ] [YYYY-MM-DD] (类型)[(状态)?](层:Ln)?(重:轻/中/重)? 标题 (src: ...)`
- 状态枚举：降级 / 暂缓 / 候（机器可解析，勿用 emoji）
- 层 L0 引擎 · L1 平台 · L2 数据 · L3 加工 · L4 UI；重 轻/中/重
- 版本绑定项(V3/V4)可省日期，保留 [ ]
- 长期行为：每会话结束按 @todo-groom 仪式归并去重；每周一自动化巡检防回潮
-->

## goodshare

- [ ] [2026-10-02] (风险)(层:L0)(重:中) VAD `bufferSizeInSeconds=100` 对长音源溢出：>100s 音频触发 circular buffer overflow 告警（sherpa 报「数据未丢失」，桌面复现确认），与 2026-09-28 长视频 WAV 临时文件/超时风险条目同属长视频待验族，落地时一并实测 (src: ai, 字幕管线深度评估)
- [ ] [2026-10-02] (功能)(层:L3)(重:中) document 归一化接线：`taskActionFor(document)` 由 null 接上队列（html/plain/pdf 三 normalizer 已建，接口位已存在），文件类分享自动出可读正文；content-pipeline §9 既有 Phase，半天级 (src: ai, app-share 链路评估)
- [ ] [2026-10-02] (功能)(层:L1)(重:中) 图文同分享文案修复：receive_sharing_intent 的 toJsonObject 只取 uri 丢文案（小红书/微博类图文帖源头发内容损失），需 fork 插件或自写 intent 解析补齐；自 misc 低优升级（app 分享为主的使用方式） (src: ai, app-share 链路评估)
- [ ] [2026-10-01] (功能)(层:L4)(重:重) 轻剪辑独立页面（区间选择器）：超门槛拦截后一键进入，独立路由页 + 预留 AI 调用路径（AI 可对用户视频发起区间操作）；唯一动作「切」：双端 scrubber 拖动粗定位 + 按住慢放精调（静止按下 200-250ms 触发，回退 1-1.5s 含反应补偿，0.5x 起步，拖动中停顿 500ms 触发且不回退）+ 抬手定点即正速续播；包含式补偿（in 点自动前移 0.3-0.5s / out 点后延 0.3-0.5s），北极星一次剪对率 ≥85%；不做字幕/变速/拼接/逐帧按钮；产物=原件时间轴裁剪原样副本（转码只裁时间不压画质，原文件不动），重新过门槛校验后进收集链路 (src: ai, 交互评估对话)
- [ ] [2026-09-28] (风险)(层:L3)(重:中) 视频字幕转写：长视频 16k 单声道 WAV 临时文件约 115MB/小时落 systemTemp，且既有 10 分钟超时策略未覆盖视频场景，落地时评估分段/清理与超时上限 (src: ai, design-docs-review)
- [ ] [2026-09-28] (优化)(层:L2)(重:轻) 图片列表「有标注」角标按 annotations JSON 存在性判定属文件 stat IO，列表滚动路径需异步缓存避免主线程阻塞 (src: ai, design-docs-review)
- [ ] [2026-09-28] (功能)(层:L0)(重:中) 真离线翻译引擎（OPUS-MT / 自托管小模型）：翻译层骨架已就位，实现 `TranslationEngine` 并注册进 `TranslationRouter` 即可接棒——国内 ML Kit 语言包不可达时才有译文产出 (src: ai, translation-skeleton)
- [ ] [2026-09-28] (功能)(层:L0)(重:轻) iOS Apple Translation framework 引擎实现（骨架期 Android 独享，iOS 恒落 Noop） (src: ai, translation-skeleton)
- [ ] [2026-09-28] (优化)(层:L0)(重:轻) 源语识别替换启发式：当前 `detectSourceLanguage` 为字符分布启发式（已标 DEGRADE），接入语言识别能力后替换，接口不变 (src: ai, translation-skeleton)
- [ ] [2026-09-30] (功能)(层:L2)(重:中) 【Epic】超长文本管线（Phase 2→4）：①归一化分块——按标题层级 + 500-token 滑动窗口切分 `human_md`，`item_embeddings.chunk_index` 已预留，先补生产侧切块；②解析 Isolate 异步化——`MarkdownSubsetParser` 移出主线程，30k/60k 字符桌面实测 18/19ms，真机 AOT 以实测为准定阈值并覆盖编辑器保存 serialize；③向量引擎落地 + RAG/Map-Reduce 摘要——嵌入生产者写 `item_embeddings` 分块向量，超长摘要先分块再归并，解 Context 溢出。分步推进 (src: content-pipeline long-text, rich-text-media §8)
- [ ] [2026-10-01] (风险)(层:L4)(重:轻) 文本块 AI 入口改划词菜单后可发现性下降（无常驻图标、须先划词）：真机验收触达率与「命中块是否正确」；若不足，优先叠加「视口焦点块单 ✨」（复用同一 BlockAnchorStore），不复活全量常驻图标 (src: ai, 用户拍板)
- [ ] [2026-10-01] (优化)(层:L4)(重:中) 详情页操作区重划真机验收：底栏 编辑/工作区/分享 三项够不够用、删除移入 ⋯ 菜单后路径是否变长（危险项深度 +1）、长按标题切机器态有无误触 (src: ai, 用户拍板)
- [ ] [2026-10-01] (功能)(层:L3)(重:中) 视频主体条目（新 item_type，与附件视频姊妹）：入口分叉「添加附件 vs 视频条目」，主体态设宽门槛非零（拟 ≤10min / ≤500MB，待定），超限拦截拒收；门槛内不干预大小（无提示），工程防线后移：封面/转写 Job 化后台、播放懒加载、大文件三态兜底；不做「有无配文」隐式推断主体 (src: ai, 交互评估对话)
- [ ] [2026-09-30] (功能)(层:L3)(重:中) 行内媒体块 V2 插入链路：图片相册选取+压缩+OSS 上传（产出 https url 写 ImageBlock，「📷」按钮）；音频/视频本地行内插入（依赖多端资产同步机制）；视频封面提取（顶级+行内，引入 video_thumbnail 类依赖走 Job 化） (src: rich-text-media §5)

- [x] [2026-10-02] (功能)(层:L4)(重:中) 编辑态媒体块精细化（图/音/视频）：`_EditBody` 按块类型分流——媒体块渲染 `MediaBlockEditor`（预览+标签编辑+替换媒体），其余块保持 `TextField` 不变；替换媒体走新增 `ReplaceMediaOp(index, newUrl)` 经 `EditSession.apply`（事务一致性：取消即整体回滚，杜绝「独立 Command 绕过 Session」造成的脏状态分裂）。护栏：①`EditBlock` 加稳定 `id` 作 `ValueKey` 防结构变更后 Element 错位复用；②`MediaBlockEditor` 零本地私有状态、可视状态 100% 派生自 `blocks[i]`，替换成功经回调上抛顶层 `session.apply(ReplaceMediaOp)` 由重建驱动预览。标签编辑仍走 `CommitTextOp`/`rebuildBlock`（src: devlog 2026-10-02 后续迭代项②, 用户拍板 ReplaceMediaOp 方案）

## goodshare · 暂缓/候（已移出活跃区，状态结构化）

- [ ] [2026-10-02] (功能)(降级)(层:L4)(重:重) 工具箱收敛+预置链实施：详情页单一「工具」胶囊→工具箱 BottomSheet（预置链置顶+状态行，底栏 5 项恒定）；预置链「提取并翻译」（image=ocr→translate、audio/video=transcribe→translate，产品固定）；工程大头=TranslateCommand 产物化（译文写回 translated_md）+ 队列链式触发。**2026-10-02 降级**：加工主体拍板 MCP 优先，人类端只留按需轻量入口，排序殿后；预置内容建议补「转写并摘要」「OCR 并打标」 (src: ui-spec §4.3/§4.4, 2026-09-30 拍板)
- [ ] [2026-10-02] (功能)(暂缓)(层:L4)(重:轻) 图片标注吸附数值微显（image-markup.md §5 标「可选」）：拖锚点时锚点旁浮出小数值（45°、宽 320px 等）、松手即隐——纯精度增强非必做项，用户已拍板**暂缓**（2026-10-02），真机验收反馈有需要再排期 (src: ai, 用户拍板暂缓)
- [ ] [2026-10-02] (功能)(候)(层:L4)(重:中) 视频多段剪辑批次模型 + 音频剪辑复用预留：轻剪辑页一次进入=一个工作批次（区间逐个「收进本次」入暂存架，scrubber 色带防重叠、>10 段软提示，完成时逐区间过门槛、默认产出 N 个独立条目可选合并）；音频**不建剪辑页、不挂入口**（宽约束拦不到人+无截片段场景），仅架构预留（TrimAction 泛化 mediaType + 媒体无关壳，未来零返工接入）。**说明：交互设计已落档 docs/design/video-trim.md §1/§5.1，本条为实现候选项——轻剪辑页动工时一并实现，勿单独排期** (src: ai, 交互评估对话)

## misc

- [ ] [2026-10-02] (测试)(层:L0)(重:中) 端侧 LLM 4B 档真机实测（定 R1/R3 实现深度）：Qwen3-4B/3B int4 GPU 包在 8 Gen 3（OnePlus 13R）跑分（decode tk/s、内存峰值、发热）+ OCR 修正小样评估（命中率/误改率，含数字保护校验）；设备基线=8 Gen 3/天玑 9400 + 12GB（on-device-llm.md §3.1a） (src: ai, 4B/NPU 讨论链拍板)
- [ ] (功能)(层:L3)(重:重) app 内 agent/自动化引擎（**已划 V4**，2026-10-02 拍板）：app 兼作 MCP host（第四 `CommandActor.agent` 槽位）+ 对外连其他本地 MCP 服务（日历等）；起步=固定工作流引擎（确定性管道+局部 LLM 判断点，离线可靠），通用 LLM agent 后置（端侧 1.5B 多步调用可靠性不足/云 API 破坏离线承诺）；价值=住进手机生命周期（充电/后台/定时，复用 AiQueueService 基建），补桌面 host 不在线空档。硬纪律：独立成层、业务层零耦合，其他 app 只出现在工作流配置数据里。前置：V2 素材加工（event.v1 等）+ V3 分域授权。SSOT：PRD §9 V4 行
- [ ] (功能)(层:L1)(重:重) MCP 客户端分域授权（**已划 V3**，2026-10-02 拍板「V2 先把加工链路走通」）：客户端注册表（按客户端发 token）+ 三维权限域——工具域（tools/list 按 scope 过滤）、数据域（类型/工作区白名单，沿用 Vault 排除）、内容形态（raw/processed 二档，processed 与 V2 打码层协同）；默认新客户端=只读+processed+Vault 排除，预设 2-3 档避免细粒度矩阵；设置页「接入客户端」管理区（生成/吊销/选档）。方案评估见 2026-10-02 会话，SSOT：PRD §9 V3 行
- [ ] (功能)(层:L1)(重:重) iOS 端适配：需 macOS 构建；验证 receive_sharing_intent iOS 行为与前台服务限制（预期「app 前台时 MCP 可用」）
- [ ] (功能)(层:L1)(重:重) 鸿蒙 OHOS 适配：flutter_flutter fork + receive_sharing_intent/flutter_foreground_task 插件 ohos 化
- [ ] (功能)(层:L1)(重:中) ACTION_PROCESS_TEXT：任意 app 选中文本一键收集（需自定义平台通道）
- [ ] (功能)(层:L4)(重:中) 标签管理（编辑/筛选）；数据量大后评估 FTS 全文索引替换 LIKE
- [ ] (风险)(层:L1)(重:中) 国产 ROM 省电策略可能杀前台服务：真机验证华为/小米等存活情况，必要时引导加白名单
- [x] (优化)(层:L4)(重:轻) 自定义 app 图标：flutter_launcher_icons 已接入（pubspec.yaml），源图 assets/icon/app_icon.png（1024²），生成 Android ic_launcher（mipmap 五套）+ iOS AppIcon（remove_alpha_ios: true，规避 App Store alpha 限制）
- [ ] (功能)(层:L4)(重:轻) 启动页 splash 自定义（自「图标与启动页」拆出，待办）
- [ ] (文档)(层:L1)(重:轻) release 签名配置文档化（keytool + signingConfig）
- [ ] (功能)(层:L1)(重:中) Shorebird 接入收尾：本机被两件事挡住——官方安装脚本 404（改用 GitHub release 包手动装）+ api.shorebird.dev TLS 握手失败（需代理）；用户侧网络可用时按 docs/guide/self-update.md §2 走 shorebird init/login/release
- [ ] (风险)(层:L1)(重:轻) 自更新 release 包当前用 debug 签名（模板默认），正式分发前配置 release keystore 并在 shorebird 流程中统一
- [ ] (优化)(层:L4)(重:轻) 更新页增加「强制最低版本」逻辑（清单 minVersionCode，低于即全屏提示必须升级）
- [ ] (优化)(暂缓)(层:L0)(重:轻) ASR 模型源迁移 R2 + 换新版（低优先/暂缓）：模型改为 csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09（model.int8.onnx 237,115,547 / tokens.txt 315,894）+ csukuangfj/sherpa-onnx-paraformer-zh-int8-2025-10-07（238,429,929 / 75,756，川渝方言版）；分发方式改为 Cloudflare R2 自托管 tar.gz 包（域名 https://r2.oklhj.eu.org，包的完整 URL 待用户提供），lib/ai/asr_model.dart 改「单包 + entries」结构、lib/ai/model_manager.dart 改下载→解压→逐文件校验→删包（需加 archive 依赖）。未决：是否保留 whisper-small 多语种档、方言版是否契合场景（否则换 paraformer-zh-2024-03-09，227,330,205 / 75,354）。现状可用（hf-mirror 三档已能下载），无需紧急处理
