---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 8
last-merge: 2026-09-30
---

# 2026-09-29 · 启动崩溃修复：androidx.work WorkDatabase 初始化失败

[落点] android/app/build.gradle.kts（强升 `androidx.work:work-runtime:2.9.0` + 锁定 `room-runtime:2.6.1`）；android/app/proguard-rules.pro（保留 work/room 类）

## 现象
- 安装后 App 直接崩溃（进程 `has died: fg TOP`）。logcat 关键栈：
  `FATAL EXCEPTION: main` → `Unable to get provider androidx.startup.InitializationProvider` →
  `Failed to create an instance of androidx.work.impl.WorkDatabase`。堆栈为 R8 混淆名（`n6`/`cx2`/`r8-map-id`），说明安装的是 release（混淆）构建。

## 根因（依赖版本冲突，非 Dart 代码）
- 新加的 `google_mlkit_entity_extraction` 传递引入 `com.google.mlkit:entity-extraction:16.0.0-beta6`
  → 拖入 `androidx.work:work-runtime:2.7.0`（2021 年老版本）；`work-runtime` 全树仅有这一来源
  （`flutter_foreground_task` 不依赖 work-runtime，它用前台 Service 而非 WorkManager）。
- 2.7.0 内嵌 Room 生成的 `WorkDatabase_Impl` 在 **Android 16（API 36）/ 现代 room** 上实例化失败
  → 启动即崩。仅升 `room-runtime`（先试 2.4.3）不足，因为病根在 work-runtime 2.7.0 这版太老本身不兼容。
- `dependencyInsight` 实证：`work-runtime:2.7.0 ← entity-extraction:16.0.0-beta6 ← :google_mlkit_entity_extraction`。
- 与本次安全窗 Dart 改动无关（安全窗启动时为 no-op，不触发通道调用）。

## 修复
- `configurations.all { resolutionStrategy { force("androidx.work:work-runtime:2.9.0") } }`：覆盖 2.7.0，
  现代 work-runtime 自带兼容 room 的 WorkDatabase 实现，在 Android 16 正常初始化。
- `implementation("androidx.room:room-runtime:2.6.1")`：与 2.9.0 对齐（2.9.0 声明依赖 room-runtime）。
- proguard-rules.pro 追加 `-keep class androidx.work.**` / `androidx.room.**` 及 RoomDatabase 子类：
  双保险，防 release R8 误删 `WorkDatabase_Impl` 反射类（若混淆是主因而非版本）。
- `dependencyInsight` 复核：`work-runtime:2.7.0 -> 2.9.0 (forced)`，`room-runtime:2.6.1`。

[验证] 用户实测重编安装后 App 正常启动（2026-09-29 确认），崩溃消失。本机无 NDK 仅能确认依赖解析：work-runtime=2.9.0、room-runtime=2.6.1。release 混淆构建下 keep 规则覆盖了 WorkDatabase_Impl。

---

# 2026-09-29 · 安全窗（FLAG_SECURE）改为仅「保险箱」tab 可见时才开启

[落点] 管控 lib/service/secure_window.dart（引用计数：tab 维度 `_tabSecure` + vault 详情维度 `_detailDepth`，任一为真才开）；驱动 lib/pages/home_shell.dart（底部 5 tab 切换时 `setVaultTabVisible(index==3)`）；明细 lib/pages/item_detail_page.dart（`vaultContext` 时 `enter/exitVaultDetail`）；去除 lib/pages/vault_page.dart 原 initState/dispose 的 `setSecure`（不再由其生命周期驱动）

## 根因
- 主页用 `IndexedStack` 常驻挂载全部 5 个 tab → `VaultPage.initState()` 在**应用启动即触发** `setSecure(true)`，永不清除 → 等价于「银行级、处处不可截图」。用户反馈「隐私规则太严无法截屏」。

## 修复
- 安全窗开关改由当前 tab 索引驱动：切到「保险箱」(index 3) 才开，离开即关，普通页面（全部/时光机/AI 分类/设置）恢复可截图分享。
- `SecureWindow` 重写为双维度引用计数：`_tabSecure`（tab 维度）与 `_detailDepth`（从保险箱进入的 vault 详情维度），任一为真即 `_want`，全部归零才真正调用 native `setSecure(false)`；配套 `_applied` 去重避免重复跨通道调用。
- `VaultPage` 移除 initState/dispose 的 `setSecure`（否则启动即全局开启）。
- `ItemDetailPage` 的 `vaultContext=true` 详情改用 `enter/exitVaultDetail`，叠加在保险箱 tab 之上时不会被本页 dispose 提前解除。

[验证] flutter analyze → No issues found；flutter test test/mcp_tools_test.dart → 16/16 全绿（native 通道 `setSecure`(bool) 协议不变）

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
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 148/148 全绿
- [2026-09-29] [决策]: ML 能力抽象层 + 引入范围拍板（用户拍板「新建 MlCapability + 适配器桥接旧 AiReconstructor」）——引入范围：Barcode Scanning / language_id / entity_extraction 引入（离线轻量、国内可用）；document_scanner 引入但**环境检测门控**（GMS 可用才启用，否则降级隐藏入口，与翻译层 Play 不可达教训同源）；face/object/pose **预留占位**（不引依赖、不实现、不抢相册职责）。抽象封装 前置(ensureReady/handles) + 执行(run) + 后置(normalize/dispose)，保证 Android/iOS 各自调官方插件但门控与产出口径共享（官方效果一致、人/AI/双端同一份状态）。新建 lib/ai/ml_capability.dart（MlCapability + ExecutionMode + CapabilityReadiness + AiReconstructorAdapter）；旧 AiReconstructor（ImageLabelReconstructor 等）经适配器接入现有 ReconstructorRegistry，QueueConsumer 零改动。落地顺序：barcode → language_id/entity → doc_scan → 占位。（新增 computePartSize 边界 + completeMultipartBody 转义 2 条）；debug APK 重新构建 ✓
- [2026-09-29] [变更]: 取消 AiReconstructorAdapter——[MlCapability] 直接 implements [AiReconstructor] 并提供默认 reconstruct（组合 ensureReady+run+normalize）；[ImageLabelReconstructor] 改名 [ImageLabelCapability] implements MlCapability（拆 ensureReady/handles/run/normalize，facets['分类']/note 文案/20s 超时/R1 可观测全保留）。QueueConsumer/ReconstructorRegistry 零改动（用户拍板「旧 Image Labeling 也直接改，不必为单一方法写适配器」）。
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 148/148 全绿（ImageLabel 改造后工具数仍 16、分类行为/文案/20s 超时/R1 不变）。Dart 语义坑已排：implements 不继承默认实现须用 extends（模板方法）；超类无 const 构造则子类去 const；library 指令用匿名 `library;` 避免不必要命名 lint。
- [2026-09-29] [决策]: 任务编排评估收束（docs/design/scheduling-tasks.md 新建，status=draft）——结论：**暂缓引入自组装编排器**（现有 ai_task_queue + AiReconstructor/Registry 已覆盖 80%；当前仅 clip 一条多步链，抽象 JSON workflow + 组装 UI 纯负收益）；触发条件三条全满足再重开（多链并存/用户排序诉求/Rule of Three）；同步固化**大参数三铁律**（P1 上下文只传引用不传实体、P2 快照记录摘要截断、P3 产物分级+中间产物即弃）——与编排器解耦现在生效；升级路径=外挂 WorkflowRunner 不动 Reconstructor 接口与队列。README 索引已同步，docs-lint OK
- [2026-09-29] [验证]: 续前轮：flutter analyze → 1 error（BarcodeReconstructor const 构造调 MlCapability 非常量超类构造 + main.dart const 调用点，即上轮已排 Dart 语义坑重现）→ 去 const 修复后 No issues found；flutter test → 148/148 全绿；docs-lint OK
- [2026-09-29] [变更]: minSdk 24→34（Android 14，用户拍板「兼容安卓14以上不做低版本兼容」）——根因：新引 google_mlkit_entity_extraction 16.0.0-beta6 硬性要求 minSdk ≥ 26，Manifest merger 失败；用户口径下直接抬到 34 一并化解（个人侧载无商店约束，与 targetSdk 34 对齐）。build.gradle.kts 注释留痕
- [2026-09-29] [验证]: flutter build apk --debug → ✓ Built（minSdk 34 下全链路通过）
- [2026-09-29] [变更]: Barcode 全链路落地（首个 MlCapability 实例，验证抽象成立）——①Repository 新增 taskScanBarcode 常量 ②新建 lib/ai/barcode_reconstructor.dart（extends MlCapability，写入 facets['条码']=[类型:值]，识别只标注不动作，不抢链接打开/Wi-Fi 连接）③commands 新增 ScanBarcodeCommand(op='scan_barcode') + fromJson 补 scan_barcode 分支（并补 AI 裸 JSON 路径既遗漏的 classify 分支）④item_action_handler 新增 _dispatch→_scanBarcode（「仅图片可扫描」校验下沉动作层，AI/MCP 换入口绕不过）⑤item_detail_page 新增「识别条码」按钮（仅图片）⑥mcp tools 新增 scan_barcode_item 工具清单 + callTool 分支。识别只标注不动作（与 OCR/分类对称）。
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 148/148 全绿（工具数 16→17；BarcodeScanner() 无参构造在 0.16.1 合法）。barcode_score 仅占位未引依赖（按拍板策略）。
- [2026-09-29] [变更]: 文本分析全链路落地（MlCapability 吃文本模态，验证抽象两模态通吃）——新建 lib/ai/text_analysis_capability.dart（extends MlCapability，对 note 条目，一次手动动作合并跑 ML Kit Language ID + Entity Extraction，写 facets['语言']/facets['实体']=[类型:值]，识别只标注不动作）。设计取舍：语言识别是实体提取前置，合并为单一入口省 UI/MCP/队列两套脚手架（不对用户拆「只想看懂语言」vs「想提取结构」）。BCP-47 离线转中文名、未命中保留原始码；EntityExtractor 仅支持语言才跑、否则只给语言。配套：Repository.taskAnalyzeText 常量 + AnalyzeTextCommand(fromJson/supportedOps 同步) + handler _dispatch→_analyzeText（「仅笔记可分析」校验下沉动作层）+ 详情页「分析文本」按钮（仅笔记）+ 空产出状态条 + MCP analyze_text_item 工具清单/callTool 分支。API 坑：LanguageIdentifier 必须传 confidenceThreshold（无参构造失败）、EntityExtractor({required language}) 用 EntityExtractorLanguage 枚举。
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 148/148 全绿（工具数 17→18；language_id/entity_extraction 精确 API 调用验证通过）。
- [2026-09-29] [变更]: 文档扫描落地（MlCapability 第三模态 foregroundUi，验证抽象覆盖前台相机流）——新建 lib/ai/document_scan_capability.dart（extends MlCapability，mode=foregroundUi，调起系统 Document Scanner 相机流；产出经 machine_json 透传，UI 据此每页新建一张图片条目 / 整本 PDF 建文档条目）。与已落地能力本质不同：**它是相机流、AI(headless/MCP) 无法调起相机 → 无 MCP 工具、不进队列路由**（handles 仅作契约占位，UI 直接 ensureReady+reconstruct）；[AiCapabilities] 新增 documentScan 字段持有单例供 inbox 页取用；inbox 页 AppBar 加全局「扫描文档」入口。GMS 门控取舍：该包**不暴露任何 GMS/相机预检 API**，且文档扫描真依赖 GMS 无法像 OCR 那样 bundled——故**不做脆性 GoogleApiAvailability 预检**（会重演 OCR 早期误关国内无 GMS 设备入口的坑），改为**点击时运行时优雅降级**：无 GMS → PlatformException 被 run 捕获 → 归占位完成并明说「设备无 Google Play 服务」；ensureReady 留原生 MethodChannel 钩子，后续要「无 GMS 真隐藏入口」可在此接入。pageLimit 暂用默认 1（多页调优待定）。
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 148/148 全绿（MCP 工具数保持 18，文档扫描无 MCP 工具符合设计；前三种 MlCapability 模态——backgroundQueue 图片/条码/文本、foregroundUi 文档扫描——全通）。
- [2026-09-29] [决策]: face/object/pose 定为本轮**预留占位**（`ml_capability.dart` 的 `ExecutionMode.placeholder` 已定义，注释即「不引依赖、不实现，仅留接口不抢相册职责」）——**不落地具体 MlCapability 子类、不引任何依赖**。理由：人脸 / 物体 / 姿势识别是系统相册（Google Photos 等）的既有能力，端侧 ML Kit 重做一遍既重又边际价值低，且与相册职责重叠（设计明确「不抢相册职责」）。MlCapability 抽象已为三者留干净插槽，未来要上只需新增一个 `extends MlCapability` 的类（mode 取 placeholder 或具体形态）。**本轮 ML 能力体系收尾**：已落地 4 个（图片分类 / 条码 / 文本分析 = backgroundQueue；文档扫描 = foregroundUi）+ 3 个预留（人脸 / 物体 / 姿势 = placeholder）。
- [2026-09-29] [变更]: 深度代码审核修复（P2/P3 各一条）——①inbox `_scanDocument` 入库循环纳入 try/catch（CollectCommand 抛错不再逃逸，SnackBar 报「已添加 X 个，失败 Y 个」部分完成状态）②扫描结果路径先经 `copyToAppDir` 落 app 私有目录再入 CollectCommand（扫描器返回的 content URI/临时路径会被系统清理，防后续 OCR/预览/备份全挂，与分享摄入同口径）③补 MCP scan_barcode_item/analyze_text_item 的 callTool 测试（空 id 拒绝 + happy path 入队 taskScanBarcode/taskAnalyzeText + 类型不符拒绝 + Vault 条目对 AI actor 不可见）
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 150/150 全绿（含 2 个新 MCP 工具测试）

