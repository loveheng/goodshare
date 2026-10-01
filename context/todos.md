---
memo: todos
format: v2
---

# 待办列表

## goodshare

- [ ] [2026-10-02] (功能) 视频多段剪辑批次模型 + 音频剪辑复用预留：轻剪辑页一次进入=一个工作批次（区间逐个「收进本次」入暂存架，scrubber 色带防重叠、>10 段软提示，完成时逐区间过门槛、默认产出 N 个独立条目可选合并）；音频**不建剪辑页、不挂入口**（宽约束拦不到人+无截片段场景），仅架构预留（TrimAction 泛化 mediaType + 媒体无关壳，未来零返工接入）。**说明：交互设计已落档 docs/design/video-trim.md §1/§5.1，本条为实现候选项——轻剪辑页动工时一并实现，勿单独排期** (src: ai, 交互评估对话)
- [ ] [2026-10-01] (功能) 轻剪辑独立页面（区间选择器）：超门槛拦截后一键进入，独立路由页 + 预留 AI 调用路径（AI 可对用户视频发起区间操作）；唯一动作「切」：双端 scrubber 拖动粗定位 + 按住慢放精调（静止按下 200-250ms 触发，回退 1-1.5s 含反应补偿，0.5x 起步，拖动中停顿 500ms 触发且不回退）+ 抬手定点即正速续播；包含式补偿（in 点自动前移 0.3-0.5s / out 点后延 0.3-0.5s），北极星一次剪对率 ≥85%；不做字幕/变速/拼接/逐帧按钮；产物=原件时间轴裁剪原样副本（转码只裁时间不压画质，原文件不动），重新过门槛校验后进收集链路 (src: ai, 交互评估对话)
- [x] [2026-10-01] (功能) 便签页内嵌视频双路径：主路径相册选择（后置校验：≤5min 提示非阻断、非 MP4 转码或提示暂不支持、>50-100MB 提示过大），次路径相机直拍（`image_picker maxDuration` ≤60s 自动停、720p 间接控大小）；用户只感知时长不感知字节；UI 收敛到附件面板「拍摄/从相册选」二选一、相册首位；封面卡+播放按钮懒加载，播放器 dispose 配对、缩略图 cacheWidth (src: ai, 交互评估对话)（✅ 2026-10-01 落地：拍板调整——白名单 mp4/mov 直入库不转码、封面留图标占位卡、阈值定 100MB；代码 lib/share/note_video_policy.dart + note_composer NoteVideoSegment + quick_note_bar 视频入口；封面提取仍留 V2 todo）
- [ ] [2026-09-28] (风险) 视频字幕转写：长视频 16k 单声道 WAV 临时文件约 115MB/小时落 systemTemp，且既有 10 分钟超时策略未覆盖视频场景，落地时评估分段/清理与超时上限 (src: ai, design-docs-review)
- [ ] [2026-09-28] (优化) 图片列表「有标注」角标按 annotations JSON 存在性判定属文件 stat IO，列表滚动路径需异步缓存避免主线程阻塞 (src: ai, design-docs-review)
- [ ] [2026-09-28] (功能) 真离线翻译引擎（OPUS-MT / 自托管小模型）：翻译层骨架已就位，实现 `TranslationEngine` 并注册进 `TranslationRouter` 即可接棒——国内 ML Kit 语言包不可达时才有译文产出 (src: ai, translation-skeleton)
- [ ] [2026-09-28] (功能) iOS Apple Translation framework 引擎实现（骨架期 Android 独享，iOS 恒落 Noop） (src: ai, translation-skeleton)
- [ ] [2026-09-28] (优化) 源语识别替换启发式：当前 `detectSourceLanguage` 为字符分布启发式（已标 DEGRADE），接入语言识别能力后替换，接口不变 (src: ai, translation-skeleton)
- [ ] [2026-09-30] (功能) 超长文本 Phase 2 归一化分块：按标题层级 + 500-token 滑动窗口切分 `human_md`，消费侧（渲染/摘要/向量）按需取 chunk；`item_embeddings.chunk_index` 结构已预留，先补生产侧切块 (src: content-pipeline, long-text)
- [ ] [2026-09-30] (优化) 超长文本 Phase 3 解析异步化：将 `MarkdownSubsetParser` 的解析（数万字正则 + 块/行内 AST 构造）移出主线程到 Isolate，避免超长正文首帧解析卡 UI（RichTextView 解析缓存已在，补 Isolate 调度） (src: content-pipeline, long-text)
- [ ] [2026-09-30] (功能) 超长文本 Phase 4 向量引擎落地 + RAG/Map-Reduce 摘要：实现嵌入生产者（写入 `item_embeddings` 分块向量）+ 超长摘要走 Map-Reduce（先分块摘要再归并），解决 Context 溢出瓶颈 (src: content-pipeline, long-text)


