---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 5
last-merge: 2026-09-29
---

# 2026-09-29 · 图片分类（ML Kit Image Labeling）落地

[落点] AI 能力 lib/ai/image_label_reconstructor.dart + lib/ai/image_labels_zh.dart；命令/动作 lib/action/commands.dart(ClassifyCommand) + lib/action/item_action_handler.dart(_classify)；路由 lib/main.dart(Registry) + lib/data/repository.dart(taskClassifyImage)；入口 lib/mcp/tools.dart(classify_item 第 16 工具) + lib/pages/item_detail_page.dart(识别分类按钮 + 空产出状态分支)；依赖 pubspec.yaml(google_mlkit_image_labeling ^0.16.1)；测试 test/mcp_tools_test.dart(工具数 15→16)

## 评估结论
- ML Kit Image Labeling base 模型 **bundled**（打进 APK），离线可用，不依赖 Google Play 语言包——国内无 GMS 也能跑（与 translation 受 Play 不可达相反，显著优势）。
- 覆盖约 400 类常见物体；英文标签经 `kImageLabelZh` 离线映射中文（高频类，未命中保留英文），纯静态表零依赖。
- Flutter 插件 `google_mlkit_image_labeling`（flutter-ml.dev 同族，API 与 text_recognition 一致）。

## 设计决策（用户拍板「手动 + 离线中文映射」）
- 仅**手动触发**（`task_action=classify_image`），与 OCR/转写同口径：摄入不自动跑模型，避免占队列。
- 产出写入 `ReconstructResult.facets['分类']`（多视角聚类，AI 分类页消费）；落库链路已通（handler 写 `facets_json`）。
- 错误/空产出按 R1/R3 可观测：`note` 含「图片文件缺失 / 未识别已知分类 / 分类失败」；超时 20s 兜底；失败归占位完成不置死信。
- 新增依赖经用户批准（R4 突破：原约束内无出路）。