---

# 2026-09-29 · 构建产物优化：APK 仅 arm64-v8a（split-per-abi），375MB→154.9MB

[落点] scripts/release-r2.sh（构建命令改 `--split-per-abi --target-platform android-arm64`；APK 路径指向 `app-arm64-v8a-release.apk`）；android/app/build.gradle.kts（移除与 split 冲突的 `ndk.abiFilters` 块）

## 现象
- 初版整包 `flutter build apk --release` 产出 fat APK 375.2MB，含 arm64-v8a / armeabi-v7a / x86_64 全部 ABI 的 native 库（ffmpeg_kit、onnx、litertlm、translate、mlkit 等）。目标设备均为 64 位，x86_64/v7a 无使用场景，纯冗余。

## 根因
- `flutter build apk --target-platform android-arm64` 仅过滤 **Flutter 引擎** libflutter.so，第三方插件从 Maven 拉取的预编译 AAR 内 .so 仍全打（unzip 证实仍含 x86_64/v7a），首次只省 40MB。
- 在 `defaultConfig` 加 `ndk { abiFilters += "arm64-v8a" }` 又被 Flutter Gradle 插件 `afterEvaluate` 覆盖，且与 `--split-per-abi` 同时设置时报 `Conflicting configuration: ndk abiFilters cannot be present when splits abi filters are set`。

## 修复
- 构建命令改为 `flutter build apk --release --split-per-abi --target-platform android-arm64`：AGP 物理拆分，每个 ABI 包只含该 ABI 的 .so（含插件 AAR），产出 `app-arm64-v8a-release.apk`。
- 移除 build.gradle.kts 的 `ndk.abiFilters` 块（与 split-per-abi 冲突）。
- 脚本 APK 路径同步指向 `app-arm64-v8a-release.apk`，上传远端 key 仍为 `updates/app-release.apk`（App 端源地址不变）。

## 结果
- 包体 375.2MB → **154.9MB**（so 总 130.7MB，仅 lib/arm64-v8a 24 个 .so）。已发布到 R2（json 200 / apk 154.9MB / 新 sha256）。
- 残留 130.7MB 为 arm64 自身 native 库（libonnxruntime 22MB、liblitertlm_jni 21MB、libtranslate_jni 16MB、libavcodec(ffmpeg) 11MB、libflutter 11MB）+ ML Kit 等；靠 ABI 过滤已无空间。
- 进一步缩小需换更小依赖变体（如 ffmpeg_kit lgpl/min、裁剪翻译/AI 引擎），属更大改动，暂不动。
- Gradle daemon 偶发崩溃一次（disappeared unexpectedly），清理 daemon 后重试成功，非配置问题。

[验证] R2 公开 URL 验证：goodshare-update.json 200、app-release.apk content-length 154903032、sha256=a5676be1b351dd0e09728d2eba8f96423a637e93e7695a4aa0b52b5f1b634026；包内 lib/ 仅 arm64-v8a（unzip 计数 24）

# 2026-09-29 · 应用图标更换：接入 flutter_launcher_icons 自动生成

[落点] pubspec.yaml（dev_dependencies + `flutter_launcher_icons` 段）；assets/icon/app_icon.png（1024² 源图）；android/app/src/main/res/mipmap-*/ic_launcher.png 与 ios/Runner/Assets.xcassets/AppIcon.appiconset/ 由工具生成

## 做法
- 源图 /home/zzh/Downloads/1790684235662.png 非方形（1008×1045）→ 居中裁剪到 1008² 再放大到 1024² 存为 assets/icon/app_icon.png
- 配置：android: "ic_launcher"（保持 AndroidManifest 引用 `@mipmap/ic_launcher` 不变）、ios: true、remove_alpha_ios: true（规避 App Store alpha 限制）
- 执行：`flutter pub get && dart run flutter_launcher_icons -f pubspec.yaml`（Flutter 绝对路径 /home/zzh/flutter/bin/flutter，本机不在 PATH）

## 备注
- 未做 Android 自适应图标（mipmap-anydpi-v26），沿用传统方形 ic_launcher；后续如需随主题变形再补 foreground/background 资源
- 启动页 splash 自定义未做，已拆为独立待办（见 todos.md）

# 2026-09-29 · 应用图标源图替换（去白边）

[落点] assets/icon/app_icon.png（源图由 1790684235662.png 换为 1790684901326.png）；android/app/src/main/res/mipmap-*/ic_launcher.png 与 ios/Runner/Assets.xcassets/AppIcon.appiconset/ 重新生成

## 做法
- 旧源图 1790684235662.png 四周带白边 → 改用 1790684901326.png（原生 1024×1024 方形 RGBA，无需裁剪居中）
- 重新执行 `dart run flutter_launcher_icons -f pubspec.yaml`；`remove_alpha_ios: true` 仍生效，无 alpha 警告
- [2026-09-29] [变更]: 提交收口——.gitignore 补 .atomcode/（AtomCode 工具本地记忆，与 context/CURRENT 同类不入库）；当日全量改动（ML 能力体系 4 能力/启动崩溃修复/安全窗收窄/应用图标/R2 发布链路/scheduling-tasks 文档）落单个 commit
- [2026-09-29] [验证]: flutter analyze → No issues found；flutter test → 150/150 全绿（提交前门禁复跑）
- [2026-09-29] [决策]: 内容管线与展示形态改版定调（多轮 @confirm 收敛；参考 mymind 详情页「文档」形态，**否决小红书式低密度大卡片**——用户口径「显示密度太低」）——①呈现基调：详情页从「分区卡片堆叠的仪表盘」改为「一篇文章」：标题置顶(headlineSmall w600)→导语块(原 TL;DR，次级色+左侧细线)→正文富文本全宽→派生内容作**附录章节**而非叠 Card→机器态收进 AppBar ⋯ 菜单(双态保留但降权)→操作收敛（⋯ 菜单 + 底部唯一浮动主按钮，不做按钮矩阵）→末尾小字「来自 XXX · 时间」；列表提密度（文档条目行：标题 1-2 行 w500 + 正文摘要 60-80 字 + 元信息行，缩略图 56-64px，去 Divider）②**弃 flutter_markdown_plus 改自建富文本渲染器**——硬理由四条，最硬一条：`ui-spec` §7 要求 `human_md` 中 `[ ]` 待办可勾选（状态写 todo_state_json 按 hash 关联），而 Markdown 渲染器输出不可交互文本流，**该需求在渲染器架构下永远做不了**；其余为停更分叉风险、排版参数受限、全仓仅 2 处引用替换成本极低③富文本载体 = **Markdown 子集**（存储格式不变、MCP 输出契约零改动；明确不引 HTML 渲染包）；块级降级铁律「**宁可样式平，不可吞内容**」④**存储仍三层、呈现只走富文本**——`raw_content` 常是唯一副本（便签/链接条目无原文件）不可抛，呈现层暴露原始层正是「链接条目显示裸 URL」这一现存缺陷的根源；「查看原文」退为 ⋯ 菜单次要入口⑤新建 `lib/doc/` 归一化层（接口 + Registry，与 AiReconstructor/ItemViewRegistry 同构）：html/pdf/plain → Markdown 子集，**docx 不做留插槽**（OOXML 代价与收益不成比例）；产物写 `human_md` 不新增列；**上游 `url_extract.dart` 现把标题/列表/引用/代码块全剥成纯文本，须补保结构**；PDF 结构靠字号/位置启发式，标 DEGRADE⑥**文件持有改为引用原件不复制**（用户拍板「不能给用户存储增加麻烦」）：导入=1 份 vs 复制=2 份（视频 500MB→1GB 是重灾区）；分享进来的 `content://` URI 只有读权限、FileProvider 未实现 delete，**「导入即删原件」技术上不可行且属破坏性动作不采纳**；引用必须 SAF + takePersistableUriPermission 存 URI，**不能存裸路径**（分区存储下会失效）——⚠️ 现 file_picker/image_picker 能否拿到可持久化 URI **待实测**，且需确认选择器自身缓存副本是否长期残留⑦文档类走「转换后释放副本」= 零占用且内容自持（严格优于单纯引用，不用赌原件）；媒体类富文本替代不了内容本体，走引用整片 + 缩略图/关键片段自持（**视频文本化不作为常规流程**：需提音轨+跑模型且画面信息全丢，现状已手动触发不动）⑧分享·视频/音频 = **摄入后弹提醒 + 快捷导入**（用户拍板）——分享 URI 生命周期短，等下次打开再提醒很可能已失效来不及导入；状态机 ref→owned/lost（新增 attach_state 列，schema v12）⑨备份：引用原件**不进备份**（备份时可能已不可读、换机后路径无效），备份内容 = 富文本 + 小衍生物
- [2026-09-29] [变更]: 新增设计 SSOT `docs/design/content-pipeline.md`（status=draft：关键决策表/文档形态改造对照/Markdown 子集规范/lib-doc 归一化层/自建渲染器理由与排版令牌/文件持有策略矩阵/引用状态机与三级提醒/对备份·切片·队列的影响/**实施顺序（先转换后切引用，颠倒则内容没留住且无副本）**/待确认默认取值）；`docs/design/ui-spec.md` 同步五处（§1 增「文档形态」原则并记否决小红书、§2.2 增富文本排版令牌与 Markdown 子集、§4.2 增列表密度、§4.3 增文档形态改版条目并标注旧外壳、§8 实现指针由 flutter_markdown_plus 改为自建渲染器 + pdfx、frontmatter updated 2026-09-29）；`docs/README.md` design 域新增索引行
- [2026-09-29] [验证]: bash scripts/agent-tools/docs-lint.sh → OK: docs/ 全部校验通过（本轮仅设计文档与索引变更，未动 Dart 代码，analyze/test 未跑）

- [2026-09-29] [决策]: 导航架构与页面排布改版定调（多轮 @confirm 收敛，参考 mymind 形态）——①**底部 3 tab（全部 / 工作区 / 设置）+ 底部常驻添加条**（上推展开全屏）+ 侧边栏；**悬浮球删除**（`floating_ball.dart`）：它浮在内容之上形成遮挡，与「chrome 极低」的文档形态基调冲突，职责由常驻条承接；跨 app 系统级悬浮窗不再考虑②**时光机降为主列表的排序 / 分组维度**（`timeline_page` 删除）——代码事实：它与「全部」取的是同一份 `repo.list`，唯一差别是多渲染一层「按天分组」头，且 `daily_metrics` 无数据（健康/日历属 V3）；V3 分化口子须保留，不得在改版中堵死③**AI 分类降为标签筛选维度**（`ai_tags_page` 删除，本就是静态空态占位不读数据）：按 `facets` 过滤，与工作区区分——标签=AI 产出的属性（扁平、只可筛选），工作区=容器（可创建/命名/增删）④**保险箱移入侧边栏并定位修正为「安全域」**（此前将其归为筛选维度的表述是错的，已修正）：已有四道机制——MCP 物理隔离(is_vault=0)、动作层 `set_vault(off)` 需生物识别且 AI actor 直接拒绝、FLAG_SECURE 防截图、备份排除（快照删 is_vault=1 再 VACUUM）；**本轮复用已有 `PrivacyBlurOverlay` 做保险箱视图内默认打码**（用户拍板）；生物识别门与 AES 加密归 **V3**（`local_auth` 尚未引入依赖、内容当前明文存本地，文档与 UI 须如实表述不可让用户误以为已加密）；鉴权发生在「点侧边栏入口」处而非进入后或勾选筛选时⑤主列表**取消横滑 PageView**（类型降为筛选后，横滑翻页与 chips 筛选两套并存是重复交互）⑥**新增「工作区」tab**（对应 mymind Spaces）：条目集合容器、多对多，`workspaces` + `workspace_items` 两表；手动聚合 + AI 聚合（**V2**，端侧 LLM/向量就绪前硬做只会出垃圾聚类）；**按 Human-AI 对称性铁律**，UI 能建则 AI 必能建 → 须配 `WorkspaceCommand`（create/add/remove/rename/delete）走 ItemActionHandler + MCP 工具；多选交互属新增能力（当前列表点条目直接进详情，无多选模式），低成本替代=先只做「详情页加入工作区」；Vault 条目可进工作区但 MCP 侧仍须 is_vault=0 过滤⑦常驻条**仅在主 tab 显示，详情页不显示**（详情页保留自己的底部浮动主按钮，避免两层底部元素）
- [2026-09-29] [变更]: `docs/design/ui-spec.md` 导航层改版落地——§1「零阻力吞噬」改常驻条（点即聚焦、打字即存，高频类型一步到位，路径不得比原悬浮球更长）、§3 导航架构重写（3 tab + 常驻条 + 侧边栏 + mermaid 重画 + 页面去留：inbox 改造 / timeline·ai_tags·vault 删除 / settings 保留 + SecureWindow 由 tab 索引判定改按视图判定的连带改动）、§4.1 时光机降为时间维度（含代码前提：`Repository.list` 排序硬编码 `created_at DESC` 须先加排序参数）、§4.2 主列表（取消 PageView、新增筛选维度语义表：类型/时间/标签/保险箱分别替代原三个 tab）、§4.4 保险箱改安全域（含已有四道机制清单、打码、门禁语义、详情页复用、V3 缺口如实标注）、§4.6 悬浮球删除 + 常驻条 + 上推页三层结构 + 速记路径硬要求 + 显示范围与遮挡处理、§4.7 侧边栏重排（保险箱置顶带锁 / 最近删除 / 任务队列；删 AI 分类·类型分类·设置开关类失效项）、§4.10 AI 分类降标签维度、新增 §4.11 工作区（数据模型/对称性铁律/多选成本/隐私隔离）、§6 组件库更新（`RichTextView` 取代 `MarkdownView`、`PrivacyBlurOverlay`、常驻条取代 `ExtendedFAB`）
- [2026-09-29] [验证]: bash scripts/agent-tools/docs-lint.sh → OK: docs/ 全部校验通过（本轮纯设计文档变更，未动 Dart 代码）

