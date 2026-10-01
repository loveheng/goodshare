---
status: active
updated: 2026-09-30
---

# docs/ 结构索引

> 工程文档纯结构索引（域 → 文档 → 一句话定位）。状态以各文档 frontmatter 为唯一事实源，此处不重复。

## product（产品 / 跨域需求）

- [product-requirements.md](product/product-requirements.md) — goodshare 全局 PRD：愿景、已确认架构决策、数据模型、五大模块需求、MCP 接口规范与分期路线图。
- [v2-requirements.md](product/v2-requirements.md) — V2 需求：离线双态 AI 重构（调用系统自带模型，零下载）+ 通用截图解析接口（OCR→LLM 归一截图）；多源健康接入已推迟 V3。

## architecture（架构）

- [overview.md](architecture/overview.md) — 架构总览：分层、关键决策（传输/鉴权/保活/桥接）、测试与已知边界。⚠️ 该文档使用非标准 `> status:` 块引用 frontmatter，待归一为 docs-spec。
- [human-ai-parity.md](architecture/human-ai-parity.md) — Human-AI 对称性（无头架构）：命令模式统一入参、防呆下沉、写后回状态、原子批量；主体×命令权限矩阵与试金石。

## guide（接入指南）

- [mcp-integration.md](guide/mcp-integration.md) — MCP 接入指南：手机端准备、USB/局域网连接、stdio 客户端配置、工具一览与安全提示。
- [self-update.md](guide/self-update.md) — 自更新手册：更新源配置、清单/下载/校验/安装流程与 Shorebird 受阻记录。⚠️ 同上，frontmatter 待归一。

## design（UI 设计规范）

- [ui-spec.md](design/ui-spec.md) — UI 设计规范：Material You/M3 视觉系统、5 底 tab + FAB 导航、页面清单、设置树、组件库与双态呈现；配套约束见项目 skill `goodshare-ui`。
- [detail-two-zone.md](design/detail-two-zone.md) — 详情页两区改版与区块能力平台设计：公共区/灵感区分工、区块能力分发（ContentCapability 自声明 + CapabilityChain 任务链）、单卡链式能力卡（不嵌套）、分享分流（截图 PNG / PDF 兜底）。
- [asr-subtitle.md](design/asr-subtitle.md) — 音频转写与字幕生成设计：VAD 分段取时间戳的可选下载资源 `silero-vad-v5`、文本与 SRT/VTT 双产物、无 VAD 时降级为纯文本的门控；§8 为端侧翻译层（引擎接口/路由/双语字幕三模式/译文存储与命令）。
- [ocr-cn-adaptation.md](design/ocr-cn-adaptation.md) — 中文 OCR 适配设计。
- [ai-capabilities-overview.md](design/ai-capabilities-overview.md) — AI 能力总览。
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
- [rich-text-component.md](design/rich-text-component.md) — 富文本组件分层与结构化编辑设计：ContentBody 公共组件（sliver/inline 双面）、三层架构（规则层 RichDocument / 呈现层 / 调用层）、抹去 App 内 Markdown 用户暴露（结构化块编辑替代源码编辑，不留逃生舱）、私有块类型三出口护栏、视觉元数据前置（尺寸/OG/主色调，mymind 吸收）。
- [rich-text-media.md](design/rich-text-media.md) — 富文本行内媒体块设计：Image/Audio/Video 三块类型的三出口语法、ContentBody 呈现（AspectRatio 占位/播放条/封面播放卡）、编辑态直接操纵、插入链路分期（音频先行，图片/视频 V2）；顶级媒体与行内媒体的边界划分。

## engineering（工程规范）

- [ai-dev-spec.md](engineering/ai-dev-spec.md) — AI 协作开发规范：人+AI 双操作者的可判定约束——架构/编码/跨平台规约、AI 操作者专章（身份权限/写路径/错误/并发）、反模式与「明确不做」清单、规范自身维护协议。
