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
