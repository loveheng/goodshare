---
name: goodshare-workflow
description: 拾贝 goodshare（Flutter/Dart 分享收集器+内嵌 MCP 服务）工作流事实源：三件套分工路由、规范数据维护触发器、构建/分析/测试/质检流水线/发布链命令唯一出处、环境硬约束、lessons 使用时机、插件 API 口径、开发规约 R1-R5。构建报错、跑测试、换机器、发布前先读本 skill，命令勿凭记忆写。
---

# goodshare 工作流事实源

> 项目一句话：**拾贝（goodshare）**——Flutter 分享收集器（Android 首发），内嵌 Streamable HTTP MCP 服务，桌面 AI 客户端经 `mcp-bridge/stdio-bridge.mjs` 或直连读取收集内容。

## 定位边界（三件套分工，防双源）

| 需要什么 | 查哪里 |
|---|---|
| **写码规则**：分层矩阵 / 护栏映射 / 落点决策 / 质量门禁 | `docs/project/coding-standards.md`（结构立法 SSOT） |
| **写路径行为规则**：七条硬规则 / 三套机制 / 自查清单 | `goodshare-arch` skill（论证 SSOT = `docs/architecture/human-ai-parity.md`） |
| **立法原则 / AI 操作者 / 反模式 / 明确不做** | `docs/engineering/ai-dev-spec.md` + 本 skill「开发规约 R1–R5」 |
| **UI / 移动端健壮性** | `goodshare-ui` / `goodshare-mobile` skill |
| **改前定位**：某功能的代码/文档落点 | `docs/project/index.md`（数据；登记规约 = `goodshare-index` skill） |
| **命令与环境** | 本 skill（构建/测试/流水线/发布唯一出处） |

lib/ 的分层结构与领域归属**不在本 skill 登记**——见 `docs/project/index.md`（数据）与 `goodshare-arch`（分层矩阵）。现行 epic 与过程态查 `context/CURRENT` / `context/epics/`，本 skill 不登记。单测环境口径：`test/` 跑 VM + ffi 内存库，UI 无关的真实异步在 widget 测试里须 `runAsync`（R5）。

## 读码纪律（三段式，省 token 与正确性兼得）

文档比代码省 token，但文档**有损且可能失真**（实证：mcp-orchestration 阶段一 memory.md 声称「toolsList 已实现」与代码不符，照文档下手会建在错误前提上）。三段式读法：

| 阶段 | 动作 | 成本量级 |
|---|---|---|
| ① 文档建图 | 先读 index.md 落点 + memory.md 决策 + devlog 变更记录，拿「为什么 / 边界 / 落点」 | 几十~几百 token |
| ② 定向读码 | LSP / semantic search 只读相关符号与区域（readSymbol / 行号范围），**禁整文件通读** | 几百 token/次 |
| ③ 关键断言实证 | 文档每个「已实现」结论动手前抽查一处代码确认；行号引用须实测（会漂移，实证：`settings_page.dart:19 → :35`） | 一次性 |

- 「文档 + 定向读码」比「通读代码」省 token；「只读文档」省的是阅读成本、付的是正确性风险（返工远超省下的 token）。
- 本纪律即 devlog「背景核查（关键）」惯例的形式化——评估设计动笔前先实证，不当文档复读机。

## 规范数据维护触发器（发现即维护，不当旁观者）

**判据三问**（决定要不要写）：① 是架构分流/准入规则？② 变更频率是月/季度或重大架构变更级？③ 缺了它后续开发或 Review 是否失去判定依据？——三问命中即按下表维护；日常需求流水账禁写。

| 工作中发现的信号 | 本 skill 触发（workflow 侧） | 同轮路由（非本 skill 维护） |
|---|---|---|
| **新插件 / 插件升级** | 「插件 API 口径」表同步对应行（含硬约束是否仍成立——保鲜提醒见该节） | 坑与解法按 dev-loop lessons 协议记 `context/lessons.md` |
| **新增 `lib/` 一级域** | `coding-standards` §1 矩阵加行 + §4 三处同步 | 归属表登记 `docs/project/index.md`（**goodshare-index skill** 纪律） |
| **写路径硬规则新增** | 与 `goodshare-arch`「硬规则」+ `docs/engineering/ai-dev-spec.md` **双边同步**，禁止单边新增 | 机械可判的同步 `arch-guard` 规则 |
| **`arch-guard` 命中红灯** | — | 按 `goodshare-arch` 处置：改结构优先；确属历史遗留走白名单纪律（只减不增，见 `scripts/agent-tools/arch-guard.sh`） |
| **构建/工具链踩坑（排查 >15min 的确定性故障）** | — | lessons 底部流水录入（格式与归并协议 = 全局 dev-loop，见下节） |

## 环境硬约束