- [2026-09-29] [决策]: 顶部结构与添加入口分工（用户明确）——**顶部 = ☰ 侧边栏 │ 搜索（占主导）│ ＋（下拉菜单：拍照 / 扫描文档 / 导入资源）**；底部常驻条改为**纯速记**（点即聚焦、打字即存），原 📷🖼🎙 高频图标**上移至 ＋ 菜单**。分工依据：拍照 / 扫描 / 导入都是「把外部资源拿进来」的同类动作，速记是「直接写字」，不该混在同一菜单里（此即 mymind 原样：顶部搜索 + ＋，底部 Start typing here）。详情页底部为**基本操作条**（摘要·标签·工作区·分享·删除），与常驻条互斥——常驻条仅主 tab 显示
- [2026-09-29] [决策]: 速记支持**语音录入与文本混合**（用户提出）——硬约束：语音**不在录入时转写**（2026-09-28 拍板：Sherpa 长任务曾堵死整个 AI 队列），只存音频、之后手动触发转写并回填该段 `text`；因此「混合」的语义是**音频块与文本块共存**，而非「语音变文字插入文本」。落点决策：**不新增 collect_mode**（避免动枚举牵动合并窗口逻辑——`TextCollector` 只处理 `merge`），复用 `appendix_json` 段结构承载多段
- [2026-09-29] [变更]: 接口优先落地两处——①**归一化层 `lib/doc/`**：`normalizer.dart`（`NormalizedDoc` / `NormalizeMeta` 覆盖率与降级元信息 / `DocumentNormalizer` 接口 / `DocumentNormalizers` 按扩展名分派 + `normalizeFile` 读文件不抛异常逃逸 / `kNormalizeMaxChars=20000` 长度门控）；`html_to_md.dart`（HTML→Markdown **保结构**：h1-h6 / blockquote / pre / li / 行内粗斜体行内码 / 链接均保留；表格降级为纯文本并计数进 `meta.degradedBlocks`、图片降级为 `[图片：alt]` 文本占位、有序列表统一为 `- `；实体解码**最后统一做**，避免 `&lt;` 变 `<` 后被后续正则误判为标签）；`plain_to_md.dart`（已是 Markdown 则直通，纯文本按空行分段为段落块，**不强造标题**——铁律「宁可样式平，不可吞内容」）②**速记混合**：`AppendixEntry` 扩展 `path` 字段（段级音频；`appendix_json` 是 JSON 列，加字段**无需 schema 迁移**）+ `kSegmentText` / `kSegmentVoice` 来源标记 + `isVoice`；新增 `lib/share/note_composer.dart`（`NoteComposer` 接口 + `DefaultNoteComposer`：textSegment / voiceSegment / rawContentOf / primaryPathOf / hasVoice）。**未转写的语音段不写占位文本进 `raw_content`**（不写「[语音待转写]」，否则污染检索与 AI 上下文），段本身保留在 appendix，UI 据此显示待转写
- [2026-09-29] [变更]: `lib/ai/url_extract.dart` 的 `_decodeEntities` 公开为 `decodeEntities`，供 `html_to_md` 复用（DRY，不重复维护实体解码表）
- [2026-09-29] [验证]: flutter analyze lib/ test/ → No issues found；flutter test → **158/158 全绿**（新增 `test/note_composer_test.dart` 8 条：段来源标记 / 段级 path 往返序列化 / 旧段无 path 解析不受影响 / 未转写语音段不产生噪声 / 主附件取首个语音段 / 纯文本无附件 / 转写回填后进 raw_content / 空列表不炸）；bash scripts/agent-tools/docs-lint.sh → OK

- [2026-09-30] [变更]: 富文本渲染器落地——新增 `lib/ui/rich_text_view.dart`：`RichTextView` 把块树渲染为 widget，**StatefulWidget 缓存解析结果**（长文上限 20000 字，每次 build 重解析会掉帧）；排版令牌按 §2.2 落地（正文 `bodyLarge` + 行高 1.65；h1 22 / h2 18 / h3 16 均 w600；引用左侧 3px 竖线 + 次级色；代码块 `surfaceContainerHighest` + 等宽；列表缩进 20；待办为勾选行、完成态删除线）；段间距用 `Insets.md`(12) 守 tokens 刻度，ui-spec §2.2 的 14 同步改为 12。`lib/doc/rich_text.dart` 补 `inlineToPlain` / `blockToPlain` 纯文本工具（待办回调与预览复用）
- [2026-09-30] [变更]: **移除 `flutter_markdown_plus`**——`item_view_template.dart` 两处 `MarkdownBody` 替换为 `RichTextView`，pubspec 依赖删除并 `pub get`，全仓再无该包引用（停更分叉风险解除，且待办勾选的可行性障碍解除）
- [2026-09-30] [决策]: 待办勾选**本轮只渲染、不做写路径**——核查发现 `TodoMark` 只有数据结构，**全仓没有 hash 计算与写入逻辑**（V2 未实现项）；勾选是写操作，须走动作层命令并按 `todo_state_json` 的 hash 口径持久化，故渲染器只留回调接口（`onTodoToggle` / `todoDone`），为 null 时不可点，口径到 V2 接线时定
- [2026-09-30] [验证]: flutter analyze lib/ test/ → No issues found；flutter test → **179/179 全绿**（新增 `test/rich_text_parser_test.dart` 21 条：标题六档 / 段落 / 软换行 / 引用递归 / 列表聚合 / 有序识别 / 待办三种形态 / 代码块 language / 分隔线 / **表格降级不丢内容** / 空输入 / 未闭合围栏 / 行内粗体优先 / 斜体 / 行内码 / 链接 / 混合不丢字 / 无标记退化 / 未闭合标记原样保留）；flutter build apk --debug → ✓ Built
- [2026-09-30] [环境坑]: 本机构建须带 `ANDROID_SDK_ROOT=$HOME/android-sdk ANDROID_HOME=$HOME/android-sdk`，否则 Gradle 用 `/usr/lib/android-sdk`（NDK 28.2 许可证未接受且目录不可写）报 `LicenceNotAcceptedException`。**`android/local.properties` 的 `sdk.dir` 会被 Flutter 每次构建重写，改它无效**——只能靠环境变量

# 2026-09-30 · 工作区：MCP 工具 + UI 真实化（闭环）

[落点] lib/mcp/tools.dart / lib/pages/workspace_page.dart / lib/pages/home_shell.dart / lib/pages/item_detail_page.dart / test/mcp_tools_test.dart

## 做法
- MCP 工具补齐 6 个（守 Human-AI 对称性铁律：UI 能建则 AI 必能建）：list_workspaces / create_workspace / rename_workspace / delete_workspace / add_to_workspace / remove_from_workspace；toolSchemas + callTool switch 注册，以 CommandActor.ai 走 ItemActionHandler（与 UI 同校验）；add_to_workspace 的 Vault 隔离由动作层 _require(seeVault:) 保证
- 工作区页真实化：WorkspacePage 重写——列出/新建/进入工作区显示条目（复用 ContentCard，点击进详情）；home_shell 改传 repo/handler/caps
- 详情页「加入工作区」真入口：_workspaceHint 由假 SnackBar 改为弹工作区选择对话框 → AddToWorkspaceCommand
- 测试：工具清单断言 18→24 + 补 workspaces 名；新增 MCP 端到端用例（创建→加入→幂等→移除）

## 备注
- 工作区闭环完成：数据层 / 命令层 / handler / MCP / UI 五面齐备
- 备份是否携带 workspaces + workspace_items 两表待拍板（倾向进备份：属用户事实数据非派生）
- 第5步引用模式「摄入改 ref」仍待 SAF 实测（本机无设备），attach_state 状态机与可达性检测已就位，摄入默认仍为 owned 是刻意保守

## 断点
- [断点] 五步改版（排序参数 / 导航层 / 详情文档化 / 归一化落库 / 引用模式地基）已全部提交；工作区闭环本批完成。剩余：①**引用模式「摄入改 ref」**需实测 file_picker/image_picker 能否拿 SAF 可持久化 URI（本机无设备，阻塞项）②**备份携带工作区两表**待拍板 ③待办勾选写路径（V2，TodoMark 生产侧未实现）④PDF 转换器（pdfx）+ 文档类型支持矩阵

---

# 2026-09-30 · 内容管线收尾：引用模式落地 + 备份携带工作区表 + PDF 文本提取（pdfrx）

[落点] lib/share/share_intake.dart（referenceMode 默认 ref 不复制存源 URI）/ lib/action/commands.dart（CollectCommand.attachState）/ lib/action/item_action_handler.dart（引用模式生效）/ lib/doc/attach.dart（Attach.reachable 兼容 content://）；lib/data/repository.dart（restoreFrom 4→6 表）；lib/doc/pdf_to_md.dart（PdfNormalizer）/ lib/doc/normalizer.dart（注册 DocumentNormalizers）/ pubspec.yaml（pdfrx ^2.6.5）+ pubspec.lock

## 做法
- **引用模式（摄入改 ref）**：`ShareIntake.referenceMode` 默认 true——分享进来的附件**不复制进 app 私有目录**，直接存源 URI（含 `content://`）并标 `attachRef`；`CollectCommand.attachState` 把状态机（ref/owned/lost）写入 appendix_json 段；handler 生效路径据 attachState 走引用而非 owned 复制；`Attach.reachable` 扩展支持 `content://`（SAF 授予的临时/持久读权限 URI）。与 09-29 已落地的 attach_state 列 + Attach.reachable 地基衔接。
- **备份携带工作区两表（用户拍板）**：`restoreFrom` 恢复表由 4 张（inbox_items/ai_task_queue/daily_metrics/drafts）扩到 6 张，新增 workspaces / workspace_items——属用户事实数据非派生，按用户拍板进备份（与 Vault 排除、派生向量清空互不冲突）。snapshotTo 侧不变。
- **PDF 文本提取（pdfx→pdfrx 选型）**：`pdfx` 2.x 实测仅渲染无文本 API；`pdf_text` 在本项目 Dart 3.13 下依赖 `http ^0.13.0`，与 `package_info_plus ^10.2.1` 拉的 `http ^1.6.0` 冲突且 `<0.5.0` 无 null safety，无法解析；`pdf_render` 仅渲染不适用。选定 `pdfrx ^2.6.5`（底层 PDFium，当前 Flutter 3.13/Dart 3.13 下唯一既活跃又支持文本提取的库）。新增 `lib/doc/pdf_to_md.dart`（`PdfNormalizer`：`loadDocumentFile` → 逐页 `page.loadText()` 拼 `fullText`，按行特征启发式判标题，标 DEGRADE），注册进 `DocumentNormalizers` 按 `.pdf` 分派。

## 备注
- 三家 PDF 库底层皆 PDFium native，体积差别主要在 Dart 面；我们仅用 pdfrx 的 `loadText`，未引入其渲染 widget，Dart 侧多出的渲染代码不进使用路径，包体/启动影响有限。
- 引用模式默认开启，但 `takePersistableUriPermission` 持久化与 content URI 跨会话可达性依赖 Android SAF，**本机无设备无法真机验证**——代码已就绪但属"真机待验证"，未实测前引用条目可能随源 app 回收权限而失效。设计文档（content-pipeline.md）已标注此阻塞。
- docs/design ui-spec.md 与 content-pipeline.md 共 4 处 `pdfx` 选法已更正为 `pdfrx`，并注明"纯文本无字号/位置、按行特征猜标题"。

## 断点
- [断点] 三块已落地全绿待提交（analyze 0 / test 全绿）；提交后真机验收——①引用模式 SAF 持久化与 content URI 可达性（本机无设备，阻塞项）②PDF 文本提取对文本型 PDF 覆盖（扫描件返回空、UI 已据 note 明示）③备份恢复 workspaces/workspace_items 两表闭环。遗留：待办勾选写路径（V2，TodoMark 生产侧未实现）、文档类型支持矩阵、iOS/鸿蒙适配

---

# 2026-09-30 · 超长文本处理 Phase 0+1：去截断全量存储 + 渲染虚拟化

[落点] lib/doc/normalizer.dart（kNormalizeMaxChars 20000→1<<26）/ lib/ui/rich_text_view.dart（Column→ListView.builder + richBlocksOf/buildRichBlock 抽出）/ lib/ui/item_view_template.dart（视图函数返回 List<Widget> sliver + bodySlivers）/ lib/pages/item_detail_page.dart（ListView→CustomScrollView + SliverList 真虚拟化 + 顺手修重复 _typeActions）/ docs/design/content-pipeline.md（3 处「截断」更正为全量存储+虚拟化）

