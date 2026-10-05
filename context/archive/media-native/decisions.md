---
dev-loop: decisions
format: v1
epic: media-native
total-merged: 0
last-merge: none
---

# decisions · media-native（2026-10-03 随 epic 归档迁入）

### [2026-10-03] FFmpeg→平台原生媒体能力替换（体积驱动结构性重构） (src: 用户)
**场景/痛点**：`ffmpeg_kit_flutter_new_min_gpl` 原生库按 ABI 打包致包体积超出便签应用应有水位（用户「已经超过一个便签应用应该有的体积了」）；且原包 Arthenica 2025 年初官方退役，现用社区 fork（sk3llo/antonkarpenko）存在单点存续风险。现有用途五件：时长探测、音轨编码探测、ASR 16k mono WAV 转码、切片 libx264 区间重编码、音轨导出（copy/aac/flac/wav）。

**可选方案**：
- A. video_compress 类轻量包替代——否决：只出 MP4+AAC，无音频提取/无 WAV 重采样/无精确区间重编码，ASR 与切片链路架构上覆盖不了；Android 无 cancel，维护节奏一般
- B. 降 min 变体 + 切片改硬编——可行但半程：省 x264/x265 等数 MB，ffmpeg 运行时仍在，fork 存续风险未除
- C. 平台原生 API 接口化彻底替换——体积趋零（media3 Transformer 净增 2-4MB 但换 ffmpeg 整体出清），对齐「压缩走系统硬件编码器」既有拍板与 goodshare-arch 跨端能力接口化约束；代价=自维护 Kotlin/Swift 薄实现 + 解码格式覆盖收窄
- （曾议）media_kit/libmpv 系——否决：体积不降反增，塞入播放器

**最终决定**：走 C（用户拍板「我打算使用路线二，现在开发阶段没用户」）。分期 P0 体积基线→P1 探测→P2 ASR 音频链→P3 切片（media3 Transformer）→P4 音轨导出→P5 拆包。冷门格式（ac3/wma 等原生解不了）现阶段一律降级提示「格式不支持」不做静默失败，后续走云端体系（todos goodshare·候）。

**AI 洞察**：①探测/提取/切片全是 OS 内置能力，ffmpeg 为此背整套转码运行时是结构性错配；唯一非平凡缺口是 Android 无系统重采样 API（16k 下采样需自写 windowed-sinc，iOS AVAudioConverter 白送）。②FLAC 编码 Android MediaCodec 各 ROM 可用性不一，P4 落地时按能力探测门控。③ffmpeg-kit fork 的真实风险是 Flutter 大版本升级断档适配——升级时先验证 min_gpl 是否同步，再评估此迁移进度。
