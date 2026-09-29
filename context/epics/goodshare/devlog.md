---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 5
last-merge: 2026-09-29
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