[验证] flutter analyze → 0 issue；flutter test → 131 绿（工具数断言 15→16）；debug 构建未跑（本机无真机）。
- [2026-09-29] [变更]: 派生数据分表落地（用户拍板「第 1 点做一下；量化/检索记档」）——①schema v9 幂等迁移新增 item_embeddings 派生表（item_id/model/chunk_index/dim/dtype/vec/created_at，PK(item_id,model,chunk_index)，FK ON DELETE CASCADE 随条目硬删清理）：向量是源文本可再生派生物，独立成表保证事实源体积不随向量增长、换嵌入模型整表重算 ②Repository 嵌入 CRUD 骨架：replaceItemEmbeddings（按模型整替，分块重算语义）/deleteItemEmbeddings（可按模型）/embeddingsCount + ItemEmbedding 模型（dtype 预留 f32/int8）；派生缓存写入不 bump 乐观锁、不 notifyListeners（不进 UI 读路径，消费方是未来检索引擎）③备份/恢复联动：snapshotTo 在快照副本整表清空向量（**向量不进备份**，备份只保护事实源）、restoreFrom 同事务清 stale 向量（恢复语义=事实源全量替换+派生缓存归零）④新设计文档 docs/design/vector-embeddings.md：派生数据治理+体积测算+int8 量化约定（dtype 已预留）+检索路径分档（≤1 万 Dart 暴力余弦 / ≥10 万再议 sqlite-vec）+分块纪律（只对长文本分块）；docs/README 索引、webdav-backup.md §9 交叉引用、goodshare-index 新行三处同步
- [2026-09-29] [验证]: flutter analyze → 0 issue；flutter test → 132/132（新增「向量派生数据：CRUD 往返、快照整表不携带、恢复即清 stale」）；bash scripts/agent-tools/docs-lint.sh → OK
- [2026-09-29] [决策]: 视频切片（关键区间）三项拍板（@confirm 台账 D1-D3 全清）：D1=切片结果挂**原条目附属记录**（schema v10 clips_json JSON 列，与 appendix/facets 同风格；向量按区间序号进 item_embeddings）；D2=**转写+摘要先行**（ffmpeg 提区间音轨→端侧 ASR→端侧 LLM 摘要本期落地，向量引擎选型下期、item_embeddings 接口已就绪）；D3=**视频源文件不进 WebDAV 备份**（字幕/译文/切片产物照进，恢复走既有「文件缺失」降级态）——对齐用户「只备份关键的东西」。UX 定调：播放器打点式选多区间（用户要求友好方式、区间可多个）
- [2026-09-29] [变更]: 视频切片（关键区间）全链路落地（设计 docs/design/video-clips.md，D1-D3 台账拍板）——①schema v10：inbox_items.clips_json（建表+幂等迁移）②纯模块 lib/ai/video_clips.dart（ClipSegment + 防御解析 + 区间校验[1s,30min] + mergeClipResult + ffmpeg 提区间参数：-ss 前置快 seek + -t 时长 + pcm_s16le）③动作层：ClipCommand(op=clip) + handler _clip（仅视频/区间合法/去重校验下沉，登记空段+入队 clip:start-end 任务）；ReconstructResult 加 clip 独立通道，_applyAiResult 只合并 clips_json **不触碰条目级 human_md/summary_md**（区间结果不得覆盖整片转写）；ApplyAiResultCommand 顺带补 summaryMd 序列化缺口 ④ClipReconstructor：ffmpeg 提区间音轨（临时 wav 用完即删）→ AsrEngine.transcribeToCues 原语直调（无字幕文件副作用）→ LlmReconstructor 复用摘要提示词；失败占位完成+区间 note（与队列 last_note 同文案）；队列 clip 任务超时 180s（三段串行）⑤main 注册（复用 hoist 的 ChannelLlmEngine 实例）⑥UI：clip_editor_sheet 播放器打点式选多区间（设为起点/终点捕获播放位置，免手输时间戳，保存逐区间发命令，重复区间回动作层提示）+ 详情页「切片」按钮 + 模板「关键区间」区块（起止/文本/摘要/note 状态）⑦D3：备份白名单排除视频源文件、纳入 subtitles/translations（collectBackupFiles 抽顶层可测 + derivedArtifactItemId 首段=条目 id 做 Vault 排除）+ 设置页文案/恢复对话框明示
- [2026-09-29] [验证]: flutter analyze → 0 issue；flutter test → 142/142（新增 test/video_clips_test.dart 10 条：纯模型/编解码/区间边界/动作串往返/ffmpeg 参数/合并语义 + handler 登记/去重/非视频拒绝 + clip 通道不触碰条目级字段 + 备份白名单视频排除与字幕译文纳入）；bash scripts/agent-tools/docs-lint.sh → OK；flutter build apk --debug → ✓ Built
- [2026-09-29] [决策]: 视频切片**改版**（用户重定方向，E1-E3 台账全清）：①**标记 ≠ 处理**——标记只记时间点供播放跳转，处理显式触发且可勾选链路子集，止步于片段本身合法（原「登记即入队」废除，回归「重资源动作一律手动」铁律）②链路扩四段：提取视频片段→转写→摘要（→向量二期）③**两极标记**：区间标记 + 整片标记（整个视频重要→源文件进备份范围，D3 默认排除的逐条目 opt-in，标记不触发上传）。E1=精确重编码（ffmpeg min→**min_gpl** 变体引入 libx264，版本 2.6.2 与 min 3.6.2 不同步，APK 增重换逐帧准确剪辑）；E2=摘要自动带动转写前置（normalizeClipSteps 规整）；E3=按评估稿执行
- [2026-09-29] [变更]: 切片改版落地——①段结构 v2：ClipSegment 加 steps/status(marked|processing|done|failed)/clipPath（clips_json JSON 列吸收，schema 版本不动；v11 仅加 video_whole_marked 整片标记列）②命令层：ClipCommand 退纯标记（不入队）、新增 ClipProcessCommand（勾选子集→规整→置 processing→入队 clip:s-e:ets 动作串）与 MarkWholeVideoCommand（仅视频）③ClipReconstructor 重写为多步链：提取（libx264 精确重编码→documents/clip_segments/{itemId}.{s}-{e}.mp4）→转写（buildClipAudioArgs 16k wav→transcribeToCues）→摘要（复用 LlmReconstructor）；部分失败=区间 failed+note 分步明说，产物照存 ④UI：Sheet 改标记优先（保存不触发处理）+ 既有标记管理（跳转/步骤 FilterChips/处理按钮）+ 播放器内嵌标记跳转 chips + 详情页「整片」按钮 + 模板关键区间按状态展示（「已标记（未处理）——标记仅记时间点，处理后才算收藏完成」）⑤备份白名单：整片标记视频 opt-in 携带 + clip_segments/ 产物进备份 ⑥ffmpeg 全仓 import 切 min_gpl（asr/audio_extract/clip_reconstructor 三文件）
- [2026-09-29] [验证]: flutter analyze → 0 issue；flutter test → 144/144（切片测试重写 12 条：步骤规整/带步骤动作串/双 ffmpeg 参数/标记不入队/处理入队与 processing/整片标记开关/备份 opt-in 等）；bash scripts/agent-tools/docs-lint.sh → OK；flutter build apk --debug → ✓ Built（min_gpl 变体原生链接通过，APK 增重待真机实测）
- [2026-09-29] [SSOT 修正]: 旧结论「备份传输层=WebDAV（dio 手写 PROPFIND/MKCOL/MOVE 薄封装）」已废弃 ➔ 新结论「备份传输层=S3（dio+crypto 手写 SigV4 薄封装，path-style，零新依赖）」；编排/快照/恢复语义/manifest 提交标记/Vault 排除不变，webdav_client.dart 删除
- [2026-09-29] [变更]: S3 备份传输层落地——新增 lib/sync/s3_client.dart（SigV4 手写签名 + HeadBucket/HeadObject/PutObject/GetObject/ListObjectsV2/DeleteObject + 固定时间测试缝）；backup_service 凭据换 endpoint/bucket/region/AK/SK、去 MKCOL 建目录（S3 无目录）、原子提交改为「S3 PUT 本身原子 + manifest 最后写」；设置页区块改 S3 表单；测试改名 s3_backup_test.dart 并新增 SigV4 固定时间向量对拍 + ListObjects XML 解析用例；docs/design/webdav-backup.md 与 memory.md 同步改写
- [2026-09-29] [验证]: flutter analyze → 0 issue；flutter test test/s3_backup_test.dart → 7/7 绿；全量 flutter test 与最终验证见下一行
- [2026-09-29] [验证]: flutter analyze → No issues found（中途 use_null_aware_elements lint 试 `?key` 误放 key 侧报类型错、`if-case` 仍触发该 lint，终以 `'k': ?v` 值侧 null-aware 修复）；flutter test → 146/146 全绿
- [2026-09-29] [变更]: WebDAV 支持彻底移除（用户拍板「对 webdav 的支持就不要了」）——设计文档正名 webdav-backup.md → s3-backup.md（正文全 S3 口径，仅留变更史一行）；lib/test 内 WebDAV 字样注释全清（s3_client/backup_service/backup_manifest/repository/main/settings_page/s3_backup_test）；引用链修复 docs/README、video-clips、vector-embeddings、goodshare-index skill。代码层 WebDAV 实现上轮已删（s3_client 顶替），本轮纯命名/文档/索引收尾
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 146/146 全绿；bash scripts/agent-tools/docs-lint.sh → docs/ 全部校验通过
- [2026-09-29] [变更]: S3 错误可观测增强（真机反馈「R2 报 400 裸状态码」）——_wrap 解析 4xx 响应体 <Code>/<Message> 回传具体错误码与原因；设置页 Endpoint/Region 补 R2 可行动提示（地址格式 + region 填 auto）
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 146/146 全绿
- [2026-09-29] [变更]: S3 配置体验双修（真机反馈「填了 https 仍报仅支持 http/https」）——①测试连接改为先用当前输入框值保存再测（旧存档陷阱根因：改框不保存→测的是旧值）②_normalizeEndpoint 加固：Uri.parse 防炸（全角 scheme FormatException→友好文案）+ 拒绝零宽/不可见字符（复制粘贴混入 host）
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 146/146 全绿
- [2026-09-29] [变更]: S3 大文件 Multipart Upload 落地（真机验收通过后用户拍板）——s3_client 新增 createMultipartUpload/uploadPart/completeMultipartUpload/abortMultipartUpload，putFile 超 100MB 阈值自动切换（16MB/片，computePartSize 自动放大保证 ≤10000 片 S3 硬上限；失败 abort 清理已传分片，进度折算全文件坐标系）；putFile 签名不变，BackupService 编排层零改动；s3-backup.md 决策表补「大文件 Multipart」行
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 148/148 全绿（新增 computePartSize 边界 + completeMultipartBody 转义 2 条）；debug APK 重新构建 ✓