## 做法
- **Phase 0 去截断**：`kNormalizeMaxChars` 由 20000 改为 1<<26（≈6700 万字符，实际不触发）；html/plain/pdf 三处 normalizer 的 `s.length > maxChars` 截断逻辑因常量放大而永不触发，human_md 现在存全量。写库层 `ItemDocNormalizer.fieldsFor` 直接写 `doc.markdown`，无二次截断，内容不再丢失。
- **Phase 1 渲染虚拟化**：`RichTextView` 内部由 `Column` 改为 `ListView.builder`（解析结果缓存保留，避免重解析掉帧）；抽出 `richBlocksOf` / `buildRichBlock` 供复用。详情页 `ItemViewTemplate` 视图函数由返回单 Widget 改为返回 `List<Widget>`（sliver 兼容），文本类正文走 `SliverList`、媒体类走 `SliverToBoxAdapter`；`item_detail_page` 主体由 `ListView(children)` 改为 `CustomScrollView(slivers)`，让正文 block 成为 sliver items——数万字长文只构建可视区 widget，真正虚拟化（非嵌套 shrinkWrap 伪虚拟化）。`_appendix` 内的 RichTextView 因嵌在 Column 传 `shrinkWrap:true`。顺手修了原详情页 `_typeActions()` 被调用两次的重复 bug。

## 备注
- Phase 0/1 是用户超长文本方案（Chunking / Async / Virtualization）的前两步；后端 AI/向量化瓶颈（Context 溢出）尚未触及：向量分块（item_embeddings.chunk_index 已留结构）与嵌入引擎、Isolate 异步解析、Map-Reduce 摘要/RAG 属 Phase 2/3/4，仍待做。
- 截断移除后，`NormalizeMeta.truncated` 字段及 `ItemDocNormalizer.coverageText` 的「超出上限已截断」分支实际不再触发，保留为极端兜底（常量仍有上限语义）。

## 断点
- [断点] Phase 0+1 已落地全绿（analyze 0 / test 全绿）；超长文本「渲染不卡、内容不丢」达标。剩余：Phase 2 归一化分块（标题层级/500-token 窗口，消费侧按需切）、Phase 3 Isolate 异步解析、Phase 4 向量引擎落地 + RAG/Map-Reduce 摘要。遗留：待办勾选写路径（V2）、文档类型支持矩阵、iOS/鸿蒙适配。
- [2026-09-30] [变更] 全部页顶栏自动隐显 + 工作区卡片化（D1/D2 台账确认后落地）：①D1——inbox 主列表 AppBar 拆入滚动流（SliverAppBar floating+snap 非 pinned 非 overlay），CustomScrollView + SliverMasonryGrid.count(itemBuilder+childCount)，向下滚内容隐藏/向上滚轻微反向即弹回/顶部恒显示；一体块抽 _topBarRow 与保险箱视图共用，空态/加载态改 SliverFillRemaining 保底顶栏可达；保险箱视图与搜索页不参与（D1 范围）②D2——工作区两层卡片化：列表层 GridView.count 2 列（卡=工作区：名字+条目数+封面拼贴最多 3 图等宽裁切 cacheWidth 480，无图退首条 preview，空区图标；_WsEntry/_WsPreview 逐工作区取条目），条目层 MasonryGridView.count 双列与全部页同语言；顺手修空态文案「右上角」→「右下角」③ui-spec §4.2 补 D1 两条并清搜索页改版前残留（chips 固定区/旧缩略图行/重复片段）、§4.11 补 D2 页面形态、frontmatter updated=2026-09-30。
- [2026-09-30] [验证] flutter analyze → No issues found (8.5s)；flutter test → 213 全绿；bash scripts/agent-tools/docs-lint.sh → OK。
- [2026-09-30] [变更] 修「点开便利贴整个功能消失」：根因=home_shell 的 Positioned 仅 bottom 锚点、Stack 未收紧高度约束，展开态 Column+Expanded 触发 unbounded flex layout 异常整树渲染失败（release 下无提示，analyze/单测全绿拦不住）；修法=Positioned 四边拉满给有界紧约束（键盘让位仍由 Scaffold resize 承担、零高度手算），收合态 52px 拉手经 Align 拿松约束（紧约束下 Container 固定高会被 clamp 成整屏）；新增 test/quick_note_bar_test.dart 复刻挂载结构 pump 展开态防回归。顺带修 workspace_test 潜伏 flake：同毫秒 createdAt 打平致严格倒序断言随机炸，造数跨毫秒。
- [2026-09-30] [验证] flutter analyze → No issues found (9.3s)；flutter test → 215 全绿（新增便利贴布局回归 2 条）。
- [2026-09-30] [变更]: 全部页下拉刷新动画位移：RefreshIndicator displacement=状态栏+kToolbarHeight+lg，spinner 落到搜索条以下内容区上缘（方案1 拍板）
- [2026-09-30] [验证]: flutter analyze lib/pages/inbox_page.dart → 0 issue；flutter test test/workspace_test.dart → 10 全过
- [2026-09-30] [变更]: 便利贴三改：①写作区幻影滚动修复（工具层让位改视口级 Padding，不再算进滚动内容）②收合拉手上滑跟手拽出（TweenAnimationBuilder 拖动零时长跟随+松手回弹/过阈值展开）③工具层新增格式行（标题 ## 切换 + 粗体 ** 包裹，Markdown 子集语法，不做高亮）
- [2026-09-30] [验证]: flutter analyze (quick_note_bar + test) → 0 issue；flutter test test/quick_note_bar_test.dart → 5 全过（新增上滑拽出/标题/粗体 3 个回归用例）

## [2026-09-30] 便利贴「跟手渐展」重构（方案 A，用户拍板）
- 现象：上滑拽出时只有 52px 拉手跟手上移（Transform.translate 平移），松手后整屏面板瞬跳出现——头部先走、身体后到。
- 根因：拖动期只平移收合拉手，展开是 false→true 状态突跳，两形态间无连续形变。
- 修法（quick_note_bar.dart）：拖动从「平移」改「控高度」——`_progress ∈[0,1]` 连续进度，高度 = peek + progress×(可用高−peek)，头部+身体同一容器一起长出；`_morphSheet` 三分支：静止 0=纯拉手、静止 1=满幅面板（无 Opacity 包裹，命中区与单态一致），中间态高度增长+内容淡入（_contentFadeStart=0.35 起）+24px 上移且 IgnorePointer 防幽灵点按；TweenAnimationBuilder 双态复用（拖动 Duration.zero 跟手 / 松手 260ms easeOutCubic 补间），行程 `_travel` 按可用高动态算，`_peekMaxDrag` 平移上限废除。
- 连带修「点工具按钮面板坍缩」：外层 GestureDetector 的 onVerticalDragCancel 无展开态门控，点面板内按钮时拖拽识别器竞技场落败触发 cancel→_progress=0→面板被拽回收合；补 `if (expandedNow) return` 门控。定位手段：单测试内「点按展开→点保存」最小复现 + 各状态变更点 DBG 日志锁定 dragCancel 触发链。
- 连带修「态开形未开」：initState 静态恢复时 `_progress` 与 `_expanded` 同源恢复（否则 Activity 重建后 `_expanded=true` 而 `_progress=0`，面板态与形变态不一致）。
- 测试影响：quick_note_bar_test 原有用例全过；收合静止态不再渲染隐形展开内容（旧版 opacity 0 的幽灵树是屏外溢出告警根源）。
- 交付：analyze 0 / test 218 全绿。真机手感（跟手灵敏度/淡入阈值/补间时长）待侧载验证。

## [2026-09-30] 修「首页内容区不能点击和滑动」
- 现象：收合态下整个首页列表不可点、不可滑。
- 根因：QuickNoteBar 顶层 `Material(color: Colors.transparent)`——带颜色的 Material 即使全透明，其 RenderMaterial 在整个边界内仍不透明地吸收命中测试；Positioned 四边拉满使其覆盖整屏，列表点击/滑动全被挡。二分定位：纯 Container 52px 挡（CASE2-4 失败）→ 拆层后定位到 Material 层（CASE5/6 过、CASE7/8 挡，唯一变量即 Material 颜色 vs type:transparency）。
- 修法：改 `Material(type: MaterialType.transparency)`（透传命中的正确姿势），一行修复。
- 验证：新增命中探针测试（40 条列表，收合态点「条目0」tapped=true、拖「条目2」滚动位移 296→16）通过后删除；全量 analyze 0 / test 218 绿。
- 注意：此 bug 自速记条替换悬浮球起就存在（非本轮渐展引入），属命中测试盲区。

## [2026-09-30] B1：展开态面板头部固定在搜索框水平带（修顶栏被状态栏遮挡）
- 现象：便利贴展开后顶栏（收起箭头/日期/保存）顶进状态栏（用户复述「头部被顶部遮挡」，拍板 B1：头部固定在搜索框位置）。
- 根因：QuickNoteBar 挂在 Scaffold body 内，body 的 MediaQuery.padding.top 已被 Scaffold 消费（=0），`media.padding.top` 避让形同虚设——探针实测顶栏 y=21.5 < 状态栏 40。
- 修法（quick_note_bar.dart 两处）：①状态栏高度改取 `MediaQueryData.fromView(View.of(context)).padding.top`（未消费的原始值），`topInset = statusBar + Insets.sm`，`available = body高 − topInset`；②_morphSheet 静止展开分支补显式 `height: available`（省略会吃满 Positioned 整屏约束，修复无效的连带坑）。
- 验证：探针顶栏 y=69.5 ≥ 40 不再遮挡；转常驻回归 test/quick_note_topbar_test.dart；analyze 0 / test 219 绿。真机侧载待确认头部与搜索条水平带对齐的观感。

## [2026-09-30] 修「便签头部跟着搜索条一起隐藏」+ 解耦回归
- 现象（真机）：展开态面板头部不可见，用户复述「搜索框会隐藏连带便签头部也隐藏；便签头部不应隐藏」。
- 根因：B1 首版用 `MediaQuery.of().size.height`（整屏高）算面板最大高，但面板在 Scaffold body 内、底部有 NavigationBar——面板比 body 高出「底栏高 − topInset」，Align(bottomCenter) 把超出部分顶到 body 上沿之上，头部被推到状态栏外（视觉=头部消失，恰似跟着搜索条隐藏）。测试未抓到因测试脚手架无底栏。
- 修法：build 顶层移除屏高手算，改 LayoutBuilder 取 body 实际约束：`available = constraints.maxHeight − topInset`；静止展开/中间态高度随之前移正确，顶缘精确锚在搜索框水平带。
- 解耦取证：便签面板在 HomeShell Stack 第 2 子节点（页面之上）、锚点为屏幕静态位置，与搜索条（InboxPage 自身 CustomScrollView 内 SliverAppBar floating+snap）零数据耦合——搜索条隐显不会盖住或移动便签头部；quick_note_topbar_test 增补「滚动列表（搜索条隐藏）后头部位置不变」回归断言。
- 交付：analyze 0 / test 219 绿。真机侧载确认头部恒显于搜索条水平带。

## [2026-09-30] 拍板更新：展开态面板顶到状态栏（B1 小间距取消）
- 用户看真机后拍板「完全展开后要顶到状态栏」；搜索框样式不改（首页顶栏本就是 mymind 同款：☰ 嵌入搜索长条 + 右侧橘红 ＋ 块，inbox_page._topBarRow）。
- 修法：quick_note_bar.dart `topInset = statusBar`（去掉 B1 的 `+ Insets.sm`），顶缘 = 状态栏下沿贴满；LayoutBuilder 约束与渐展行程随动，动画连续性不变。
- 交付：analyze 0 / test 219 绿（含 quick_note_topbar_test 顶栏不进状态栏 + 滚动解耦断言）。真机侧载确认贴满观感。
- [2026-09-30] [变更]: 真机侧载验收行内媒体块 MVP 五项全绿（用户逐项确认：图片首帧定版、双音频块互斥切换、.amr 降级文件卡、行内视频全屏浮层、滚动零跳动）。验收环境：桌面自建回环媒体服务器（python http.server:8766 + adb reverse，零外网依赖）+ 分享 intent 注入 markdown 验收条目；配套环境变更——pubspec 6006→6007（真机已有 6006 需覆盖安装）、AndroidManifest 挂 network_security_config（仅放行 127.0.0.1 回环明文，验收/桌面联调专用，外网仍强制 TLS）
- [2026-09-30] [变更]: 修 firstUrl 尾部括号剥离（真机验收发现的真 bug）：url_extract 的 https?://\S+ 贪婪匹配把 markdown [a](url) 的结尾 ) 吃进 URL，OG 预取 404；改剥不配对尾部 )（配对括号的合法 URL 如维基词条不受影响），og_metadata_test 新增 firstUrl 3 例
- [2026-09-30] [验证]: 真机人工五项确认全绿；flutter analyze → 0 issue；flutter test 全量 1 例闪失（long_text_phase Isolate 时序，单跑 11/11 绿排除回归）、og_metadata 13/13 绿（含新增 firstUrl 3 例）

