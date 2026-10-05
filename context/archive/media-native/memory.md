---
dev-loop: memory
format: v1
epic: media-native
total-merged: 2
last-merge: 2026-10-03
---

# media-native · FFmpeg→平台原生媒体能力替换（已完结 2026-10-03）

- ffmpeg_kit 全系退役（P1 探测/P2 ASR 音频链/P3 切片/P4 音轨导出/P5 拆包全落地）：MediaBridge.kt 通道 `goodshare/media`（videoDurationMs/audioCodec/decodeMonoPcm/trimVideo/exportAudio）+ lib/media/ 接口 + media3 Transformer 1.9.2 硬编切片；16k 重采样走 Dart pcm_resample.dart（windowed-sinc，Isolate.run）
- 体积对拍：ffmpeg 原生库 17.9MB/ABI→0；release APK 388MB→293.7MB（ffmpeg 清零）→147.7MB（ABI 收敛）=-74%
- ABI 收敛（SSOT 修正）：gradle.properties `disable-abi-filtering=true` + abiFilters 按 split-per-abi 属性门控（FlutterPlugin 默认强注入全 ABI 须禁用；abiFilters 与 AGP splits 并存被拒）；x86_64 模拟器 run 不可用（用户拍板不需要）
- 降级契约：探测/解码/导出失败一律 null 非阻断；冷门格式（ac3/wma）明示「暂不支持」，云端体系后续（todos goodshare·候）
- 验证：analyze 0 / 全量 441 绿 / debug+release 构建 ✓；真机验收完成（2026-10-03 用户确认任务结束）
- ADR 已随归档移至 context/archive/media-native/decisions.md

## 断点
- [断点] 已完结并归档（2026-10-03）——目录移入 context/archive/media-native/，恢复流程不再读取