- Flutter 在 `~/flutter`（tarball 安装，不在 PATH），Android SDK 在 `~/android-sdk`（cmdline-tools + platform-tools + platforms;android-36/37.0 + build-tools;36.0.0），**每条命令都要显式 export PATH/ANDROID_HOME**
- **compileSdk 固定 37**（插件 receive_sharing_intent 1.9.0 的 AAR metadata 硬要求，低于 37 会在 checkDebugAarMetadata 失败）；**targetSdk 固定 34**（35+ 的 dataSync 前台服务有 6h/24h 限额）——两处都在 `android/app/build.gradle.kts`，改动前必读 docs/architecture/overview.md「关键决策」
- pub 下载卡住的表现是 hosted 包数不增长且 `_temp/` 残留——清 `_temp` 后重跑，勿盲目重试超过 2 次
- 模拟器/真机不在本机，涉及 UI/前台服务的验证只能真机侧载后人工确认，本机验证止步 analyze/test/build

## 经验教训使用时机（context/lessons.md）

**数据住 `context/lessons.md`；录入格式、归并与清零协议住全局 dev-loop（lessons）**——本文件不复制协议正文（防双源），只锁三个使用时机：

| 时机 | 场景 | 动作 |
|---|---|---|
| **写前检索** | 动高风险模块前（widget 测试 / 平台插件 / 媒体原生 / sliver 布局…） | 先查对应模块节，提取已知反模式，在写代码第一分钟避开暗坑 |
| **排障检索** | 构建 / 测试 / 真机联调报错时 | 取报错堆栈关键字在 lessons.md 检索，先读解法再动手，禁从零排查 |
| **升维销项** | 坑解决后 | 按 dev-loop 协议落底部流水，归并时提炼成避坑规则正文；固化级坑升级进本 skill 对应节（先例：ABI 约束、测试超时） |

## 研发闭环命令（唯一出处）

所有命令显式携带 SDK 环境变量：

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter pub get                 # 依赖拉取（pub.dev 直连偶发停滞，重跑即可）
```

> 命令双入口：项目工具池 `toolbox run <工具>`（canonical，别名见注释）与裸脚本 `scripts/agent-tools/<工具>.sh` 等价；无 toolbox 环境用裸脚本。

### 1. 提交前质检流水线（PR 交付红线，按耗时从小到大）

任一步失败**禁止提交**；禁止 `--no-verify` 绕过门禁：

```bash
toolbox run arch-guard            # ag   # ① 架构红线扫描（秒级：UI 禁直连 repo 写/内联 json/Platform 分支/裸 Image 等 7 条）
flutter analyze                   #      # ② 静态检查 → 0 issue 为交付线
flutter test --timeout 60s        #      # ③ 单测 → 全过为交付线（⚠️ 务必带 --timeout，见「测试超时」）
node mcp-bridge/e2e-check.mjs     #      # ④ 桥接端到端（改 mcp-bridge/ 时）→ E2E PASS
```

- lib/ 与 docs/ 混改时用聚合门禁按改动范围分派：`toolbox run pre-commit-gate`（pcg；无 lib/ 改动跳 arch-guard、无 docs/ 改动跳 docs-lint）；提交信息过 Conventional Commits 校验：`toolbox run commit-msg-gate`（cmg，commit-msg 钩子）。
- ① 命中红灯 = 按 `goodshare-arch` 处置：改结构，不得申请加白名单（只减不增）。

### 2. 本地运行与真机联调

```bash
flutter build apk --debug         # 构建 → build/app/outputs/flutter-apk/app-debug.apk
adb reverse tcp:8765 tcp:8765     # USB 场景让桌面访问手机端 /mcp
toolbox run build-apk --install   # apk  # 构建 debug 包并 adb 安装（--release/--abi 出 release 分包，--fat 整包）
```

### 3. 打包与发布（Release Workflow）

发布链 = **升版本 → dry-run → 发布**（release-r2 读 `pubspec.yaml` 的 version 行，必须先 bump）：

```bash
toolbox run bump-version --patch  # bump # ① 升版本：--patch/--minor/--major（先 --help 看全参数）
bash scripts/release-r2.sh -n     #      # ② dry-run 预览全链步骤，不构建不上传
bash scripts/release-r2.sh --commit  #   # ③ 正式发布：release 整包（arm64 纯净，versionCode=pub build）→ sha256 → updates/goodshare-update.json → 上传 R2
                                  #      # --commit 把清单提交进仓库追溯（APK 本体被 .gitignore 忽略）
