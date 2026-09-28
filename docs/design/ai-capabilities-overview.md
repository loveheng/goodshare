---
status: draft
updated: 2026-09-28
---

# 端侧 AI 能力综合评估（OCR / 音视频转写 / 字幕 / 图片标注 / 翻译）

> 将分散在 `asr-subtitle.md`、`image-annotation.md`、`ocr-cn-adaptation.md` 中的设计做横向综合：统一状态、复用关系、风险与落地优先级。各子能力细节见对应文档。

## 1. 能力矩阵

| 能力 | 状态 | 作用 item 类型 | 引擎 / 依赖 | 平台策略 | 相对工作量 |
|---|---|---|---|---|---|
| 文字态产出（human_md / machine_json / 翻译文本） | 已落地（贯穿层） | 全部 | 各重构器 + 翻译层 | 纯 Dart | — |
| OCR 文字识别 | 已落地，**国内待适配** | image / url | ML Kit（`google_mlkit_text_recognition`） | Android 需 bundled；iOS 已打包 | 小（gradle + 真机） |
| 音频转写（纯文本） | 已落地 | audio | ffmpeg + sherpa-onnx | 纯 Dart 跨平台 | — |
| 音频字幕（SRT/VTT） | 设计中，未落代码 | audio | + silero VAD 分段 | 纯 Dart 跨平台 | 中 |
| 视频转写 / 字幕 | 设计中，零新增 | video | 复用音频 `_toWav16k` + VAD | 纯 Dart 跨平台 | 极小 |
| 图片标注（overlay） | **原型已落地**（最简画布，UI 待正式化） | image | CustomPainter + GestureDetector | 纯 Dart 跨平台 | 中 |
| 翻译（文本层） | **骨架已落地**（2026-09-28） | 文本 / 任意 | ML Kit + Noop；OPUS-MT / Apple 待插拔 | **按系统 API 分流** | 骨架中已完；真离线引擎中–大 |

## 2. 公共基建复用

- **`ffmpeg_kit_flutter_new_min`**：音频转码与视频抽音轨**同一命令**（`-ar 16000 -ac 1 -c:a pcm_s16le`），视频字幕零新增依赖。
- **sherpa-onnx + silero VAD**：音频 / 视频字幕**完全共用**同一识别与分段管线，仅输入容器不同。
- **`subtitle.dart`（待建）**：cue 结构 + SRT/VTT 序列化，音视频字幕统一消费。
- **`CustomPainter`**：图片标注纯前端，与音视频无关但同为纯 Dart。
- **`ItemViewRegistry`**：各类型详情页统一扩展点（image/video/audio 各自专属区，框架零改动）。
- **降级策略「占位不卡死」**：OCR 与 ASR 均遵循——底层不可用时写占位文本，绝不阻塞 AI 队列。

## 3. 平台分流对照

| 能力 | 是否分流 | 原因 |
|---|---|---|
| ASR / 字幕 / 视频 / 图片标注 | **不分流** | 引擎自托管（sherpa / CustomPainter），跨平台统一 |
| 翻译 | **分流** | 借力系统 API（ML Kit 仅 Android / Apple 仅 iOS），系统侧分裂；⚠️ ML Kit 语言包经 Play 动态下载，**国内即使有 GMS 也大概率不可用**（见 `asr-subtitle.md` §8） |

结论：除翻译外，所有媒体 AI 能力都**不应**做平台双实现；差异只在「外围工程」（模型存放/iCloud 备份、后台执行窗口、自托管下载）。

## 4. 技术风险评级

| 风险点 | 等级 | 缓解 |
|---|---|---|
| 国内 OCR 失效（动态下载模型被墙） | 中 | §3 bundled 中文库 + 真机矩阵验证 |
| gradle unbundled/bundled 依赖冲突 | 低–中 | 排除写法构建实测（见 `ocr-cn-adaptation.md` §3） |
| ASR 模型体积（数百 MB 下载） | 低 | 按需下载 + 断点续传；R2 迁移为低优先可选项 |
| VAD 分段字幕准确性 | 低–中 | 对齐官方 `generate-subtitles.py` 参数 |
| 图片标注手势 / 缩放对齐 | 低 | 归一化坐标 + InteractiveViewer |
| 翻译 OPUS-MT 体积（单语对 ~246MB） | 已排除 | 退居兜底，默认走系统引擎 |
| 翻译 ML Kit 语言包国内不可达（Play 动态下载） | 已拍板 | 国内接受 `source-only` 默认（设置项明示），不自托管/不云 API；海外仍走 ML Kit。骨架已落地：`MlKitTranslationEngine.isAvailable` 把语言包就绪纳入门禁，未就绪即落 Noop，产物保留原文（见 `asr-subtitle.md` §8） |
| 长视频转写临时 WAV 体积与超时（~115MB/小时） | 中 | 分段转写 + 临时文件清理 + 视频单独超时（见 `asr-subtitle.md` §11） |

## 5. 优先级与建议落地顺序

| 序 | 能力 | 理由 | 工作量 |
|---|---|---|---|
| 1 | **OCR 国内适配（bundled）** | 现有 OCR 在国内可能已失效；成本极低，解锁核心用户群（bundled 理论不依赖 GMS，或可同时覆盖无 GMS 设备） | 小 |
| 2 | **字幕批次（音频 + 视频一起交付）** | 二者共享同一批新增基建（VAD assets 入库 → subtitle.dart → cue 通道 → reconstructor 路由收 video → 详情页导出入口），拆开无意义；开工前先拍板翻译层国内策略（见 §4 风险表） | 中 |
| 3 | **图片标注正式化** | 原型已落地验证逻辑，剩余工具栏/手势命中/角标 | 中 |
| 4 | **翻译层** | 骨架已落地（2026-09-28 用户拍板「骨架先行 + ML Kit」）；剩余真离线引擎与 iOS Apple 实现按既有接口插拔 | 骨架已完 / 引擎中–大 |
| 5 | **R2 模型源迁移** | 现状 hf-mirror 可用，非阻塞（见 `context/todos.md` low） | 中 |

> 排序原则：**低成本高价值优先**；已落地但国内失效的 OCR 置顶；音/视频字幕共享基建合并为一个批次；依赖下载/模型的排在后。

## 6. 跨文档索引

- `asr-subtitle.md` — 音频转写与字幕、VAD、翻译层、跨平台、视频字幕（§11）
- `image-annotation.md` — 图片标注（非破坏性 overlay）
- `ocr-cn-adaptation.md` — OCR 国内 Android 适配（bundled 中文库）
- `context/todos.md` — R2 模型源迁移（低优先待办）

## 7. 关键未决项汇总

- [已确认] 字幕输出 SRT + VTT **双份**（零成本，覆盖最多播放器与编辑工具）；
- [已确认] VAD 随 App 内置 assets（~2.3MB），字幕默认开启，不再作为下载项；
- ~~翻译层国内可用性对策~~（[已拍板 2026-09-28] 接受国内 `source-only` 默认，不自托管/不云 API；见 `asr-subtitle.md` §8）；
- 图片标注类型集（矩形/箭头/笔迹/文字/序号是否够；模糊明确不做）；
- 翻译失败重试是否走 `ai_task_queue` 重入队（倾向不重入队）；
- OCR 真机矩阵是否全部离线通过（§4 of `ocr-cn-adaptation.md`，含无 GMS 设备）。
