---
status: active
updated: 2026-10-03
---

# docs/ 结构索引

> 工程文档纯结构索引（域 → 文档 → 一句话定位）。状态以各文档 frontmatter 为唯一事实源，此处不重复。

## product（产品 / 跨域需求）

- [product-requirements.md](product/product-requirements.md) — goodshare 全局 PRD：愿景、已确认架构决策、数据模型、五大模块需求、MCP 接口规范与分期路线图。
- [v2-requirements.md](product/v2-requirements.md) — V2 需求收敛版（只含未完成项）：摄入自动双态重构管线、隐私打码、截图解析、便签 AI 增强、温控节流；技术路线已对齐 LiteRT-LM 端侧 LLM。

## architecture（架构）

- [overview.md](architecture/overview.md) — 架构总览：分层、关键决策（传输/鉴权/保活/桥接）、测试与已知边界。⚠️ 该文档使用非标准 `> status:` 块引用 frontmatter，待归一为 docs-spec。
- [human-ai-parity.md](architecture/human-ai-parity.md) — Human-AI 对称性（无头架构）：命令模式统一入参、防呆下沉、写后回状态、原子批量；主体×命令权限矩阵与试金石。

## guide（接入指南）

- [mcp-integration.md](guide/mcp-integration.md) — MCP 接入指南：手机端准备、USB/局域网连接、stdio 客户端配置、工具一览与安全提示。
- [self-update.md](guide/self-update.md) — 自更新手册：更新源配置、清单/下载/校验/安装流程与 Shorebird 受阻记录。⚠️ 同上，frontmatter 待归一。

## design（UI 设计规范）