```

- 真身 = `scripts/release-r2.sh`（内部走 `scripts/upload-r2.mjs`）；R2 凭证配置见仓库根 `.env`（R2_* 与公开域，缺配置脚本会 FAIL 并列出缺失项）。

### 4. 构建异常自救（缓存重置急救包）

```bash
flutter clean && flutter pub get          # 基础缓存重置
cd android && ./gradlew clean && cd ..    # 深度原生构建缓存清理
```

- 构建类故障先查 `android/local.properties` 的 `sdk.dir` 与 `ANDROID_HOME` 指向，别先怀疑项目配置（lessons「构建」节）。

## 测试超时（2026-10-05 拍板，排查实录见 context/lessons.md）

- **widget 测试（`testWidgets`）的默认超时是 10 分钟**（`flutter_test/lib/src/binding.dart:2240`），普通 `test()` 才是 30 秒；`pumpAndSettle` 的 settle 超时恰好也是 10 分钟且文案同为「Test timed out after …」。后果：**任何"卡死类"故障都要等满 10 分钟才报，且 stack 全是 `<asynchronous suspension>`，看不出断点**，极易被误诊为「页面里有无限动画」。
- **本机与 CI 一律跑 `flutter test --timeout 60s`**：把 10 分钟兜底压到 60 秒，卡死类问题分钟级暴露（2026-10-05 实测：同一故障从 10:42 变成 ~1 分钟报错）。
- 看到「某个 widget 测试卡满超时」的第一嫌疑 = FakeAsync 里 await 了依赖真实时钟的东西（sqlite / 网络 / 未 mock 的插件通道），**先查 `await` 链，别先查动画**。断点定位手法：`print` 会被 reporter 缓冲不可靠，用**每步同步写文件的日志**（`File.writeAsStringSync(…, mode: append)`），卡死也能读到最后一步。

## ABI 约束（2026-10-03 用户拍板）

- **只保 arm64-v8a**：`android/gradle.properties` 设 `disable-abi-filtering=true` + `app/build.gradle.kts` defaultConfig `ndk.abiFilters=arm64-v8a`。机制：FlutterPlugin.configureAbiWithoutSplits 默认 clear 用户 abiFilters 强注入全 ABI，禁用后用户过滤才生效（源码 FlutterPlugin.kt:561-598）。
- `flutter build apk --release`（整包）与 `--split-per-abi --target-platform=android-arm64`（发布流水线拆分包）**均恒为 arm64 纯净产物（147.7MB）**：前者走 ndk.abiFilters（gradle.kts 内已按 `split-per-abi` 属性门控，避免与 AGP splits 并存冲突），后者走 AGP splits 分区；**x86_64 模拟器不可 run**（真机调试）。
- 升级 Flutter 时必须核实 `disable-abi-filtering` / `split-per-abi` 属性名仍有效（grep FlutterPlugin.kt）。

## 插件 API 口径（改前先读 pub 缓存源码，勿凭旧版记忆）

> **保鲜提醒**：本节内容按当前版本号锁定，升级任一插件时必须同步核实并更新对应行（含硬约束是否仍成立），否则本节即失真。

- `receive_sharing_intent` 1.9.0：`SharedMediaFile{path, thumbnail, duration, type, mimeType, message}`（无 source 字段），类型枚举 `SharedMediaType.{image,video,text,file,url}`
- `flutter_foreground_task` 11.0.3：先 `init()` 再 `startService(serviceTypes: [ForegroundServiceTypes.dataSync], ...)`；manifest service 名不可改
- `share_plus` 13.3.0：`SharePlus.instance.share(ShareParams(text:, title:, files:))`
- `google_mlkit_text_recognition` 0.17.1：`TextRecognizer(script: TextRecognitionScript.chinese)` + `InputImage.fromFilePath`；**已切 bundled 中文识别库**（`com.google.mlkit:text-recognition-chinese`，模型随 APK 打包），**无 GMS 设备也可用**（2026-09-30 起，GMS 检测已移除）
- ~~`speech_to_text`~~ **已移除**：速记录音改走 `record` 存音频文件 + Sherpa 端侧文件转写（手动触发，`lib/ai/asr*.dart`），采集时不再同步转写
- `google_mlkit_translation` 0.15.1：`OnDeviceTranslator(sourceLanguage:, targetLanguage:)` + `translateText(text)` + `close()`；`OnDeviceTranslatorModelManager`（`isModelDownloaded`/`downloadModel`/`deleteModel`，模型名 = BCP-47 码）；语言包经 Play 动态下发，**国内通常不可达**——`isAvailable` 必须查语言包就绪，未就绪即落 Noop 保留原文。**翻译无 bundled 变体**（依赖即 `com.google.mlkit:translate`，只有 thin 一种，不像 OCR 的 `text-recognition-chinese` 可打进 APK），API 也没有指定本地模型路径的入口，**语言包不能侧载**；语言包一旦下载完成，翻译本身纯端侧、断网可用。**语言包不可导出再分发**（Google 知识产权 + Play 服务条款；且落在 GMS 私有目录、由 GMS 校验，孤立文件无法被 API 加载）——要「可分发给别人」的离线翻译只能走开源模型自托管（OPUS-MT / NLLB）
- **ffmpeg_kit 全系已退役（2026-10-03，media-native P1-P5）**：探测/转写解码/切片/音轨导出全走平台原生——`lib/media/`（MediaToolkit 接口）+ `MediaBridge.kt`（goodshare/media 通道：videoDurationMs/audioCodec/decodeMonoPcm/trimVideo/exportAudio）+ media3-transformer 1.9.2（切片硬编）。时长/编码探测失败 null 非阻断；冷门格式（ac3/wma 等）导出/转写降级「暂不支持」文案，云端处理后续规划。ADR：context/decisions.md「media-native」
- `record` 7.1.1：`AudioRecorder()` + `hasPermission()` + `start(RecordConfig(encoder: AudioEncoder.aacLc), path:)` + `stop()` 返回落盘路径

## 开发规约（硬规则）

> 下列为拾贝项目级硬规则，源自实踩坑的显式决策（均在 `context/epics/goodshare/memory.md` 有记录），优先级等同 memory 硬规则。新代码若违反即视为缺陷，Code Review / AI 生成代码须主动核对。

- **R1 错误必须被用户与 AI 共同感知（2026-09-28，用户原话「错误要描述清楚原因被用户给感知到，这样未来对 ai 也是优好的」）**：任何会让任务「失败 / 无产出」的路径，失败原因不能只 `debugPrint` 静默丢失。原因要落 `ai_task_queue.last_note`，并**同时**（a）进 UI 状态反馈（详情页状态条 / 任务队列页 `last_note`，失败时红字）与（b）进 MCP 返回体——现状是 `get_item` 回传 `last_task{action,status,note}`，让 AI 读到与用户**同一份**文字。**同一份可观测状态，人看到啥 AI 看到啥；否则 AI 只能盲重触发**。管线给的具体 `note` 优先于按状态猜的兜底文案；失败 / 空产出都要给**可行动的下一步**，不要只说「失败」。落点：管线 `ReconstructResult.note` + `QueueConsumer.catch` 写 `finishTask('failed', note:)` + 完成也写 `result.note`（「完成但无产出」不是静默成功）。

- **R2 Human-AI 对称性（架构底色）**：命令协议 `commands.dart` 是唯一写入口，所有写操作走 `ItemActionHandler.execute/executeAll`；写结果经 `machine_json` 校验且可被 MCP 读回。人点按钮与 AI 调工具应触达同一逻辑、读到同一口径——这是 R1「同一份状态」的支撑。

- **R3 异步队列「降级不卡死」必须配「结果可观测」（2026-09-28，翻译 + 转写两次踩坑）**：占位 / 兜底不要记成「成功」（`is_processed=1`）；「完成但无产出」要单独成档并明示原因（如转写空产出 = 语言与所选模型不匹配），否则静默成功与失败在用户眼里完全一样，等于把不确定性转嫁给用户。R1 与 R3 同一脉络：**可观测是降级的必要条件**。

- **R4 用户约束优先、不擅自换依赖 / SDK 版本**：用户明确「不换依赖 / 不改 SDK 版本」时，先在原约束内寻出路（如 ffmpeg min 变体用 `-c:a copy` 流复制而非升级 audio 变体；国内语言包不可达就落 Noop 保留原文而非换库）；需突破约束先询问。

- **R5 widget 测试不得在 FakeAsync 下 await 真实异步（2026-10-05 用户拍板加固）**：`testWidgets` 跑在 FakeAsync（Timer 被假化），sqlite / 网络 / 未 mock 插件通道这类依赖**真实时钟或 isolate 消息**的调用在此环境里永不完成，`Future.timeout` 也救不了（Timer 同样被假化）——在测试体里裸 `await repo.add(...)` / `await Db.instance()` 的现象就是整个测试卡满超时且无有效 stack。写法：①**UI 无关的真实异步一律 `tester.runAsync(() async { … })` 包裹**（种子数据、落库断言、`DraftStore.load` 之类 DB 读同理；需在 tap 与 pumpAndSettle 之间给真实事件循环让位时插 `await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)))`）；②**页面级「UI + 真实 sqlite」组合原则上不写 widget 测试**——即使补了 runAsync，sqflite `txnSynchronized` 内部的 10s Timer 仍会让框架收尾报 *Pending timers*，且 FutureBuilder 每次 rebuild 再造新 timer，靠 `pump(Duration)` 推进也收敛不了；这类场景拆成「数据侧普通 `test()`」+「UI 侧纯组件 widget 测试」两处守（先例：标签 = `action_handler_test`(写路径) + `tag_editor_sheet_test`(组件)）。
