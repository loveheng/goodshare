---
name: goodshare-workflow
description: 拾贝 goodshare（Flutter/Dart 分享收集器+内嵌 MCP 服务）工作流事实源：构建/分析/测试/自检命令、模块结构、环境硬约束。构建报错、跑测试、换机器、发布前先读本 skill，命令勿凭记忆写。
---

# goodshare 工作流事实源

机制层面（终端超时管控、验证账本等）见全局 dev-loop；本文件只记本项目事实。结构与粒度参照既有实例（stock-calculator-workflow）。

## 项目形态

- Flutter 单模块应用（`lib/`），Android 首发；iOS 已生成 runner（未适配），鸿蒙走 flutter_flutter fork（未开始）
- 包名 `com.zzh.goodshare`，应用名「拾贝」，应用层语言 Dart 3.13 / Flutter 3.47 stable
- 仓库根：`~/app/goodshare`（AI 协作记忆体系在 `context/`，项目 skill 在 `.agents/skills/`）

## 模块结构（锚点，展开现场 derive）

| 目录 | 职责 |
|---|---|
| `lib/share/` | 系统分享接收、文本/链接归一、附件复制落盘、文本收集合并/分散（TextCollector） |
| `lib/data/` | sqflite 三表（inbox_items/daily_metrics/ai_task_queue）+ Repository（UI/MCP 共用查询入口） |
| `lib/action/` | Human-AI 对称性核心：命令协议 `commands.dart`（ItemCommand/CommandResult/CommandActor/ActionException）+ 唯一写入口 `ItemActionHandler.execute/executeAll`（事务批量）+ machine_json Schema 校验 |
| `lib/ai/` | AiReconstructor 抽象/占位实现/Registry + 队列消费者 + 端侧翻译层（`translation.dart`/`translation_mlkit.dart`/`translate_reconstructor.dart`/`language_codes.dart`）+ 音轨提取 `audio_extract.dart` |
| `lib/mcp/` | JSON-RPC、工具集（PRD §7 全量 10 工具）、Streamable HTTP 服务 |
| `lib/service/` | McpController（token/开关/前台保活总控） |
| `lib/pages/` | 5 tab 主壳（时光机/全部/AI 分类/保险箱/设置）、详情、速记、最近删除 |
| `lib/ui/` | ItemViewTemplate/ItemViewRegistry、ContentCard 等 UI 框架件 |
| `mcp-bridge/` | 桌面 stdio↔HTTP 桥接器（纯 Node，零依赖） |
| `test/` | 数据层/动作层/收集模式/队列/MCP 协议单测（VM，ffi 内存库） |