## [2026-09-30] 便签页多媒体编辑（作曲器）：媒体不分散保存（用户四点拍板落地）
- 需求与拍板：便签内文本/图片/录音混排且保存为**一个**条目不分散（视频 V2）。四点裁决——①本地行内媒体 url=`local://<documents 内相对路径>` 相对标记（绝不写绝对路径，推翻 rich-text-media.md 原「本地一律顶级附件」并修订 SSOT §2/§5/§7；resolver 见 attachments.dart 的 resolveLocalMediaSrc）②拍照/录音语义反转：直接出独立卡片→**就地插入本条** ③含媒体便签豁免合并窗口（合并链只对纯文本成立）④MVP 不含视频。
- 落地：`lib/share/note_composer.dart` 重写为段模型（NoteText/Image/AudioSegment）+ `serializeNoteMd`（标准 md 媒体行，三出口护栏继承；旧 appendix 语音段骨架经查零调用方，一并 supersede）；`quick_note_bar` 展开态改**分段作曲器**——媒体在光标处拆段插入、媒体后恒有文本段、MediaAudioBar 复用（便利贴作用域 AudioPlaybackService，单实例红线不破）、草稿静态留存含媒体段、移除媒体段删私有副本文件（孤儿防线）；`InlineMediaImage` 本地文件支持（FileImage 首帧探测同一定版机制 + GoodshareImage.file）；保存路由：纯文本走 `TextCollector.collectText`（合并窗口不变）/ 含媒体直发 `CollectCommand(note, scatter, humanTitle=首文本行兜底「图文便签」)`。
- 测试踩坑（重要）：①widget 测试内 sqflite_ffi 写链在 FakeAsync 下推不完——需「`runAsync` 放行真实时钟 → `pump` 推假区微任务」**交替循环**到 UI 反馈出现，单独任一都卡死（pumpAndSettle 10 分钟超时的根源）；②`record` 插件 `AudioRecorder` 构造的异步 MissingPluginException 落在「测试完成后」误判用例失败——setUpAll mock 其方法通道（com.llfbandit.record/messages）。
- 验证：analyze 0 / 全量 309 绿 / arch-guard 7 条过（R4 抓作曲器裸 Image.file→改 GoodshareImage）/ docs-lint OK。文档联动：rich-text-media.md §2 写入口径修订 + §5 排期（MVP+ 便利贴作曲器）+ §7 验收行；ui-spec §4.6 便利贴多媒体语义（顺带修正落后于便利贴改版的旧「纯速记常驻条」描述）。真机待验：拍照/相册/录音插入→保存一条→详情混排渲染→草稿跨 Activity 重建恢复。

---

## [2026-09-30] 文档口径统一到 local://（后台跑全量）

- 背景：`rich-text-media.md` §2 与代码（note_composer.dart 写入口径 + attachments.dart 的 `resolveLocalMediaSrc`/`toLocalMediaSrc`）早已采用 `local://<documents 内相对路径>` 相对标记、绝不写绝对路径；但 ui-spec §4.6 仍残留「url = app 私有目录绝对路径，与 `rawFilePath` 同口径」旧口径，与 SSOT 矛盾。index 等位置的 `rawFilePath` 是**条目主附件字段**（inbox_items.raw_file_path），属不同概念，不动。
- 修正：`docs/design/ui-spec.md` §4.6 行内媒体 url 口径改为 `local://` 相对标记；`context/epics/goodshare/memory.md` 进度行与 `devlog.md` 便签作曲器条目①的「绝对路径/rawFilePath 同口径」同步改为 `local://` 相对标记，全口径对齐 SSOT 与代码。
- 验证：后台脱离终端跑 `flutter test`（日志 /tmp/gs_test_full.log）→ **全量 314 绿**（All tests passed!）；analyze 0 issue 未跑（本批仅文档改动，无 Dart 代码）。

## [2026-10-01] 便签内嵌视频（附件态）落地：双路径 + 门槛校验
- 拍板（评估轮用户三裁决）：①非 MP4 策略=**扩大原生白名单 mp4/mov 直入库不转码**，.webm/.avi/.mkv 等硬拦截提示「暂不支持该格式」，**彻底抛弃 FFmpeg 软编软解**（将来压缩走系统硬件编码器另期）②封面=沿用图标占位卡（封面提取维持 V2，todo #37）③相册大小阈值=100MB。
- 落地：新建 `lib/share/note_video_policy.dart`（门槛常量集中：60s 直拍 maxDuration / 5min 相册非阻断 / 100MB 拦截 / mp4/mov 白名单；`checkNoteVideoAlbum` 后置校验 + `probeVideoDurationMs` 走 FFprobeKit 只读元数据——probe 非 decode，不违拍板）；`note_composer.dart` 增 NoteVideoSegment（默认 label「视频」，序列化 `[label](local://…)` 命中 parse 视频白名单）；`quick_note_bar.dart`：_MediaSeg 的 bool audio 升三态 NoteMediaKind(image/audio/video) + 草稿行 'v' 编码 + 视频入口按钮→二选一 BottomSheet（相册首位）→_pickVideoWithGate 统一校验（拦截类 SnackBar、>5min AlertDialog「仍要添加」）+ 视频占位卡（保存后详情页 VideoBlock 全屏浮层播放）。
- 验证：analyze 0 / 全量 315 绿（note_composer_test 增视频段序列化 + parse 回块树 VideoBlock 用例）。真机待验：相册选 mp4/mov/边缘格式三分支、直拍 60s 自动停、>5min 提示流、草稿含视频段跨 Activity 重建、保存后详情浮层播放。
- SSOT 修订：note-video.md §2 格式行（mp4/mov 白名单拍板）、§6（SAF 前置实测可跳过：image_picker 本身复制进沙箱=即降级预案）、§7 落点补 note_video_policy.dart；todos #11 完成勾销。

## [2026-10-01] 图片标注对象化改版第 1 批（image-markup.md：schema/渲染纯函数/画布状态机/手势锁）

- 背景与切批（用户确认架构后开工）：标注从「手指涂画」升级「矢量对象操作」，操作与呈现分离。第 1 批锁**架构不可逆部分**——schema 扩展与渲染纯函数接口先定死；标注列表/反馈栈（loupe/吸附/触觉）留第 2 批，文字标注/导出合成/隐私遮挡 Toggle 留第 3 批（schema `filled` 位已就绪）。
- 落地（分层按 goodshare-arch「UI 只持交互态」）：
  - `lib/models/annotation.dart`：增 `filled` 实心填充态（仅 rect 有效，隐私遮挡=圆角矩形实心态，JSON 缺省不写字段向后兼容）；`'stroke'` 读侧归一到 `free`（笔迹留位，写侧维持旧口径）。
  - `lib/models/annotation_geometry.dart`（新建，全部纯函数）：`assignPinNumbers`（**序号与身份解耦**——schema 只存 ID，序号渲染时按列表顺序算，删中间 pin 自动回补防雪崩）、`anchorsOf`（锚点最小集：箭头/矩形两点、pin/文字单点、free 全轨迹）、`hitAnchor`（就近吸附，倒序遍历=Z 轴最上层优先）、`hitObject`（矩形包围盒/箭头线段距离/pin 半径/笔迹逐段）、`withAnchor`（锚点重算原地副本不换身份）、`translated`（整体平移）。
  - `lib/render/annotation_painter.dart`（新建）：`paintAnnotations` 单一入口服务三消费方（§5.1 纪律）——画布叠加 / loupe（`onlyIds` 过滤只画当前操作标注）/ 导出合成（离屏 Canvas 同链路出图）；线要素淡黑投影 + 文字半透明底框（对比度纪律）；选中态叠加（锚点小圆点、锚点级单点放大高亮其余变暗）。
  - `lib/ui/annotation_canvas.dart`（新建）：两级选择状态机（对象级↔锚点级，层级回退单向，唯一出口点空白/点本体）+ **手势排他锁**（命中优先级 锚点热区>对象本体>画布；选中后 `InteractiveViewer.panEnabled` 翻转锁平移，双指缩放恒可用；8dp 逃生口=选中判定只发生在 tap）；AnnotationToolbar 轻量工具栏（箭头/矩形/序号，拖拽生成两点、pin tap 单点生成，误触两点重合不产出）。
  - `lib/ui/image_annotator.dart` 重写为编辑宿主（旧涂画实现 supersede）：装配画布+工具栏+调色板，持久化走 AnnotationStore——宿主零几何判定零 json。
- 测试（test/annotation_object_test.dart，10 用例）：schema filled 往返与缺省不写、stroke 归一、序号防雪崩回补（删②③→②）、schema 无 index 字段、锚点最小集、就近吸附容错、包围盒/线段命中与重叠取最上层、对角锁定/整体平移（浮点 closeTo）、离屏渲染三消费方（全量/onlyIds/toImage）。
- 验证：analyze 0 / 全量 329 绿（+10）。真机待验：三工具生成与两级选中手感、选中锁平移/8dp 逃生口竞争、缩放后命中坐标、pin 删除回补显示。
- SSOT：image-markup.md §9 落点表补四个文件 + §10 第 1 批验收行（含未含清单）。

## [2026-10-01] 图片标注对象化改版第 2 批（标注列表 + 精度反馈栈：吸附/触觉/loupe）

- 落地（继续对齐「UI 只持交互态」分层）：
  - **吸附纯函数**（`annotation_geometry.dart` 追加）：`snapAnchorPoint`（x/y 独立解算：图片 0/0.5/1 三线 + 其他标注锚点坐标为参照，返回修正点 + SnapLine 列表，参照系排除被拖标注自身）；`snapOrthogonal`（八向 45° 射线修正，弧度容差）；`SnapLine`（竖/横 + 触觉语义）、`SnapHaptic` 两档（orthogonal=selectionClick / align=lightImpact）。
  - **画布接入**（`annotation_canvas.dart`）：锚点拖动走吸附解算（对齐与正交叠加，正交优先）；触觉**边沿触发**（`_lastHaptic` 去重，不随帧连发）；吸附线垫底渲染细白线，松手/取消即隐（`_snapLines` 清理三处：up/cancel/objectDrag 收尾）。
  - **loupe**（`lib/ui/annotation_loupe.dart` 新建）：复渲染法（FittedBox+Transform.scale 放大原图层，**非截屏**，§5.1 纪律）；镜中三层=原图+当前操作标注本体线（`onlyIds` 复用第 1 批 paintAnnotations 纯函数——三消费方纪律兑现）+ 十字准星；贴顶翻下方/贴左翻右侧（悬浮层边界碰撞）；**仅锚点级拖动浮现**（对象级不浮现，§5），画布 Stack 挂载、拖动结束清 `_fingerLocal` 即隐；`AnnotationCanvas` 增 `background` 参数供镜中复渲染原图。
  - **标注列表**（`lib/ui/annotation_list.dart` 新建）：§6 四件事（选中/删除/改色=色板循环/进入调整），防膨胀纪律（无搜索/折叠/分组/锁定/重排）；pin 行首序号角标（`assignPinNumbers` 动态算，与画布同源）；行内 trailing 三钮；`Scrollable.ensureVisible` 双向联动列表侧。
  - **宿主装配**（`image_annotator.dart`）：持受控 `_selectedId` 透传列表↔画布（§6 双向联动打通：图上选中→列表行滚动高亮、列表点行→画布高亮）；列表竖屏收底部抽屉（280h，选中不关抽屉可连续管理）；「调整」= 选中并 pop 抽屉露出画布拖锚点；删除清选中；画布传入原图 `background`。
- 测试（test/annotation_snap_test.dart，7 用例）：边缘/中心吸附修正+线、对齐其他标注参照（含自身不吸附）、超容差原样、横竖双线同帧、正交 45°/轴向/超容差、SnapLine 两档语义、loupe 渲染链路回归（onlyIds 复用）。
- 验证：analyze 0 / 全量 336 绿（+7）。真机待验：吸附手感与容差观感、触觉两档区分度、loupe 跟手与翻转、抽屉列表联动流畅度。
- SSOT：image-markup.md §11 第 2 批验收行（含未含清单：文字标注/导出合成/隐私遮挡 Toggle/横屏右栏列表留第 3 批）。

## [2026-10-01] 图片标注对象化改版第 3 批（文字标注 + 导出合成 + 隐私遮挡 + 横屏右栏，三批收官）

- 落地（分层不变：UI 只持交互态，合成/导出下沉 render 层）：
  - **隐私遮挡**（§3 不新增工具=rect 实心态）：工具栏「遮挡」快捷入口（rect 生成默认实心）+ 选中 rect 的空心/实心 Toggle（`AnnotationToolbar` 增 onToggleFill/fillAvailable/currentFilled；宿主 `_toggleFill` 有选中改对象、无选中切生成态）；安全边界口径「展示级遮挡非数据级销毁」随 tooltip 与 SSOT 保留。
  - **文字标注**（§7）：工具栏「文字」工具，tap 落点单点生成（`AnnotationCanvas` up 判定放行 text 单点）→ 宿主弹输入确认才入列（取消/空文本不产出）；渲染零新增——`paintAnnotations._paintText` 既有 TextPainter 动态宽高（maxWidth 0.8 图宽换行）+ 半透明底框即 §7 形态，单锚点可拖可整体移。
  - **导出合成**（§7 瞬时合成）：新建 `lib/render/annotation_export.dart`——`exportCompositedImage` 离屏 PictureRecorder 先画原图再走 `paintAnnotations` **同一纯函数**（三消费方纪律第三消费方兑现），PNG 落 `documents/annotations/export/` 新文件（长边 2048 限边）；源图与 annotations 数据不动；解码失败原样抛出不静默（R1）；宿主「导出分享」按钮 share_plus 出系统分享，防重入转圈态，无标注先提示。
  - **横屏右栏列表**（§9）：宿主 `OrientationBuilder` 方向感知——横屏 Row 画布+240dp 右栏常驻 `AnnotationList`（进入调整就地选中不 pop），竖屏保持抽屉形态；「标注列表」入口按钮随方向显隐。遗留：横屏沉浸式全屏文字输入（当前通用对话框，§7 横屏降级的完整形态随真机横屏验收再补）。
- 测试（test/annotation_export_test.dart，8 用例）：实心渲染出图、filled Toggle 往返、安全边界 schema 面（filled 不改 points/type）、文字渲染出图、空文字/无点防御、文字单锚点最小集、导出源图缺失原样抛出、产物新文件落 export 目录且源图 stat 不变（path_provider mock 系统临时目录）。
- 验证：analyze 0 / 全量 344 绿（+8）。
- SSOT：image-markup.md §12 第 3 批验收行（改版三批收官声明 + 遗留演进位：横屏沉浸输入/数值微显/笔迹工具）。

## [2026-10-01] 标注遗留演进位销项：笔迹工具 + 横屏沉浸输入（用户拍板两项即做）

