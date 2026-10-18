---
status: active
updated: 2026-10-17
---

# goodshare 功能落点索引（数据）

> 索引数据（功能归属表 / 跨域隐式契约 / 业务别名映射）。登记规约与维护协议 = `.agents/skills/goodshare-index/SKILL.md`；索引机制正文 = 全局 `project-index` skill，两边均不在此复制。

## 归属表

| 领域 | 覆盖功能 | 代码落点（锚点 · 展开命令） | 文档落点 |
|---|---|---|---|
| 采集 | 系统分享接收、文本/链接归一、附件落盘 | `lib/share/`（`find lib/share -type f`） | docs/architecture/overview.md |
| 存储 | sqflite 表结构、Repository 查询/删除 | `lib/data/`（`find lib/data -type f`） | docs/architecture/overview.md |
| 动作层 | UI/MCP/AI 管线共用写路径：命令协议（`ItemCommand`/`CommandResult`/`ActionException`/`CommandActor`）、`ItemActionHandler.execute`（编辑/软删/重分类/set_vault/reprocess/unlock_edit/collect/restore/批量事务）、machine_json Schema 校验 | `lib/action/`（`find lib/action -type f`） | docs/architecture/human-ai-parity.md、docs/product/product-requirements.md（§7 关键约束） |
| AI 管线 | AiReconstructor 接口/占位实现/Registry、ai_task_queue 消费者、**端侧翻译层**（`translation.dart`引擎接口/路由/句子切分、`translation_mlkit.dart`、`translate_reconstructor.dart`、`language_codes.dart` 语言码 SSOT）、**离线转写+字幕**（`asr.dart` Sherpa 引擎+VAD cue、`asr_reconstructor.dart`、`asr_model.dart` 三档模型目录、`subtitle.dart` AsrCue/SRT·VTT 序列化/SubtitleStore）、~~端侧 LLM~~（2026-10-14 ai-app-split M2 已整体拆出：`lib/ai/llm*.dart` 与双端 `LlmBridge.*` 移除，本地不再持有 LiteRT 引擎；LLM 任务 `llm_summarize`/`llm_tags`/`block_summarize` 改由 AI 宿主 App 经 `claim/touch/apply_ai_task` 远程认领回写。命令 `SummarizeCommand`/`ExtractTagsCommand` 与 MCP `summarize_item`/`extract_tags`/`block_summarize_item` 作为入队契约保留，`summary_md` 字段保留） | `lib/ai/`（`find lib/ai -type f`）、`lib/action/`、`lib/mcp/tools.dart` | docs/product/v2-requirements.md（收敛版）、docs/design/asr-subtitle.md（§8 翻译层）、docs/design/ai-app-split.md（LLM 拆分 SSOT，on-device-llm.md 已墓碑化） |
| 浏览 | 收集列表/搜索/详情/再分享 UI、导航/页面/设置树/组件规范、详情模板注册表 | `lib/pages/` `lib/ui/` `lib/main.dart`（`find lib/pages lib/ui -type f`） | docs/project/ui-design.md、docs/design/detail-page-visual-audit.md（详情页视觉对账蓝本） |
| 速记/编辑器 | 速记条作曲与格式引导层：段模型（`NoteTextSeg`/`NoteMediaSeg`）、文本真相引擎 `ComposerDoc`、`SpanTextEditingController`、**格式引导层**（统一排版规约 `BlockPresentation` + 侧轨语义角标 + 贴键浮层打样面板 → `setLineKind`/`toggleTodo`）、列表凹槽与有序重排 | `lib/ui/note_composer_editor.dart`、`lib/ui/composer_doc.dart`、`lib/ui/span_text_controller.dart`、`lib/ui/theme/block_presentation.dart`、`lib/share/quick_note_*.dart` | docs/design/note-editor-source-of-truth.md、docs/design/note-editor-unification.md、**docs/design/note-format-guidance-layer.md**（格式入口 SSOT，2026-10-08 取代已墓碑化的 quick-note-format-dial.md） |
| MCP 服务 | 端点/鉴权/版本协商、工具集、token 总控、前台保活 | `lib/mcp/` `lib/service/`（`find lib/mcp lib/service -type f`） | docs/guide/mcp-integration.md、docs/architecture/overview.md |
| 更新体系 | 应用内自更新（清单/下载/校验/安装）、配置热更（公告/MCP instructions） | `lib/update/` `lib/pages/update_page.dart`（`find lib/update -type f`） | docs/guide/self-update.md |
| 备份同步 | S3 备份/恢复（endpoint/bucket/AK/SK 配置与测试、DB 快照 VACUUM INTO、SigV4 传输、附件增量上传/下载、全量替换恢复、Vault 排除）、BackupService 状态机与进度 | `lib/sync/` `lib/pages/settings_page.dart`（备份区块）（`find lib/sync -type f`） | docs/design/s3-backup.md |
| 向量派生数据 | item_embeddings 派生表（schema v9，分块向量缓存：不进备份、恢复即清、换模型全量重算）、嵌入 CRUD（`replaceItemEmbeddings`/`deleteItemEmbeddings`/`embeddingsCount`） | `lib/data/db.dart` `lib/data/repository.dart` | docs/design/vector-embeddings.md |
| 视频切片 | 关键区间登记/校验（ClipCommand）、clip:* 队列任务（原生提取：media3 Transformer trim + extractWav16k→ASR→LLM 摘要）、clips_json 附属记录（schema v10）、区间结果独立回写通道 | `lib/ai/video_clips.dart` `lib/ai/clip_reconstructor.dart` `lib/action/`（clip 路径） | docs/design/video-clips.md |
| 块附件通道 | 行内媒体块 AI 能力：block_artifacts 派生表（schema v21，撤销重跑/GC/磁盘联动）、block_* 队列动作串（`\|` 分段，首段=block_key）、WorkflowSpec 工作流编排与三级能力页工作流轨/产物卡、门禁分叉（UI 手动即授权 / AI 须 aiProcess）+ 动作头入队互斥、MCP 五个块能力工具（`block_transcribe/ocr/translate/summarize/extract_audio_item`）与 get_item 的 `block_artifacts`/`block_tasks` 双字段 | `lib/data/block_artifacts.dart` `lib/ai/workflow.dart` `lib/ui/block_workflow_page.dart` `lib/ui/workflow_track.dart` `lib/action/`（block 分支）、`lib/mcp/tools.dart`（第 30 工具） | docs/design/block-artifact-workflow.md、docs/guide/mcp-integration.md（工具一览） |
| 跨端媒体能力 | 原生媒体能力接口（探测 videoDurationMs/audioCodec、解码 decodeMonoPcm、切片 trimVideo、音轨导出 exportAudio；MethodChannel `goodshare/media` + `MediaBridge.kt` + media3-transformer；ffmpeg_kit 已退役 2026-10-03） | `lib/media/media_toolkit.dart` `android/.../MediaBridge.kt` | decisions.md「media-native」ADR + context/epics/media-native/memory.md |
| 桌面桥接 | stdio↔HTTP 桥、e2e 自检、客户端接入配置 | `mcp-bridge/`（`find mcp-bridge -type f`） | docs/guide/mcp-integration.md |
| 构建发布 | manifest 权限/intent-filter、targetSdk、签名 | `android/`（`find android/app -type f`） | .agents/skills/goodshare-workflow |
| LLM 拆分（AI 宿主 App） | LLM 类任务（llm_summarize/llm_tags/block_summarize/template_apply）远程化：claim_ai_task/touch_ai_task/apply_ai_task 三工具（M1 ✅）、占位守卫（M2 ✅：QueueConsumer SQL 层排除远程集合，llm*.dart/LlmBridge.kt 已删）、sampling 反向推理（M3 ✅） | `lib/mcp/tools.dart`（三工具 + ai_suggest_tags）`lib/ai/queue_consumer.dart`（远程集合过滤） | docs/design/ai-app-split.md（接缝 SSOT） |
| 内容生产模板 | templates CRUD（MCP AI 托管）+ 模板 skill resource + 人类只读预览页 + P2「按模板处理」（TemplateApplyCommand → template_apply:<id> 远程任务 → 只追加回写 template_output 三列）+ 详情页呈现规约 | `lib/action/`（TemplateApplyCommand/_templateApply/模板分支早退）`lib/data/repository.dart`（byIdTemplate/listTemplates）`lib/pages/item_detail_page.dart`（_showTemplatePicker/模板卡）`lib/pages/template_preview_page.dart` | docs/design/ai-template.md（模板域 SSOT） |

## 跨域隐式契约

- 存储 ↔ MCP 工具：tools.dart 的返回结构是 list_items/get_item 的对外契约，改动需同步 test/mcp_server_test.dart。
- 前台保活 ↔ 构建发布：targetSdk=34 与 dataSync 绑定，联动记入两处文档。
- LLM 拆分 ↔ MCP 服务：claim/touch/apply 是第二客户端接入面，改动须同步 docs/design/ai-app-split.md 接缝契约。

## 业务别名映射

- **收集器/收藏/分享箱** → 采集/存储域；**MCP 服务/服务器端点/工具** → MCP 服务域；**桥/bridge/桌面接入/Claude 配置** → 桌面桥接域
