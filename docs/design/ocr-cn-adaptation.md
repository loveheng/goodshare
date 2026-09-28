---
status: draft
updated: 2026-09-28
---

# OCR 国内手机适配（Android + GMS）

> 结论：**有 GMS ≠ OCR 可用**。根因在 ML Kit 中文识别模型的「交付方式」，不在 GMS 本身。默认插件走动态下载，国内 Play 不可用则失败；适配关键是切到 **bundled 中文库**，把模型打进 APK。

## 1. 现状

- 依赖：`pubspec.yaml` 引 `google_mlkit_text_recognition: ^0.17.1`，Dart 侧 `OcrReconstructor` 用 `TextRecognizer(script: TextRecognitionScript.chinese)`；
- 默认（unbundled）底层依赖 `com.google.android.gms:play-services-mlkit-text-recognition`，**中文模型经 Play 商店动态下发**；
- 降级：识别失败 try/catch → 占位文本，不卡死 AI 队列（已就绪，但**静默**）。

## 2. 国内可用性判断

| 条件 | 结果 |
|---|---|
| 有 GMS + Play 商店可正常下载 ML Kit 模块 | OCR 可用（海外/部分港版） |
| 有 GMS 但 Play 被阉割/无网络（多数国内 ROM） | **默认 unbundled 失败** → OCR 不可用 |
| bundled 中文库（模型随 APK） | **离线可用，与 Play 无关** ← 目标适配 |

用户环境：安卓已装 GMS → 障碍是「中文模型动态下载」，非 GMS 缺失。

## 3. 必须做的适配：bundled 中文库

`android/app/build.gradle.kts`：用 bundled 中文 artifact 替换默认 unbundled 通用 artifact。

```kotlin
dependencies {
  // 默认 google_mlkit_text_recognition 插件传递的是 bundled 通用库
  // com.google.mlkit:text-recognition:16.0.1（仅 latin，中文模型缺失）。
  // 国内改为 bundled 中文库：模型打进 APK，离线可用，不依赖 GMS/Play。
  // 注意：bundled 坐标是 com.google.mlkit:*；com.google.android.gms:play-services-mlkit-*
  // 是 unbundled 变体（模型经 Play 动态下载），国内不可用，勿用。
  implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}
```

- Dart 侧 `TextRecognizer(script: TextRecognitionScript.chinese)` **不变**；bundled/unbundled 仅底层 Gradle 依赖差异；
- 现有 `build.gradle.kts` 中的 GMS unbundled 中文行（`play-services-mlkit-text-recognition-chinese`，2026-09-27「标准设备优先」决策）直接**替换**为上一行 bundled 坐标；
- 插件 0.17.1 传递依赖为 `com.google.mlkit:text-recognition:16.0.1`（bundled 通用版，仅 latin 脚本模型）——与中文 bundled 库**同组同体系，无重复类冲突，无需 exclusion**（若构建报重复类再按实际依赖图处理）。

## 4. 真机验证清单

- 机型矩阵：MIUI / HyperOS / ColorOS / HarmonyOS / 海外版国内使用 各至少 1 台；**建议加一台无 GMS 设备**——bundled 变体（`com.google.mlkit:*`）为纯静态库，理论上无 GMS 也可用，实测可扩大适配覆盖面（若通过，§7 备选方案可整体废弃）；
- 步骤：**断网 + 关闭 Play 商店** → 收集一张含中文的图 → 确认 OCR 文本产出（证明模型已打包、未走下载）；
- 监控 `OcrReconstructor._ocr` 的 catch 是否触发，确认降级路径。

## 5. 降级与提示（改进项）

- 现状：失败静默降级为占位文本，用户无感知；
- 建议：复用 `google_api_availability`（已在 pubspec）在设置页显示「OCR/GMS 能力」状态，明确提示不可用，与翻译层 ML Kit 可用性提示一致；
- 队列不卡死的兜底已就绪，无需改。

## 6. iOS

ML Kit 在 iOS 模型随 SDK 打包，无 Play 下载环节，国内 iPhone 直接可用，**无此适配问题**。

## 7. 备选（仅当 bundled 变体仍不可用）

若个别设备 bundled 中文库也无法初始化（纯静态库理论上不依赖 GMS，概率低），再上**完全离线方案**：`flutter_onnxruntime` + PaddleOCR-nano（自管 ONNX 检测+识别模型，需自实现后处理 pipeline），即 `ocr_reconstructor.dart` 注释预留的「无 GMS 设备 bundled OCR 变体」。**优先 §3 bundled 方案，真机验证通过前不换引擎**。

## 8. 体积影响

bundled 中文模型会把约数 MB~十余 MB 打进 APK（精确值构建后实测）；相对 ASR 模型（数百 MB 下载）增量极小，可接受。

## 9. 待定 / 需实测

- ~~插件 0.17.1 依赖图：确认排除 unbundled 通用 artifact 是否必要及确切写法~~（已核实：插件传递 bundled 通用版 `com.google.mlkit:text-recognition:16.0.1`，与中文 bundled 库同组，无需排除）；
- bundled 中文库确切版本号与 APK 体积增量（实测）；
- 真机矩阵是否全部离线通过（§4，含无 GMS 设备验证 bundled 是否摆脱 GMS 依赖）。