- [ui-spec.md](design/ui-spec.md) — UI 设计规范：Material You/M3 视觉系统、5 底 tab + FAB 导航、页面清单、设置树、组件库与双态呈现；配套约束见项目 skill `goodshare-ui`。
- [workspace.md](design/workspace.md) — 工作区管理闭环交互设计稿（active 2026-10-05）：删除守门与清空链路（删工作区≠删内容语义红线、列表层长按单删不做多选、非空守门 B 快捷删「保留内容并删除」、ackNonEmpty 仅 ui actor 的动作层同守门、重命名复用整页创建表单）；「移出本工作区」批量转正为独立候选。
- [card-batch-selection.md](design/card-batch-selection.md) — 卡片长按批量选择模式方案蓝本（draft 未实现）：长按进选择模式 + 底部操作栏取代导航、四动作（置顶/工作区/保险箱/删除）声明式配置、置顶全链路（pinned_at + PinCommand + MCP set_pin）、四层抽象（词汇表/执行全共享，呈现分形态：列表选择栏/详情底栏/⋯面板）、整体落地切片。
- [block-format-input.md](design/block-format-input.md) — 编辑态格式输入方案蓝本（draft 未实现）：键盘工具条「格式」按钮先选后打、块级标题/正文真所见即所得、行内加粗/斜体/下划线自研样式化编辑层（无 md 标记可见，不换编辑器）、`<u>` 语法扩展。
- [quick-note-format-dial.md](design/quick-note-format-dial.md) — 速记格式转盘交互设计稿（draft 待过稿）：可收起三级径向盘（一级圆钮/二级三分类/三级联动）、松手即选、激活角标外显；仅转盘输入交互，渲染/GFM 收编拆至 rich-text-gfm.md。
- [rich-text-gfm.md](design/rich-text-gfm.md) — 富文本 GFM 渲染收编与 AI 写入原则设计稿（draft 待拍板）：AI 写入三层处理链（引导/映射/R1 告知）、格式全量镜像对照表（与 rich_text.dart 同源）、GFM 收编语法实现契约（粗斜体/删除线/高亮/表格/自动链接/行内码防回溯方案）与渲染标准；自 quick-note-format-dial.md §3-§4 拆出。
- [ai-writeback-revert.md](design/ai-writeback-revert.md) — AI 写回可逆与用户接管设计稿（active 2026-10-04）：单基线快照三件套（`human_md_baseline` 锚点 + `doc_meta_json.ai_session_state` 短枚举 + `ai_revisions` 有界日志表）、AI_PENDING/RESTORED/CLOSED 状态机、1.5s settle 接管判定（生命周期强制 flush + 显式按钮取消计时器的竞态防护）、只读 Inline Diff 与接管 Toast / 极简历史面板。与 rich-text-gfm.md 互补——那稿管「写入质量」，本稿管「写入后的可控性」。
- [note-editor-unification.md](design/note-editor-unification.md) — 编辑器统一（active 2026-10-03）：详情编辑切换到速记作曲器形态（NoteComposerEditor 唯一编辑器）、human_md→草稿行转换（noteMdToDraftRows 字面保留裁决）、媒体替换钩子与 EditSession/FormatToolbar 废弃口径。
- [quick-note-draft.md](design/quick-note-draft.md) — 速记条草稿持久化方案蓝本（draft 未实现）：QuickNoteBar 接入既有 drafts 表/DraftController 基建（防抖+退后台 flush+结构变更即写），static 内存草稿退役，进程被杀重开原样恢复（含媒体段）。
- [detail-visual-hierarchy.md](design/detail-visual-hierarchy.md) — 详情页视觉层级方案蓝本（draft 未实现）：灵感区分区头统一换 SectionLegendCard 骑框签（消两套分区语言）、区块间距调档、便签标题槽显示规则（无标题显创建时间绝对格式、用户标题优先、不回写 human_title）；水平留白丢失 bug 已修复（空 SliverPadding 死代码）。
- [detail-two-zone.md](design/detail-two-zone.md) — 详情页两区改版与区块能力平台设计：公共区/灵感区分工、区块能力分发（ContentCapability 自声明 + CapabilityChain 任务链）、单卡链式能力卡（不嵌套）、分享分流（截图 PNG / PDF 兜底）。
- [asr-subtitle.md](design/asr-subtitle.md) — 音频转写与字幕生成设计：VAD 分段取时间戳的可选下载资源 `silero-vad-v5`、文本与 SRT/VTT 双产物、无 VAD 时降级为纯文本的门控；§8 为端侧翻译层（引擎接口/路由/双语字幕三模式/译文存储与命令）。
- [ocr-cn-adaptation.md](design/ocr-cn-adaptation.md) — 中文 OCR 适配设计。
- [ai-capabilities-overview.md](design/ai-capabilities-overview.md) — AI 能力总览。
- [block-artifact-workflow.md](design/block-artifact-workflow.md) — 块附件通道与工作流式三级能力页：行内媒体块 AI 能力（block_artifacts 派生表 schema v21、block_* 队列动作串、手动即授权门禁豁免）、WorkflowSpec 声明式能力编排（一步双产物/锚点切换/应用导出动词）、三级页工作流轨重设计（结构保留只换芯）。
- [on-device-llm.md](design/on-device-llm.md) — 端侧 LLM 设计：LiteRT-LM（Android，SoC 感知 NPU/GPU/CPU 模型包）+ FoundationModels（iOS 系统模型零下载）双端分治、模型分发与队列/命令整合。
- [image-annotation.md](design/image-annotation.md) — 图片标注设计（元数据层架构 SSOT：overlay 不改像素、annotations JSON 随条目走、原图只读；交互层已改版为对象化标注，口径见 image-markup.md）。
- [image-markup.md](design/image-markup.md) — 图片标注交互改版（对象化标注）：操作与呈现分离（标注列表主入口 + 画布微调台）、两级选择状态机、锚点精度栈（loupe/吸附线/触觉 tick）、画布恒定、文字不合成、首发工具集（箭头/圆角矩形/文字/序号+笔迹候选）、横屏推荐策略。
- [s3-backup.md](design/s3-backup.md) — S3 备份与恢复设计：dio+crypto 手写 SigV4 薄封装 + `VACUUM INTO` DB 快照、固定包结构与 manifest 提交标记、附件增量跳过、Vault 排除与全量替换恢复语义；对象存储 Server 明确不做（桌面精修走 MCP）。
- [vector-embeddings.md](design/vector-embeddings.md) — 向量检索与派生数据策略：item_embeddings 独立派生表（schema v9，不进备份、恢复即清、可全量重算）、int8 量化约定、检索路径分档（暴力余弦 → sqlite-vec）。
- [scheduling-tasks.md](design/scheduling-tasks.md) — 任务编排与调度评估：暂缓引入自组装编排器的结论与重开触发条件、大参数处理三铁律（只传引用/快照截断/产物分级即弃）。
- [video-clips.md](design/video-clips.md) — 视频切片（关键区间）设计：clips_json 附属记录（schema v10）、clip:* 队列任务三段链（ffmpeg 提区间音轨→端侧 ASR→LLM 摘要）、区间结果独立回写通道不覆盖整片产物、视频源文件不进备份；打点 BottomSheet UI 已退役（逻辑保留，交互收编轻剪辑页）。
- [video-trim.md](design/video-trim.md) — 轻剪辑页（视频区间选择器）：全 App 唯一选区间交互面（双端 scrubber + 按住慢放定点，含反应补偿参数标定），纯交互壳无数据归属；双出口（切出原样副本收进 / 标记转写复用 video-clips 链路）；TrimVideoAction 命令层无头对称预留 AI 调用路径。
- [video-subject.md](design/video-subject.md) — 视频主体条目（宽门槛准入）：新 item_type 入口分叉、两级门槛矩阵（≤10min/≤500MB 拦截式）、100MB 通用确认对视频作废、门槛=备份准入线（收进来=系统认可=进备份）、门槛内工程防线后移。
- [note-video.md](design/note-video.md) — 便签内嵌视频（附件态）：相册选择主路径+相机直拍次路径、附件态门槛（60s/5min/50-100MB，用户只感知时长）、封面卡懒加载与内存纪律、SAF 可持久化 URI 待实测前置依赖。
- [content-pipeline.md](design/content-pipeline.md) — 内容管线设计：富文本归一化（lib/doc/ 接口+Registry，html/pdf/plain → Markdown 子集）与文件引用策略（引用原件不复制、attach_state 状态机、分享后弹提醒+快捷导入）；详情页「文档形态」改造与自建富文本渲染器（弃 flutter_markdown_plus）的 SSOT。
- [attach-ownership.md](design/attach-ownership.md) — 附件持有机制说明：导入=复制/分享=引用的语义总表、persist 授权决定可达性的 Android 链路、迁移兜底、按类型分档（纯文本释放 / PDF 一律持有作事实来源 / 媒体引用+迁移）、范围拍板（不考虑微信/QQ 源）与 iOS 缺口预留位。
- [rich-text-component.md](design/rich-text-component.md) — 富文本组件分层与结构化编辑设计：ContentBody 公共组件（sliver/inline 双面）、三层架构（规则层 RichDocument / 呈现层 / 调用层）、抹去 App 内 Markdown 用户暴露（结构化块编辑替代源码编辑，不留逃生舱）、私有块类型三出口护栏、视觉元数据前置（尺寸/OG/主色调，mymind 吸收）。
- [rich-text-media.md](design/rich-text-media.md) — 富文本行内媒体块设计：Image/Audio/Video 三块类型的三出口语法、ContentBody 呈现（AspectRatio 占位/播放条/封面播放卡）、编辑态直接操纵、插入链路分期（音频先行，图片/视频 V2）；顶级媒体与行内媒体的边界划分。
- [md-template-schema.md](design/md-template-schema.md) — Markdown 模板文件格式约定（V2 资产协议）：Front Matter Schema + `{{slot}}` 占位符、解析容忍度基线（不崩溃不乱码）、存储边界（documents/templates/ 不进条目、进备份）；渲染/执行见 agent-workflow-skill.md。
- [agent-workflow-skill.md](design/agent-workflow-skill.md) — V4 Agent 工作流与 Skill 体系：模板（用户视角）/Skill（AI 视角）一体、SlotSpan 双向渲染 AST 扩展、HCI 四对策（零阻力入口/先猜后问/生命周期/延迟透明化）、执行引擎归 AI 客户端、save_skill 高权限门控。

## engineering（工程规范）

- [ai-dev-spec.md](engineering/ai-dev-spec.md) — AI 协作开发规范：人+AI 双操作者的可判定约束——架构/编码/跨平台规约、AI 操作者专章（身份权限/写路径/错误/并发）、反模式与「明确不做」清单、规范自身维护协议。