## misc
- (功能)[long] iOS 端适配：需 macOS 构建；验证 receive_sharing_intent iOS 行为与前台服务限制（预期「app 前台时 MCP 可用」）
- (功能)[long] 鸿蒙 OHOS 适配：flutter_flutter fork + receive_sharing_intent/flutter_foreground_task 插件 ohos 化
- (功能)[medium] ACTION_PROCESS_TEXT：任意 app 选中文本一键收集（需自定义平台通道）
- (功能)[medium] 标签管理（编辑/筛选）；数据量大后评估 FTS 全文索引替换 LIKE
- (风险)[medium] 国产 ROM 省电策略可能杀前台服务：真机验证华为/小米等存活情况，必要时引导加白名单
- (优化)[done] 自定义 app 图标：flutter_launcher_icons 已接入（pubspec.yaml），源图 assets/icon/app_icon.png（1024²），生成 Android ic_launcher（mipmap 五套）+ iOS AppIcon（remove_alpha_ios: true，规避 App Store alpha 限制）
- (功能)[low] 启动页 splash 自定义（自「图标与启动页」拆出，待办）
- (文档)[low] release 签名配置文档化（keytool + signingConfig）
- (优化)[low] 图文同分享（相册带文案）时文案会被插件丢弃（toJsonObject 只取 uri），需 fork 插件或自写 intent 解析才能补齐
- (功能)[medium] Shorebird 接入收尾：本机被两件事挡住——官方安装脚本 404（改用 GitHub release 包手动装）+ api.shorebird.dev TLS 握手失败（需代理）；用户侧网络可用时按 docs/guide/self-update.md §2 走 shorebird init/login/release
- (风险)[low] 自更新 release 包当前用 debug 签名（模板默认），正式分发前配置 release keystore 并在 shorebird 流程中统一
- (优化)[low] 更新页增加「强制最低版本」逻辑（清单 minVersionCode，低于即全屏提示必须升级）
- (优化)[low] ASR 模型源迁移 R2 + 换新版（低优先/暂缓）：模型改为 csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09（model.int8.onnx 237,115,547 / tokens.txt 315,894）+ csukuangfj/sherpa-onnx-paraformer-zh-int8-2025-10-07（238,429,929 / 75,756，川渝方言版）；分发方式改为 Cloudflare R2 自托管 tar.gz 包（域名 https://r2.oklhj.eu.org，包的完整 URL 待用户提供），lib/ai/asr_model.dart 改「单包 + entries」结构、lib/ai/model_manager.dart 改下载→解压→逐文件校验→删包（需加 archive 依赖）。未决：是否保留 whisper-small 多语种档、方言版是否契合场景（否则换 paraformer-zh-2024-03-09，227,330,205 / 75,354）。现状可用（hf-mirror 三档已能下载），无需紧急处理
- [ ] [2026-10-01] (功能) 视频主体条目（新 item_type，与附件视频姊妹）：入口分叉「添加附件 vs 视频条目」，主体态设宽门槛非零（拟 ≤10min / ≤500MB，待定），超限拦截拒收；门槛内不干预大小（无提示），工程防线后移：封面/转写 Job 化后台、播放懒加载、大文件三态兜底；不做「有无配文」隐式推断主体 (src: ai, 交互评估对话)
- [ ] [2026-09-30] (功能) 行内媒体块 V2 插入链路：图片相册选取+压缩+OSS 上传（产出 https url 写 ImageBlock，「📷」按钮）；音频/视频本地行内插入（依赖多端资产同步机制）；视频封面提取（顶级+行内，引入 video_thumbnail 类依赖走 Job 化） (src: rich-text-media §5)
- [ ] [2026-09-30] (优化) 超长文本 Phase 3 Isolate 化补充实证：30k/60k 字符 parse 实测 18/19ms（桌面 JIT），真机 AOT 预计 2-4 倍超一帧预算；Isolate 化时以实测为准定阈值，同步覆盖编辑器保存链路 serialize (src: rich-text-media §8 评估)