- **笔迹工具**（§3 候选→正式落地，成本最低因全链路第 1 批已备）：工具栏「笔迹」入口（`_tool(context, Icons.gesture, '笔迹', AnnotationType.free)`）；画布 free 生成态改**矢量一笔采点**——`_onPointerMove` creating 分支按类型分派：free 轨迹追加（与上一点 <0.002 归一化重合不重复采）、其余两点替换。命中/锚点/渲染零新增（hitObject 逐段线距离、anchorsOf free=全轨迹、paintAnnotations drawPath 分支均第 1 批就绪）；schema `'stroke'` 留位兑现为 free 同模型，写侧维持 'free' 旧口径。工具集至此=四工具+笔迹全齐（§3 表格全覆盖）。
- **横屏沉浸式文字输入**（§7 横屏降级完整形态）：宿主 `_askText` 方向感知两形态——竖屏对话框不变（键盘不遮画布）；横屏走 `_ImmersiveTextInput` 全屏毛玻璃（BackdropFilter blur 16 + surface 60% 底 + 大输入区 expands，完成/取消显式双钮，PageRouteBuilder opaque:false 推入）。不做「回竖屏」规则碎片化。
- 测试（test/annotation_stroke_test.dart，4 用例）：free 轨迹逐段命中/远点不命中、anchorsOf 全轨迹、withAnchor 单点重算保身份、drawPath 三消费方出图。
- 验证：analyze 0 / 全量 348 绿（+4）。
- SSOT：image-markup.md §13 遗留位销项（笔迹+沉浸输入 ✅；仅剩吸附数值微显低优按需）。

## [2026-10-01] 真机验收反馈修复：视频门槛通过不插入（null 语义误解）+ 三项连带
- 现象（真机首轮验收）：①test.mp4/test.mov 相册添加后**无视频卡** ②保存后详情点视频「视频加载失败」 ③用户提议草稿态视频应可预览确认。
- 取证路径：uiautomator dump 对 Flutter 语义不可见 → run-as 拉 DB + shares 目录对账 → ffmpeg 体检设备上文件。**「加载失败」根因是测试媒体本身**——首轮生成的 long_330s.mp4 被 libx264 编成 h264 High 4:4:4（yuv444p），Android 硬解不支持；test.mp4 有 `-pix_fmt yuv420p` 所以没问题。教训：**造测试媒体必须显式 `-pix_fmt yuv420p`**（testsrc 源在 ultrafast 下会被选成 yuv444p）。
- 真 bug ①（无视频卡）：`checkNoteVideoAlbum` 约定「返回 null = 校验通过」，但 `_pickAlbumVideo`/`_captureVideo` 把 null 当「已取消」直接 return——mp4/mov 通过校验后**从不执行插入**，只有 >5min 非空 check 走弹窗后插得进去。修法：null 分支显式 `_insertCheckedVideo()`；gate 入口清 `_pendingVideoPath` 陈值（取消/失败不得残留上一次待插路径）。
- 真 bug ②（孤儿副本）：白名单外 .webm 拦截前已 `copyToAppDir`，设备实测确认遗留孤儿。修法：拦截类 SnackBar 后异步删除已拷副本（[DEGRADE] 留痕）；顺手 run-as 清掉设备上 10 个测试孤儿。
- 增强：作曲器视频卡**点按可预览**（用户提议）——复用详情同一全屏播放器与 `local://` 链路，草稿态即给「添加了什么、能不能播」的确认机会；播放器失败文案带真实原因（R1，media_blocks 与 item_view_template 两处），yuv444p 这类硬解问题用户可直接看到。
- 测试：quick_note_bar_test 新增 2 用例（mp4 通过即插入 / webm 拦截提示+无孤儿副本）。踩坑：①ffmpeg_kit 事件通道 `flutter.arthenica.com/ffmpeg_kit_event` 在测试环境无实现，listen 的 MissingPluginException **逃逸出** probeVideoDurationMs 的 try/catch（异步事件回调抛出），setUpAll mock 之 ②unawaited 的删除链是 FakeAsync 区续体，断言须 runAsync（真实 IO）+ pump（微任务）交替推进——与保存路由用例同口径 ③草稿静态留存跨用例泄漏（有意设计），用例顺序敏感：拦截用例须先于插入用例。
- 验证：analyze 0 / 全量 317 绿 / arch-guard 7 条 / docs-lint OK。真机已装 6007 修复版、yuv420p 测试媒体已重推、孤儿已清。真机待复验：mp4/mov 添加出卡、直拍、>5min 确认流、100MB 拦截、草稿预览、详情播放。

## [2026-10-01] 60s 直拍进度感知：自建拍摄页＋进度环（用户拍板）
- 动因：用户提出「拍摄 60s 自动停放个进度条，用户可以明确感知」。评估发现**原系统相机路径做不了**——image_picker 拉系统相机（源码实锤：ACTION_VIDEO_CAPTURE + MediaStore.EXTRA_DURATION_LIMIT），录制界面是相机 Activity，Android 不允许普通 App 在其上叠 UI；系统相机自带计时无倒计时、被掐断无预告。三选一（保持系统相机 / 记入待办 / 自建拍摄页）经用户拍板选**自建拍摄页＋进度环**。
- 落地：新增 `camera ^0.12.1` 官方插件（用户批准）+ `lib/ui/note_video_capture_page.dart`——取景器（后摄优先）+ 快门单键复用（未录=白圆键启动录制 / 录制中=外圈 60s 进度环 CircularProgressIndicator(value:) + 红色停止方块）+ 「剩余 m:ss」倒计时 + 100ms ticker 到点自动停（camera 0.12 startVideoRecording 无 maxDuration 参数，自动停归我们定时器）+ 取消先停录并删 cache 临时文件防孤儿 + CameraException 分支给可行动文案（权限拒绝→引导系统设置，R1）。页面只产 ≤60s mp4 路径 pop 回作曲器，白名单/大小/时长门槛照走 `_pickVideoWithGate` 统一链，本页零写库。
- 测试（test/note_video_capture_test.dart 2 用例）：fake `CameraPlatform` 桩（availableCameras/createCameraWithSettings/事件流/initializeCamera 补发 CameraInitializedEvent/startVideoCapturing/stopVideoRecording/buildPreview——**buildPreview 不是 buildView**，0.12 已改名）覆盖错误态渲染与直拍闭环（假时钟 pump 60s 验自动停+路径回传）。踩坑：①真相机平台通道在 FakeAsync 不完成（spinner 恒转、错误态不落地），probe 实证后与 sqflite 同口径 runAsync+pump 交替 ②`camera_platform_interface` 直接 import 须声明 dev 依赖（depend_on_referenced_packages）。
- 验证：analyze 0 / 全量 319 绿 / debug 构建 ✓ / 真机 6007 覆盖安装、重启无崩溃。真机待验：自建拍摄页取景器、进度环走满 60s 自动停、提前停、取消丢弃、拍完直接出卡。

## [2026-10-01] 直拍页微调：去倒计时文案（用户拍板）+「斜黄条」取证
- 拍摄页录制中「剩余 m:ss」文案按用户拍板移除——进度环是时间的唯一表达（外圈走满 = 60s 自动停），快门红方块/圆键语义不变；回归测试同步改为 findsNothing。
- 「拍摄的视频播放后出现斜黄条」取证（不盲改）：拉真机所拍 1790826820381.mp4（16.2s, h264 High, yuvj420p, 1280x720）逐帧体检——单帧、末 3 秒帧、全片 8 帧拼图三路核对，斜向暖色光带 16s 全程纹丝不动、无块状伪影、无跳变 → **文件本身完好，「斜黄条」录在内容里**（暗光下失焦光源/近距遮挡的镜头画面），非解码/播放损坏。判据沉淀：视频疑似损坏先抽帧对时间线（fps=1/2 tile 拼图），内容静止≠损坏；若真机复验发现「取景器所见 ≠ 录得内容」才是 CameraX 曝光/对焦链路问题，另案处理。
- 验证：analyze 0 / 拍摄页 2 用例绿 / debug 构建覆盖安装 ✓

## [2026-10-01] 「斜黄条」真凶定位与修复：两处布局溢出警示条（非视频损坏）
- 迭代取证（三轮推翻）：①先判「测试媒体 yuv444p」→那是上一条「加载失败」的因，不是黄条 ②再抽帧判「内容如此」→错（暗视频里的暖色光带是巧合撞脸）③最终 **adb 驱动真机复现**：screencap 逐屏导航（tap 坐标按 1272 物理宽换算），打开视频详情播放 → 截图实拍 **黄黑斜纹 + "BOTTOM OVERFLOWED BY 6.4 PIXELS"** ——Flutter 调试态溢出警示条，release 不显示但内容被裁。教训：**真机可连时优先 adb+screencap 亲自复现，别停在文件取证推理**；uiautomator dump 对 Flutter 语义为空，但 screencap+坐标 tap 全程可驱动。
- 溢出点 1（用户所见）：`_InlineVideoPlayerPage` 全屏播放页 Column `mainAxisAlignment: center`——竖版视频 VideoPlayer 高约 588dp（宽 331dp×16/9）+控制行 > 屏高，溢出 6.4px。修：视频区 Expanded+Center（AspectRatio letterbox），控制行钉底。
- 溢出点 2（连带发现）：详情底栏 `_actionBar` Row 5 项胶囊——**本机逻辑屏宽仅 331dp**（1272px/DPR 3.84，非预想的 462dp），超宽 34px。修：Row→**Wrap**（贪心换行 spaceAround）。⚠️ 两个误改教训：**OverflowBar 不是换行**——放不下时「每项各占一行」竖排（AlertDialog 动作语义），真机上 5 项变 5 行；**BottomAppBar 把子级高度钉死**（探针实测 h=56），两行必竖向溢出——最终 Material+SafeArea+Wrap 自适应高度。
- 连带修配色：主题未覆写 errorContainer，M3 默认回落值与 error 同粉系——删除胶囊「error 字 + errorContainer 底」粉底粉字隐身（旧版被裁切看不出来）。补 errorContainer 0xFF43111E / onErrorContainer 0xFFFFB3C0。
- 取证工具沉淀：LayoutBuilder debugPrint 约束（logcat 按 pid 过滤）定位 w=331.4/h=56；screencap 全程目击。analyze 0 / 全量 319 绿 / 装机后截图复验：底栏 4+1 换行、删除胶囊清晰、播放页无斜纹。

## [2026-10-01] 真机验收闭环：便签内嵌视频 + 作曲器全部项目完成（用户确认）
- 用户逐项复验全绿：相册 mp4/mov 出卡、webm/big 拦截、>5min 确认流、直拍自建拍摄页（进度环+60s 自动停+去倒计时文案）、草稿视频卡点按预览、详情浮层播放、作曲器混排保存。断点①②销项。
- 里程碑提交：本轮全部变更（便签视频双路径+自建拍摄页+验收修复批）入库。
- 剩余前轮遗留：返回手势三态与引用模式 SAF 真机验收；自主下一项=超长文本 Phase 2。

## [2026-10-01] 前轮遗留验收销项：返回手势三态 + 引用模式 SAF（用户确认全绿）
- 返回手势三态：详情返回回列表不退 App（enableOnBackInvokedCallback 修复生效）/ 根页返回退 App / 浮层返回只关浮层。
- 引用模式 SAF：分享文件进拾贝 → 杀 App 重开仍可打开——takePersistableUriPermission 跨会话可达性实测通过，2026-09-30 落地时「本机无设备、持久化成败未实测」的悬置风险正式销项（摄入默认 referenceMode 从此有实测背书）。
- 设备中途断开未做库级 attachState 对账，以用户行为验收为准。

## [2026-10-01] 导航减 chrome：去 app 内返回箭头，出口收归系统手势（用户拍板）
- 口径（ui-spec §3 新增「返回口径」节）：二级页与状态层级视图一律无返回箭头，出口=系统手势/返回键（HCI 评估定论：Android 返回是平台级能力，app 内箭头是冗余 affordance；判断依据是任务重量——拾贝详情是工作面，走小红书式「安静的正式页」，不走 mymind 便签式降级）。
- ①路由页机械摘箭头（6 处 `automaticallyImplyLeading: false`）：详情 / MCP 服务 / 更新 / AI 任务队列 / 最近删除 / 视频全屏播放（media_blocks）。
- ②状态层级视图必须先接管再摘（评估关键发现：全仓原本零 PopScope，保险箱/工作区里系统返回会直接退 App，摘箭头=困住用户）：保险箱视图（inbox_page vaultOnly 分支）PopScope 返回→`onVaultOnlyChanged(false)` 回「全部」；工作区进入态 PopScope `canPop: _selected==null`，返回→退回工作区列表。
- ③标注画布手势兜底（image-markup §5.1 新增条目）：生成/拖拽中 `PopScope canPop:false`——笔画起于边缘手势带被系统掐断（ACTION_CANCEL）后，返回事件解释为「取消生成模式」而非退页；评估中否决「工具栏当手势缓冲区」作主防线（手势带全屏高度 ~20-24dp > 工具栏覆盖、Tap/Drag 论证对画布无效、16dp 内缩低于阈值），采纳为第一层布局缓冲，PopScope 为第二层；可选第三层（左缘 200dp exclusion rects）真机验收再定。
- 例外保留：块编辑器 CloseButton（取消/保存语义）、速记面板收起箭头（收合非返回）——导航返回口径不外溢到动作语义。
- 验证：analyze 0 / 全量 348 绿。真机待验：保险箱/工作区手势返回回上级、标注边缘起笔后返回不退页、六路由页手势返回。

