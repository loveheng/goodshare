---
memo: todos
format: v2
---

# 待办列表

## goodshare

- [ ] [2026-09-28] (风险) 视频字幕转写：长视频 16k 单声道 WAV 临时文件约 115MB/小时落 systemTemp，且既有 10 分钟超时策略未覆盖视频场景，落地时评估分段/清理与超时上限 (src: ai, design-docs-review)
- [ ] [2026-09-28] (优化) 图片列表「有标注」角标按 annotations JSON 存在性判定属文件 stat IO，列表滚动路径需异步缓存避免主线程阻塞 (src: ai, design-docs-review)
- [ ] [2026-09-28] (功能) 真离线翻译引擎（OPUS-MT / 自托管小模型）：翻译层骨架已就位，实现 `TranslationEngine` 并注册进 `TranslationRouter` 即可接棒——国内 ML Kit 语言包不可达时才有译文产出 (src: ai, translation-skeleton)
- [ ] [2026-09-28] (功能) iOS Apple Translation framework 引擎实现（骨架期 Android 独享，iOS 恒落 Noop） (src: ai, translation-skeleton)
- [ ] [2026-09-28] (优化) 源语识别替换启发式：当前 `detectSourceLanguage` 为字符分布启发式（已标 DEGRADE），接入语言识别能力后替换，接口不变 (src: ai, translation-skeleton)


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
