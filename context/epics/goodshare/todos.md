---
memo: todos
format: v3
epic: goodshare
---

# goodshare · 域内待办
- [ ] [2026-10-07] (功能)(候)(层:L3)(重:中) 列表语法增强批次（依附解析器责任链稳固后动工，**两条同批落地、勿分开做**）：①**裸待办并入前序列表**——`- item1` 紧跟 `[ ] task2` 现被切成两个 ListBlock，连贯清单被截断；**原因**=旧 `_parseBlocks` 把裸待办行建成独立 `ListBlock(ordered:false)` 分支（排在媒体行之后），与列表聚合（只吃 `_bullet`/`_ordered`）不互通；②**多行列表项**——缩进延续行（`  这是续行`）现不落入列表项、降级为独立段落；**原因**=`ListItem.inline` 为单行 `List<InlineNode>`，模型不表达多行项。两条均于 2026-10-07 `_parseBlocks` 责任链重构（LineReader + BlockSyntax）行为对账中确认为**旧版既有行为、非本次回归**，按「本轮纯架构解耦、语法增强留待下轮」协议显式搁置。**修改后影响**：①合并后 `serializeBlocks` 对同类输入由「两块（空行拼接）」变为「单块连续列表行」；②`ListItem` 扩多行承载 + `serializeBlock` 同步输出延续行缩进；两者都会改变既有 parse→serialize→parse 的**字符串产出**（往返仍须自稳定，但**快照类单测基线需重写**），`scanTodoTexts`（待办 hash 口径）、`inlineSpansOf`（样式 run 投影）、凹槽勾选态渲染须一并回归 (src: ai, 块解析器重构行为对账)
- [ ] [2026-10-04] (风险)(层:L1)(重:中) 保险箱视觉防线接线：`SecureWindow` 类已存在但 lib 内 **0 调用方**（FLAG_SECURE 未接线）——接线时一并做三件事：①FLAG_SECURE 按视图判定（保险箱视图 + vaultContext 详情层数，enter/exitVaultDetail 计数接口已备）；②Recents 多任务卡片缩略图替换鹦鹉螺品牌图（非模糊，ui-spec §4.4 隐私纵深拍板）；③保险箱内复制打 `EXTRA_IS_SENSITIVE` 剪贴板敏感标记（Android 13+，同节）。规范 SSOT：ui-spec §4.4 (src: ui-spec 过时点核对 + 用户拍板隐私纵深)
- [ ] [2026-10-03] (功能)(层:L3)(重:中) AI 写入归一层：`lib/action/` 命令入口对格式全集外语法做**语义映射**而非剥壳，映射即降级须 R1 note 告知；v6 收窄——表格/高亮/删除线/自动链接已收编 GFM 全量不再映射，仅罕见结构（脚注等）走映射；MCP 文本写入工具的前置依赖；MCP 工具描述同步声明支持全集；原则 SSOT：rich-text-gfm.md §2 (src: 用户拍板, AI 写入格式讨论)
- [ ] [2026-10-03] (功能)(层:L3)(重:中) 解析器 GFM 全量收编：`rich_text.dart` 加 `~~删除~~`/`==高亮==` 行内分组（strikethrough/highlight 枚举+三处同源）+ 表格块级分支（TableBlock + Table/DataTable 卡片渲染，窄屏适配）+ 自动链接 run 化 + 围栏代码块语言徽标；依附转盘 epic 动工时一并做，勿单独排期 (src: 用户拍板「GitHub md 全都要」, 知识收集场景修正)
- [ ] [2026-10-02] (功能)(层:L4)(重:轻) 回收站（最近删除）页接入长按批量选择模式：动作集「恢复/彻底删除」，彻底删除需强二次确认；长按批量选择模式 epic 样板验收后另排 (src: 用户拍板)
- [ ] [2026-10-02] (风险)(层:L0)(重:中) VAD `bufferSizeInSeconds=100` 对长音源溢出：>100s 音频触发 circular buffer overflow 告警（sherpa 报「数据未丢失」，桌面复现确认），与 2026-09-28 长视频 WAV 临时文件/超时风险条目同属长视频待验族，落地时一并实测 (src: ai, 字幕管线深度评估)
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
- [ ] [2026-10-05] (功能)(层:L1)(重:轻) Clip 无 MCP 工具（待拍板）：本仓 Clip=视频切片（startMs/endMs+extract/transcribe/summary），非网页剪藏——外部 Agent 知识输入已有 collect/add_item 承载；如做须按「AI 提议视频区间→人类确认」独立设计（标记≠处理拍板）。Human-AI 对称其余三项已闭环（2026-10-05：Reprocess/Reclassify 转正回 ⋯ 面板、RemoveFromWorkspace 转正批处理条、supportedOps 摘 set_ai_*） (src: ai, 全页面闭环盘点)
- [ ] [2026-10-03] (功能)(候)(层:L3)(重:重) 冷门音视频格式云端处理体系：ffmpeg 替换为平台原生（MediaCodec/AVFoundation）后解不了的边缘格式（ac3/wma 等），**后续走云端体系处理**；现阶段一律降级提示「格式不支持」，不做静默失败。依附：ffmpeg→原生替换立项（P2 端侧转码管线落地时按此口径实现降级文案），勿单独排期 (src: 用户拍板)
- [ ] [2026-10-02] (功能)(降级)(层:L4)(重:重) 工具箱收敛+预置链实施：详情页单一「工具」胶囊→工具箱 BottomSheet（预置链置顶+状态行，底栏 5 项恒定）；预置链「提取并翻译」（image=ocr→translate、audio/video=transcribe→translate，产品固定）；工程大头=TranslateCommand 产物化（译文写回 translated_md）+ 队列链式触发。**2026-10-02 降级**：加工主体拍板 MCP 优先，人类端只留按需轻量入口，排序殿后；预置内容建议补「转写并摘要」「OCR 并打标」 (src: ui-spec §4.3/§4.4, 2026-09-30 拍板)
- [ ] [2026-10-02] (功能)(暂缓)(层:L4)(重:轻) 图片标注吸附数值微显（image-markup.md §5 标「可选」）：拖锚点时锚点旁浮出小数值（45°、宽 320px 等）、松手即隐——纯精度增强非必做项，用户已拍板**暂缓**（2026-10-02），真机验收反馈有需要再排期 (src: ai, 用户拍板暂缓)
- [ ] [2026-10-02] (功能)(候)(层:L4)(重:中) 视频多段剪辑批次模型 + 音频剪辑复用预留：轻剪辑页一次进入=一个工作批次（区间逐个「收进本次」入暂存架，scrubber 色带防重叠、>10 段软提示，完成时逐区间过门槛、默认产出 N 个独立条目可选合并）；音频**不建剪辑页、不挂入口**（宽约束拦不到人+无截片段场景），仅架构预留（TrimAction 泛化 mediaType + 媒体无关壳，未来零返工接入）。**说明：交互设计已落档 docs/design/video-trim.md §1/§5.1，本条为实现候选项——轻剪辑页动工时一并实现，勿单独排期** (src: ai, 交互评估对话)