## [2026-10-01] 速记条真机反馈三连修：主题漏覆写槽位是白边/杂色共同根因
- 白边根因：`outlineVariant` 未在主题覆写，漏 M3 基线默认浅薰衣草白（≈#CAC4D0）——速记条收起态/拖动中间态顶部 1.5px 边线用该槽位，故拖动中不消失；完全展开后边线换 primary 橘红才「消失」。修：主题补 `outlineVariant: 0xFF474D5C`（比 outline 亮一档暗灰），连带修正 rich_text_view 分隔线、卡片描边等 8 处同槽位浅线。
- 展开态杂色根因：`secondaryContainer/onSecondaryContainer` 同样漏覆写，「保存」FilledButton.tonal 漏 M3 默认紫灰底淡紫字，与暖灰底+橘红强调撞色。修：对齐 primaryContainer 暖棕系（0xFF3D1D0E / 0xFFFFB59A，secondary 本就同橘红，映射逻辑一致）。
- 教训：主题注释自称「M3 派生色不再露出」但全量 override 不全——ColorScheme 有 30+ 槽位，凡用未覆写槽位即漏 M3 基线紫白系；后续新页面用色先核对 main.dart 已覆写清单。
- 收起拉手提示词「· 点按或上滑展开」按用户拍板移除（上滑手势本就 Predictive affordance，无需文字教学）；3 处测试引用同步。
- 验证：analyze 0 / 全量 348 绿。

## [2026-10-01] 工作区创建升级为整页仪式（mymind「Create new space」参照，用户拍板）
- 背景评估：FAB+裸 AlertDialog 的创建流「语法错位」——Dialog 是快速确认语法，撑不起「建一个容器」的分量；主按钮两个同权重 TextButton 无承诺感；零语境无定位语。用户给 mymind 创建页截图定参照，确认整页方案（比此前评估的 BottomSheet 方案更贴 mymind 视觉基准 SSOT）。
- 落地 `lib/pages/workspace_create_page.dart`：全屏居中构图——中国结线稿（CustomPaint 盘长结简形：顶环+外内菱+十字织线+四向耳弧+三绺流苏，单色 onSurfaceVariant，装饰不走橘红）→ 衬线 headlineMedium 标题 → 定位语（用户四备选中拍板第 4 句「聚合点滴记录与热爱。不止是为了归档过去，更是为了启发未来。」——最短、最诚实、贴拾贝品牌）→ 居中描边名称框（autofocus）→ 橘红 StadiumBorder「创建」FilledButton（ValueListenableBuilder，名称空=onPressed null 承诺门）；右上角 X 关闭（§3 例外口径：关闭语义非导航返回）+ automaticallyImplyLeading:false，手势返回天然可用。
- 分层：本页只产名称 pop 回字符串，写路径留在 WorkspacePage 走 CreateWorkspaceCommand（arch：UI 不持写路径）；WorkspacePage._create 的 Dialog 下线改 push；V3 口子登记在 ui-spec §4.11（图标/配色属性步长在本页）。
- 测试：test/workspace_create_page_test.dart 2 用例（空名承诺门不可点 / 输入 pop 回 trim 后名称）；中国结形态经临时 golden 渲染自查两轮（整圆耳环偏花朵感→改四向半圆弧后达标），golden 不入库。
- 验证：analyze 0 / 全量 350 绿 / arch-guard 7 条过。真机待验：中国结线稿观感、衬线标题渲染、键盘弹起输入框避让、创建后回列表新卡出现。

## [2026-10-01] 品牌符号落地：鹦鹉螺 glyph（用户供 SVG，色板重映射进主题）
- 符号评选（用户供 8 图）：选定「Geometric Nautilus」——单主体无底板、剪影经得起缩小、几何线稿与既有体系同源、「贝」押「拾贝」题眼且螺旋分室暗合工作区「散落碎片长出秩序」；「Gathering Basket」聚合语义最好但编织纹理小尺寸糊死，划为空态插画素材。
- 颜色处理（用户供 SVG 后按纪律重映射，assets/glyphs/nautilus.svg）：①删 #fafefe 白底 rect+底路径（深色界面上就是白方块）②线稿层 #0a2c34/#143746 → #e8e4dc（onSurface 暖白）③40 个中间调青绿切面按亮度两分 → #242833/#1c1f27（surfaceContainerHigh/Low，亮源色压暗保持层次反转）——源图彩色不落一色进代码，仅 3 个主题槽位值。手绘 CustomPaint 版（弦线螺旋三轮迭代）作废，golden 渲染验证 SVG 深底观感达标后移除。
- 依赖：flutter_svg ^2.3.0（项目首个 SVG 渲染依赖）；NautilusGlyph widget 就绪（size 入参，未落页——创建页顶部当前仍是中国结，符号分工待用户拍板：鹦鹉螺替换创建页顶 / 作全 app 品牌符号另寻落点）。
- 验证：analyze 0 / 全量 350 绿 / arch-guard 7 条过。

## [2026-10-01] 速记条 UI 分析两连修：双提示淡出时序 + 保存按钮内容感知（用户拍板）
- 双提示根因：形变交叉淡化（收合/展开两树叠放）里两态各有一份「记点什么…」（拉手文字 + 正文首行 hint），共用 0.35→1 淡化窗口 → 半途并存。修：拉手文字提前淡出（进度 0→0.2 消隐，正文提示 0.35 才浮现）——「先死后生」，任意时刻全屏最多一份提示，且拖动初期「文字先走、面板在长」形变更连贯。
- 保存按钮「脏」的根因分析：①静态 tonal 深棕与面板底同明度 → 空态成暗斑（无状态 CTA 扛 stateful 动作，语义错位）②M3 禁用默认样式 = onSurface@12% 半透明罩 + 38% 半透明白字，罩叠面板即「灰泥」观感——用户直觉「有内容才显色」正踩主题纪律「橘红仅动作与选中」。修：内容感知 CTA——`_hasContent`（文字/媒体/标签/待办任一）+ ListenableBuilder 订阅各文本段 controller；空=实色禁用（surfaceContainer 底 + onSurfaceVariant@60% 字，无半透明罩），有内容=橘红 FilledButton + onPrimary 白字（设计好的高对比对，非脏源）。`_save` 的「先写点什么吧」分支自然退役（按钮进不去，留作防御）。
- 测试：新增内容感知用例（空禁用/输入点亮）；既有保存路由用例不受影响（先输入后保存）。
- 验证：analyze 0 / 全量 351 绿 / arch-guard 7 条过。真机待验：拖动半途单提示、保存钮点亮瞬间反馈、禁用态实色观感。

## [2026-10-01] 新建工作区页垂直居中修复
- 现象：整页内容靠上。根因：Center 套在 SingleChildScrollView 里，纵向滚动视口给子级的是**无界高度**，Center 撑不满视口 → 内容顶到上沿（单子级滚动布局的经典陷阱）。修：LayoutBuilder 取可视高 + ConstrainedBox(minHeight) 撑满 + Center 居中；键盘弹起（resizeToAvoidBottomInset 缩小可视区）时自动在剩余空间内居中、超高仍可滚。顺手补水平 Insets.lg 边距（原名称框在窄屏满宽贴边）。中间态括号补丁两次失手后整文件重写——多层级嵌套改动直接重写比逐层补丁可靠。
- 验证：analyze 0 / 全量 351 绿；临时 golden 渲染确认内容块落可视区垂直中心（golden 不入库）。

## [2026-10-01] UI 规则沉淀：本日交互/视觉决策提取进规范体系
- 分流：设计口径进 docs/design/ui-spec.md（SSOT）——新增 §2.4 品牌符号与装饰（鹦鹉螺=全 App 品牌符号 / 中国结=聚合挂创建页；装饰不走橘红；矢量资产色板重映射禁白底；不写手势教学文案）、§4.6 补三条（速记条常驻不随滚动隐显=任务生命周期判断 / 保存按钮内容感知 / 形变交叉淡化「先死后生」）、§6 补 CTA 分级（FilledButton 主按钮 / 裸 AlertDialog 仅快速确认 / 低频重要动作=整页仪式「形式升级流程不加价」+ 承诺门）。§3 返回口径、§4.11 创建页此前已回写。
- 工程硬规则进 .agents/skills/goodshare-ui/SKILL.md——新增「交互与主题硬规则」节八条（无返回箭头三层落法含「状态视图先补 PopScope 再摘箭头」次序、主题槽位覆写核对、装饰不走橘红、资产重映射、先死后生、CTA 内容感知、捕获入口不随滚动隐、Center-in-scrollview 布局陷阱）；自查清单补第 8/9 条（槽位覆写 / 返回箭头·半透明罩·AlertDialog / 资产重映射·双提示）。
- 泛化原则：规则写「可判定的工程口径 + 实证事故出处」，案例叙事留 devlog 不进规范。

## [2026-10-01] 创建页符号替换：中国结废弃（联通商标撞车）→ 鹦鹉螺顶上
- 用户供新 knot SVG 评估时自查发现：盘长结形态与**联通公司 logo 撞车**（其商标即红色盘长结）——品类被注册，非画得像不像的问题，凡品牌/logo 用途中国结形态整体禁用（硬约束）。SVG 源弃用未入库。
- 处置：创建页顶部 `_ChineseKnot`/`_KnotPainter`（手绘盘长结）整体删除，换 `NautilusGlyph(size: 96)`——此前 A/B 分工悬案就此落定为「鹦鹉螺唯一品牌符号」（ui-spec §2.4 已改写并记废弃因由；§4.11 同步）。golden 渲染验证居中构图正常。
- 教训沉淀：符号/图标引入前先做**商标形态冲突排查**（尤其中国结、灯笼、华表等被大公司注册的品类），晚发现不如入库前查。
- 验证：analyze 0 / 全量 351 绿 / arch-guard 7 条过。

## [2026-10-01] 符号体系定稿：三环结插画上创建页（箭头序号保留）+ 鹦鹉螺升任 app 启动图标
- 用户供三环绳结教程图（PNG，带①②③④序号与方向箭头、右上白补丁），拍板：**箭头+序号是表达核心不去**，与海螺同风格处理。定位=插画非品牌 glyph（品牌符号=鹦鹉螺），工作区隐喻「把散落的条目打成结」。
- 处理管线（纯 PIL，无 numpy 环境）：边界连通泛洪抠浅色渐变背景（绳体内部高光不与边连通故保留）+ 亮度反转映射主题暖灰阶（绳体→#1c1f27 档、编织纹理/线稿/箭头/序号→#e8e4dc 暖白，gamma 1.15 保纹理对比）+ 内容框裁剪。产出 `assets/glyphs/knot_diagram.png`（1075×914，源图彩色不落一色）。
- `KnotIllustration` widget 挂创建页顶（height 180）；鹦鹉螺经品牌底（#15171E）渲染 1024px→`assets/icon/app_icon.png`→`flutter_launcher_icons` 重生成 Android/iOS 全尺寸图标集（golden 渲染法产图标，DPR 1.0 需显式设）。
- 踩坑：widget test 里 `Image.asset` 异步解码不被 pumpAndSettle 追踪，golden 空白假象——`tester.runAsync` 放行真实时钟后再 pump 才捕到。
- 验证：analyze 0 / 全量 351 绿 / arch-guard 7 条过 / golden 双验（创建页构图 + 图标渲染）。真机待验：桌面图标观感、创建页插画在真暗底上的纹理表现。

## [2026-10-01] 创建页绳结插画微调：尺寸 180→96（与海螺同档）+ 序号剔除（用户拍板）
- 96dp 下序号①-④缩成斑点噪点（源图 1075×914 压到 96dp 序号仅数像素）——用户拍板「不要数字了」。连通域分析剔除：序号特征=55×55 近方形环形块（面积~2360），箭头=细长笔画保留，绳体=巨块保留；顺带清 2 个 1px 尘点。首版孔检测条件写错（透明像素 label==cid 恒假）零命中，debug 打印特征后改按形态参数精准命中。
- 资产重裁 1071×910；KnotIllustration 默认 height 96；ui-spec §2.4/§4.11 措辞同步（箭头保留、序号剔除）。
- 验证：analyze 0 / 全量 351 绿 / golden 确认 96dp 构图干净。

## [2026-10-01] 按压反馈重构：图标变色替代面积罩（用户拍板「图标本身变色」）
- 病根：M3 默认按压反馈=半透明状态层（onSurface@8-12%）叠满可点击区——暗色主题上灰白罩叠深底即「底色与白字叠成灰泥」（与禁用罩同源），且视觉重心落在底板而非图标。用户直觉「图标本身变色」正合 chrome 极低体系：反馈与动作对象同位，明度跳变 100ms 内可感知，「提亮=激活」语义比底板变灰准；橘红纪律不稀释（按压用提亮非点亮）。
- 落地（main.dart 主题一处收口）：`splashFactory: NoSplash` 全局关扩散水波纹；iconButtonTheme 按压/悬停罩透明 + 按下图标 onSurfaceVariant→onSurface 提亮；filledButtonTheme 按压底色实色加深（#E04F1A=primary 深一档）禁罩；textButtonTheme 按压文字实色加深。resolveWith 非按下态返回 null 回落 M3 默认——selected 橘红不丢（关键细节）。卡片/列表 InkWell 保留默认 highlight（未在投诉范围，且是唯一反馈）。
- tonal 特例：全局 pressed 色是橘红系，tonal 暖棕底会闪橘——settings_page 3 处 tonal 局部 `_tonalPressStyle`（Color.alphaBlend 黑18% 实色加深，主题派生不硬编码）。
- 连带：dart format 重排 settings_page（旧格式文件）触发既有裸 if 的 curly_braces lint，补大括号；long_text Phase 3 全量首跑偶发失败（Isolate 时序），复跑两次均绿判偶发。
- 规范回写：ui-spec §6 按压反馈分级 + goodshare-ui skill 硬规则新增「禁面积型反馈」条（含 resolveWith null 回落细节）。
- 验证：analyze 0 / 全量 351 绿 / arch-guard 7 条过。真机待验：图标钮按下提亮手感、CTA 按下实色加深、全 app 无灰泥罩残留感。

