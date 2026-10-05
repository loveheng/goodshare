---
name: goodshare-index
description: 拾贝 goodshare（Flutter 分享收集器+MCP 服务）的「功能 → 代码落点 + 文档落点」归属索引。改分享接收、存储、MCP 工具/协议、桥接器、前台保活前先查本表定位，避免全仓扫描。
---

# goodshare 功能索引

机制/格式/维护协议见全局 skill `project-index`。

## 用法

1. 按归属表定位领域。
2. 以该路径为 include_pattern 限定搜索展开——展开结果只用于当前任务，禁止写回本表。
3. 定位不到时才全量 grep / find_path。

## 归属表

| 领域 | 覆盖功能 | 代码落点（锚点 · 展开命令） | 文档落点 |
|---|---|---|---|
| 采集 | 系统分享接收、文本/链接归一、附件落盘 | `lib/share/`（`find lib/share -type f`） | docs/architecture/overview.md |
| 存储 | sqflite 表结构、Repository 查询/删除 | `lib/data/`（`find lib/data -type f`） | docs/architecture/overview.md |
| 动作层 | UI/MCP/AI 管线共用写路径：命令协议（`ItemCommand`/`CommandResult`/`ActionException`/`CommandActor`）、`ItemActionHandler.execute`（编辑/软删/重分类/set_vault/reprocess/unlock_edit/collect/restore/批量事务）、machine_json Schema 校验 | `lib/action/`（`find lib/action -type f`） | docs/architecture/human-ai-parity.md、docs/product/product-requirements.md（§7 关键约束） |
| AI 管线 | AiReconstructor 接口/占位实现/Registry、ai_task_queue 消费者、**端侧翻译层**（`translation.dart`引擎接口/路由/句子切分、`translation_mlkit.dart`、`translate_reconstructor.dart`、`language_codes.dart` 语言码 SSOT）、**离线转写+字幕**（`asr.dart` Sherpa 引擎+VAD cue、`asr_reconstructor.dart`、`asr_model.dart` 三档模型目录、`subtitle.dart` AsrCue/SRT·VTT 序列化/SubtitleStore）、**端侧 LLM**（`llm.dart` OnDeviceLlmEngine 接口/MethodChannel 桥、`llm_model.dart` 模型目录+SoC 感知、`llm_model_manager.dart` 下载管理、`llm_reconstructor.dart` 摘要/关键词消费者；原生桥 `android/.../LlmBridge.kt`（LiteRT-LM Kotlin 真推理，2026-09-29）+ `ios/Runner/LlmBridge.swift`（FoundationModels 门控）；命令 Summarize/ExtractTagsCommand，MCP 第 14/15 工具） | `lib/ai/`（`find lib/ai -type f`）、`lib/action/`、`lib/mcp/tools.dart`、双端 `LlmBridge.*` | docs/product/v2-requirements.md（收敛版）、docs/design/asr-subtitle.md（§8 翻译层）、docs/design/on-device-llm.md（端侧 LLM SSOT） |
| 浏览 | 收集列表/搜索/详情/再分享 UI、导航/页面/设置树/组件规范、详情模板注册表 | `lib/pages/` `lib/ui/` `lib/main.dart`（`find lib/pages lib/ui -type f`） | docs/design/ui-spec.md |
| MCP 服务 | 端点/鉴权/版本协商、工具集、token 总控、前台保活 | `lib/mcp/` `lib/service/`（`find lib/mcp lib/service -type f`） | docs/guide/mcp-integration.md、docs/architecture/overview.md |
| 更新体系 | 应用内自更新（清单/下载/校验/安装）、配置热更（公告/MCP instructions） | `lib/update/` `lib/pages/update_page.dart`（`find lib/update -type f`） | docs/guide/self-update.md |
| 备份同步 | S3 备份/恢复（endpoint/bucket/AK/SK 配置与测试、DB 快照 VACUUM INTO、SigV4 传输、附件增量上传/下载、全量替换恢复、Vault 排除）、BackupService 状态机与进度 | `lib/sync/` `lib/pages/settings_page.dart`（备份区块）（`find lib/sync -type f`） | docs/design/s3-backup.md |
| 向量派生数据 | item_embeddings 派生表（schema v9，分块向量缓存：不进备份、恢复即清、换模型全量重算）、嵌入 CRUD（`replaceItemEmbeddings`/`deleteItemEmbeddings`/`embeddingsCount`） | `lib/data/db.dart` `lib/data/repository.dart` | docs/design/vector-embeddings.md |
| 视频切片 | 关键区间登记/校验（ClipCommand）、clip:* 队列任务（原生提取：media3 Transformer trim + extractWav16k→ASR→LLM 摘要）、clips_json 附属记录（schema v10）、区间结果独立回写通道 | `lib/ai/video_clips.dart` `lib/ai/clip_reconstructor.dart` `lib/action/`（clip 路径） | docs/design/video-clips.md |
| 块附件通道 | 行内媒体块 AI 能力：block_artifacts 派生表（schema v21，撤销重跑/GC/磁盘联动）、block_* 队列动作串（`|` 分段，首段=block_key）、WorkflowSpec 工作流编排与三级能力页工作流轨/产物卡、门禁分叉（UI 手动即授权 / AI 须 aiProcess）+ 动作头入队互斥、MCP 五个块能力工具（`block_transcribe/ocr/translate/summarize/extract_audio_item`）与 get_item 的 `block_artifacts`/`block_tasks` 双字段 | `lib/data/block_artifacts.dart` `lib/ai/workflow.dart` `lib/ui/block_workflow_page.dart` `lib/ui/workflow_track.dart` `lib/action/`（block 分支）、`lib/mcp/tools.dart`（第 30 工具） | docs/design/block-artifact-workflow.md、docs/guide/mcp-integration.md（工具一览） |
| 跨端媒体能力 | 原生媒体能力接口（探测 videoDurationMs/audioCodec、解码 decodeMonoPcm、切片 trimVideo、音轨导出 exportAudio；MethodChannel `goodshare/media` + `MediaBridge.kt` + media3-transformer；ffmpeg_kit 已退役 2026-10-03） | `lib/media/media_toolkit.dart` `android/.../MediaBridge.kt` | decisions.md「media-native」ADR + context/epics/media-native/memory.md |
| 桌面桥接 | stdio↔HTTP 桥、e2e 自检、客户端接入配置 | `mcp-bridge/`（`find mcp-bridge -type f`） | docs/guide/mcp-integration.md |
| 构建发布 | manifest 权限/intent-filter、targetSdk、签名 | `android/`（`find android/app -type f`） | .agents/skills/goodshare-workflow |

跨域隐式契约：存储 ↔ MCP 工具（tools.dart 的返回结构是 list_items/get_item 的对外契约，改动需同步 test/mcp_server_test.dart）；前台保活 ↔ 构建发布（targetSdk=34 与 dataSync 绑定，联动记入两处文档）。

## 业务别名映射

- **收集器/收藏/分享箱** → 采集/存储域；**MCP 服务/服务器端点/工具** → MCP 服务域；**桥/bridge/桌面接入/Claude 配置** → 桌面桥接域

## 维护约定

- 可推导的不维护（路径/命名现场 derive），不可推导的才平时顺手登记；禁止为收集目的给文件新增元数据字段。
- 新增领域/大功能加一行；禁止写类清单/文件触点清单。
- 联动标记只记机器查不出的隐式契约；能用测试守护的优先加护栏。