## 命令（2026-09-27 实测）

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter pub get                 # 依赖（pub.dev 直连偶发停滞，重跑即可）
flutter analyze                 # 静态检查 → 0 issue 为交付线
flutter test                    # 单测（MCP 协议/文本归一/自更新）→ 全过为交付线
node mcp-bridge/e2e-check.mjs   # 桥接端到端 → E2E PASS
flutter build apk --debug       # 构建 → build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release     # 自更新发布用整包（debug 签名，个人使用可用）
adb reverse tcp:8765 tcp:8765   # USB 场景让桌面访问手机端 /mcp
```

## 环境硬约束

- Flutter 在 `~/flutter`（tarball 安装，不在 PATH），Android SDK 在 `~/android-sdk`（cmdline-tools + platform-tools + platforms;android-36/37.0 + build-tools;36.0.0），**每条命令都要显式 export PATH/ANDROID_HOME**
- **compileSdk 固定 37**（插件 receive_sharing_intent 1.9.0 的 AAR metadata 硬要求，低于 37 会在 checkDebugAarMetadata 失败）；**targetSdk 固定 34**（35+ 的 dataSync 前台服务有 6h/24h 限额）——两处都在 `android/app/build.gradle.kts`，改动前必读 docs/architecture/overview.md「关键决策」
- pub 下载卡住的表现是 hosted 包数不增长且 `_temp/` 残留——清 `_temp` 后重跑，勿盲目重试超过 2 次
- 模拟器/真机不在本机，涉及 UI/前台服务的验证只能真机侧载后人工确认，本机验证止步 analyze/test/build

## 插件 API 口径（改前先读 pub 缓存源码，勿凭旧版记忆）

> **保鲜提醒**：本节内容按当前版本号锁定，升级任一插件时必须同步核实并更新对应行（含硬约束是否仍成立），否则本节即失真。

- `receive_sharing_intent` 1.9.0：`SharedMediaFile{path, thumbnail, duration, type, mimeType, message}`（无 source 字段），类型枚举 `SharedMediaType.{image,video,text,file,url}`
- `flutter_foreground_task` 11.0.3：先 `init()` 再 `startService(serviceTypes: [ForegroundServiceTypes.dataSync], ...)`；manifest service 名不可改
- `share_plus` 13.3.0：`SharePlus.instance.share(ShareParams(text:, title:, files:))`
- `google_mlkit_text_recognition` 0.17.1：`TextRecognizer(script: TextRecognitionScript.chinese)` + `InputImage.fromFilePath`；Android 走 Play 服务（模型按需下载，首次需联网），**无 GMS 设备不可用**（bundled 变体适配待做）
- `speech_to_text` 7.5.0：`initialize()` + `listen(onResult:, listenOptions: SpeechListenOptions(onDevice: true))`；**仅实时流、无文件转写**——速记录音转写在采集时与录音同步完成，转写文本随 raw 层入库
- `google_mlkit_translation` 0.15.1：`OnDeviceTranslator(sourceLanguage:, targetLanguage:)` + `translateText(text)` + `close()`；`OnDeviceTranslatorModelManager`（`isModelDownloaded`/`downloadModel`/`deleteModel`，模型名 = BCP-47 码）；语言包经 Play 动态下发，**国内通常不可达**——`isAvailable` 必须查语言包就绪，未就绪即落 Noop 保留原文。**翻译无 bundled 变体**（依赖即 `com.google.mlkit:translate`，只有 thin 一种，不像 OCR 的 `text-recognition-chinese` 可打进 APK），API 也没有指定本地模型路径的入口，**语言包不能侧载**；语言包一旦下载完成，翻译本身纯端侧、断网可用。**语言包不可导出再分发**（Google 知识产权 + Play 服务条款；且落在 GMS 私有目录、由 GMS 校验，孤立文件无法被 API 加载）——要「可分发给别人」的离线翻译只能走开源模型自托管（OPUS-MT / NLLB）
- `ffmpeg_kit_flutter_new_min` 3.6.2（底层 `com.antonkarpenko:ffmpeg-kit-min:2.2.2`）：**min 变体无任何外部库**（README 包表 min 列 = `-`）——可编码仅 ffmpeg 内置者（`aac` / `flac` / `pcm_s16le` / `alac`），**mp3 / vorbis / opus 编码不可用**（需 lame / libvorbis / libopus，只在 `ffmpeg_kit_flutter_new_audio` 及以上变体）。**流复制 `-c:a copy` 不需要编码器**，故源为 mp3/opus/vorbis 时照样能导出 mp3/ogg（无损、秒出）——这是 min 变体下「多支持格式」的唯一正解。含 `FFprobeKit`（探源编码用），`FFmpegKit.executeWithArguments` + `ReturnCode.isSuccess(code)`（可空安全）
- `record` 7.1.1：`AudioRecorder()` + `hasPermission()` + `start(RecordConfig(encoder: AudioEncoder.aacLc), path:)` + `stop()` 返回落盘路径

## 开发规约（硬规则）

> 下列为拾贝项目级硬规则，源自实踩坑的显式决策（均在 `context/epics/goodshare/memory.md` 有记录），优先级等同 memory 硬规则。新代码若违反即视为缺陷，Code Review / AI 生成代码须主动核对。

- **R1 错误必须被用户与 AI 共同感知（2026-09-28，用户原话「错误要描述清楚原因被用户给感知到，这样未来对 ai 也是优好的」）**：任何会让任务「失败 / 无产出」的路径，失败原因不能只 `debugPrint` 静默丢失。原因要落 `ai_task_queue.last_note`，并**同时**（a）进 UI 状态反馈（详情页状态条 / 任务队列页 `last_note`，失败时红字）与（b）进 MCP 返回体——现状是 `get_item` 回传 `last_task{action,status,note}`，让 AI 读到与用户**同一份**文字。**同一份可观测状态，人看到啥 AI 看到啥；否则 AI 只能盲重触发**。管线给的具体 `note` 优先于按状态猜的兜底文案；失败 / 空产出都要给**可行动的下一步**，不要只说「失败」。落点：管线 `ReconstructResult.note` + `QueueConsumer.catch` 写 `finishTask('failed', note:)` + 完成也写 `result.note`（「完成但无产出」不是静默成功）。

- **R2 Human-AI 对称性（架构底色）**：命令协议 `commands.dart` 是唯一写入口，所有写操作走 `ItemActionHandler.execute/executeAll`；写结果经 `machine_json` 校验且可被 MCP 读回。人点按钮与 AI 调工具应触达同一逻辑、读到同一口径——这是 R1「同一份状态」的支撑。

- **R3 异步队列「降级不卡死」必须配「结果可观测」（2026-09-28，翻译 + 转写两次踩坑）**：占位 / 兜底不要记成「成功」（`is_processed=1`）；「完成但无产出」要单独成档并明示原因（如转写空产出 = 语言与所选模型不匹配），否则静默成功与失败在用户眼里完全一样，等于把不确定性转嫁给用户。R1 与 R3 同一脉络：**可观测是降级的必要条件**。

- **R4 用户约束优先、不擅自换依赖 / SDK 版本**：用户明确「不换依赖 / 不改 SDK 版本」时，先在原约束内寻出路（如 ffmpeg min 变体用 `-c:a copy` 流复制而非升级 audio 变体；国内语言包不可达就落 Noop 保留原文而非换库）；需突破约束先询问。