## [2026-10-01] 按钮去胶囊：Filled/Outlined/FAB 全局改大圆角矩形（用户拍板「不用胶囊按钮」）
- 用户示 mymind 截图拍板「不用胶囊按钮了，这种感觉的按钮更好看」——按钮类一律 Radii.lg 16dp 大圆角矩形（与卡片同语言，mymind ＋块/搜索条参照）：主题 filledButtonTheme/outlinedButtonTheme/floatingActionButtonTheme 三处 shape 全局收口（M3 默认 Stadium 整体退役）；workspace_create_page 手写 Stadium 移除（继承主题）；详情页底部操作条（InkWell+ShapeDecoration）Stadium→lg16。
- 胶囊保留给「词汇形态」：筛选 chips（chipTheme）与标签（_tagPill）——胶囊=标签专属语言，与按钮混用稀释语义；ui-spec §2.3 修订（原「按钮一律全 pill」废止，原 mymind 依据实为标签场景）+ goodshare-ui skill 硬规则新增「按钮形态=大圆角矩形，新按钮禁止手写 Stadium、不要给按钮加 shape」。
- 澄清：用户随后明确 mymind 截图同时是**按压反馈**参照（按下只有图标本身变色非整个区域）——该行为上一轮已实现（iconButtonTheme 罩透明+图标提亮/NoSplash），重新构建安装即生效。
- 验证：analyze 0 / 全量 351 绿。真机待验：按钮矩形大圆角观感 + 图标按下提亮。

## [2026-10-01] 全系统去胶囊：chips/标签/输入框/工具栏全部矩形化（用户拍板「不再使用胶囊」）
- 二次拍板升级：上一轮「胶囊留给词汇形态」口径作废，胶囊形态全系统退役。清单：①chipTheme Stadium→md12（筛选 chips）②标签 _tagPill→_tagBadge Stadium→md12 ③搜索输入框 24→xl20 ④标注工具栏容器 24→lg16 ⑤创建页输入框 M3 默认 4dp→lg16（顺带统一）。lib 内 Stadium 归零（grep=0）。
- 圆角取档原则沉淀：按组件尺寸取档——小件（chips/标签）md12、按钮/工具栏 lg16、卡片/输入框 xl20；半径 ≥ 高度一半即伪装胶囊，同禁（如工具栏 24/40dp）。
- 规范回写：ui-spec §2.3（去胶囊条款升级 + 圆角取档）+ goodshare-ui skill 硬规则（全系统去胶囊 + 禁伪装胶囊）。
- 验证：analyze 0 / 全量 351 绿 / arch-guard 7 条过。真机待验：筛选 chips/标签/搜索条/标注工具栏的矩形观感。

## [2026-10-01] 去胶囊补漏：底部导航选中指示器胶囊（用户真机截图定位）
- 用户真机截图（对比 mymind）指出页面下部「还是胶囊一个区域变色」——真凶不是按压反馈，是 M3 NavigationBar 的**选中指示器**（原生=64×32 secondaryContainer 胶囊，全部页面底部常驻）。修：navigationBarTheme indicatorColor 透明 + 选中态 icon/label resolveWith 变橘红（onSurfaceVariant→primary，mymind 口径「选中仅内容变色无底板」）。连带 SegmentedButton（settings 2 处）shape 收口 lg16（选中容器语义保留）。ActionChip 经 chipTheme 自动矩形化。
- 规范同步：ui-spec §2.3 去胶囊条目补「NavigationBar 指示器」；skill 硬规则已含全系统去胶囊条。
- 教训：去胶囊首轮只扫了 StadiumBorder 显式写法，漏了 M3 组件**内置**的胶囊形态（NavigationBar indicator）——完整清单应遍历「自带默认胶囊」的组件族：按钮、FAB、chips、NavigationBar 指示器、SegmentedButton。
- 验证：analyze 0 / 全量 351 绿 / arch-guard 7 条过。真机待验：底部导航选中=橘红图标文字无胶囊。

## [2026-10-01] 创建页定位语拆两行（用户拍板）
- 「聚合点滴记录与热爱。\n不止是为了归档过去，更是为了启发未来。」——每句一行居中，「短—长」行长对比自生节奏；层级不加配色强调（标题白/定位语灰已有明暗节奏，第三重强调过载，mymind 定位语亦统一灰）。golden 验证两行居中构图。

## [2026-10-01] 详情页两区改版 + 区块能力平台（detail-two-zone.md，11 条预警打磨）
- **页面级已落地**：公共区底栏 3 项（工作区/分享/删除，「分享」后台静默导出 PDF 后拉起分享面板）；摘要/标签切换器+刷新（复用 Summarize/ExtractTags+_AiTaskStatusLine）；PDF 导出 `lib/ui/pdf_export.dart`（pdf 包+内嵌 DroidSansFallback 中文字体，Apache 2.0）。
- **能力平台四件套**：`lib/ai/capability.dart`（ContentCapability 抽象，appliesTo 自声明，command() 对接命令层=自动进 ai_task_queue FIFO，多链互斥=队列化）+ `capability_chain.dart`（纯状态机：完成即落库/中断续跑 restore/失败停步 retry/Reset/raw+edited 双字段，6 单测绿）+ `block_capability_host.dart`（长按统一触发+Semantics custom action，媒体块三处接线 buildRichBlock）+ `block_capability_card.dart`（单卡链式+来源锚点+回注目标/复制+编辑覆盖态回调钩子）+ `block_text_page.dart`（文本块三级处理页）。
- **分享分流**：`share_scope_sheet.dart`（预览勾选，灵感区/块附录默认关=隐私红线）+ `body_screenshot.dart`（复用页面既有 RepaintBoundary=Theme 红线；8000px 等效高度硬阈值超限降级 PDF）。
- **灵感区重构**：schema v16 加 `inspiration_md` 列（幂等补齐）；UpdateItemCommand 加 inspirationMd 字段全链贯通；AI 产出区/灵感区拆分——摘要/标签=机器只读+刷新，灵感=人的碎片可编辑失焦即存（dispose 兜底，reload 编辑中不覆盖）。
- 教训：arch-guard R7 扫 `fontSize:` 正则无法用常量化绕过；pdf 包 fontSize 是文档排版参数与 textTheme 无关，按 remedy 指引加白名单注明原因（只减不增）；批量 sed 替换标签名会连 `fontSize:` 标签一起吞掉（本次 `python str.replace('fontSize: 20)', '_fontSizeTitle)')` 事故，改完必须复跑 analyze）。
- 验证：analyze 0 / 全量 357 绿（含新 6 条链单测）/ arch-guard 7 条过 / docs-lint OK。真机待验：长按唤出菜单手感（文本块双击选字分家待验，别扭回退单入口方案）、能力卡流转、分享产物形态、灵感区失焦落库。
- [2026-10-01] [变更]: 能力卡执行接线落地：item_detail_page 包 BlockCapabilityExecutor，onRunStep 组装真命令（OCR/转写/翻译/摘要，翻译带入队前预检）+ _waitForTask 轮询任务落定（completed 判定，5 分钟上限）后从条目字段抽产出（human_md/translated_md/summary_md）；onApply 三回注目标走 UpdateItemCommand（追加/替换/灵感区）；onEditOutput 接三级文本页；MVP 口径=产出落条目级字段，链每次全新开始、Reset 仅归零卡内状态（块附件通道落地前无续跑死锁）
- [2026-10-01] [验证]: flutter analyze → 0 issue；test capability_chain_test+block_editor_test 34 绿（UI 接线轮按验证分级跑相关文件，全量测试未跑）
- [2026-10-01] [变更]: 区块能力触发改版落地（真机验收否决长按+菜单三跳，用户拍板 ✨ 单入口）：BlockCapabilityHost 改每块右上角常驻 28px ✨ 圆钮点按直进三级能力页（长按/能力清单菜单层废除）；新建 block_capability_page 全屏页（资源预览+链式工作台，能力卡 BottomSheet 并入页）；链=capabilitiesFor 全量（chainFor 删除，ReinjectTarget 移 capability.dart）；行内文本/代码/列表/媒体块+顶级媒体条目全包 ✨ 外壳（补顶级区缺口）；删 showBlockCapabilitySheet/卡 Sheet 入口
- [2026-10-01] [验证]: flutter analyze → 0；全量测试 357 绿；arch-guard 7 条过；docs-lint 过；detail-two-zone.md §5.1/§5.3/§5.4/§7 已回写改版记录；8009 包构建成功但真机断连未装
- [2026-10-01] [变更]: 独立能力拆分落地（用户拍板：独有功能也进三级页，二级页与类型统一）：capability.dart 增 StandaloneCapability 五项（分类/条码=image、分析文本=text、切片/整片=video）+ standaloneFor；执行器/三级页增 onRunStandalone 分发（命令入队或切片工具流）；三级页增「独立能力」chips 区；详情页 _typeActions/_translate 整体删除——内容能力唯一入口=✨，MCP 工具不动
- [2026-10-01] [验证]: flutter analyze → 0；全量 358 绿（capability_chain_test 增 standalone 分发 4 断言）；arch-guard / docs-lint 过；detail-two-zone.md §5.2/§7 回写；8010 构建成功，真机仍断连未装
- [2026-10-01] [变更]: 触发分派定稿落地（用户拍板：媒体块长按、文本块 ✨）：BlockCapabilityHost 增 BlockCapabilityTrigger 双模式——handle=✨ 常驻（热区外扩 44×44，视觉仍 28px）/ longPress=媒体块长按直进三级页（无常驻图标，阅读态零 AI）；媒体块包 SelectionContainer.disabled 退出选区容器（解 SelectionArea 吃长按，真机已证）+ HitTestBehavior.translucent 全宽热区；行内/顶级图音视全走 longPress，文本/列表/代码块走 handle
- [2026-10-01] [验证]: flutter analyze → 0；全量 358 绿；arch-guard / docs-lint 过；detail-two-zone.md §5.1 三轮拍板记录回写；8011 已装真机（3B161700Y0600000）
- [2026-10-01] [变更]: 区块能力触发四版改版（用户拍板：文本块撤销常驻 ✨——「一行文本也出现图标，页面大量图标」，根因=常驻入口密度即块密度）：新增 BlockAnchorStore 锚点注册表（Host 注册自身矩形，dispose/滑出视口即注销；hitTest 按菜单锚点反查命中块——纵向包含取高度最小者、块间空隙取最近块、>48dp 判未命中）；BlockCapabilityTrigger.handle → selection（文本块纯透传 child，正文零图标），longPress 档与媒体块手势不动；新增 buildBlockCapabilityMenu（系统选字菜单追加「AI 处理本段」项，未命中不追加=不死项），item_detail_page 的 SelectionArea 接 contextMenuBuilder 并外包 BlockAnchorRegistry；Host 内 _invoke 抽为顶层 openBlockCapability（菜单项/媒体长按共用唯一出口）；rich_text_view 注释同步
- [2026-10-01] [验证]: flutter analyze → 0；全量 361 绿（新增 test/block_anchor_test.dart 3 条：锚点命中/卸载即注销/划词菜单项出现）；detail-two-zone.md §5.1 四版拍板 + 已评估否决的替代（侧边书签/边缘磁吸、焦点块单 ✨）、§5.2/§5.4/§7 落点/验证口径已回写；待真机验收：划词菜单项触达与命中块是否正确
- [2026-10-01] [变更]: 详情页操作区重划（用户拍板）：底栏 3 项 = **编辑 / 工作区 / 分享**（删除移出底栏——危险项不占常驻位）；`⋯` 菜单 = 解除编辑(条件) / 重分类(条件) / 重新处理 / 移入移出保险箱(条件) + **删除**（末位红字，走 _confirmDelete 二次确认）；菜单移除「编辑」「分享」——同一动作只留底栏唯一入口，纯文本直分享 `_share()` 一并删除；「机器态」不给按钮（人类不进机器态），入口改**长按 AppBar 标题**切换（_toggleMachineMode，双态呈现能力保留=ui-spec 硬规则）；_barAction 去掉 danger 形态（底栏不再有删除）
- [2026-10-01] [验证]: flutter analyze → 0；全量 361 绿；arch-guard 7 条过 / docs-lint 过；ui-spec §4.3（公共区 3 项 + 操作分层表 + 文档形态⑤⑥）+ detail-two-zone §3/§6/§7 已回写；待真机验收：底栏三项触达、菜单删除二次确认、长按标题切机器态是否误触
- [2026-10-02] [变更]: 三项拍板落地（与并行会话四版改版共存，全量 361 绿）：①图片标注迁三级页独立能力 annotate（新 annotation_editor_page.dart 全屏宿主，ImageAnnotator 整体迁入；二级页内联标注双态+按钮删除）②灵感区摘要/标签平行并置（删页签互斥）+ 标签手动增删（_TagEditorSheet BottomSheet chips，保存走 UpdateItemCommand 整表替换）+ AI 刷新并集合并（applyAiResult 只增不删）③底栏方向感知隐显（NotificationListener 方向判定 + AnimatedAlign heightFactor：下滑藏/上滑现/静止保持/键盘隐藏），与并行会话重划后的底栏（编辑/工作区/分享）零冲突叠加
- [2026-10-02] [验证]: flutter analyze → 0；全量 361 绿（含并行会话 block_anchor_test 3 条）；arch-guard / docs-lint 过；detail-two-zone.md §3/§5.2/§7 回写；8012 已装真机
