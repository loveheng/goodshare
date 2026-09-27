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
| `lib/share/` | 系统分享接收、文本/链接归一、附件复制落盘 |
| `lib/data/` | sqflite 单表 + Repository（UI/MCP 共用入口） |
| `lib/mcp/` | JSON-RPC、工具集（list/get/add_item）、Streamable HTTP 服务 |
| `lib/service/` | McpController（token/开关/前台保活总控） |
| `lib/pages/` | 收集列表页、MCP 设置页 |
| `mcp-bridge/` | 桌面 stdio↔HTTP 桥接器（纯 Node，零依赖） |
| `test/` | MCP 协议/文本归一单测（VM，ffi 数据库工厂） |

## 命令（2026-09-27 实测）

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter pub get                 # 依赖（pub.dev 直连偶发停滞，重跑即可）
flutter analyze                 # 静态检查 → 0 issue 为交付线
flutter test                    # 单测 → 全过为交付线
node mcp-bridge/e2e-check.mjs   # 桥接端到端 → E2E PASS
flutter build apk --debug       # 构建 → build/app/outputs/flutter-apk/app-debug.apk
adb reverse tcp:8765 tcp:8765   # USB 场景让桌面访问手机端 /mcp
```

## 环境硬约束

- Flutter 在 `~/flutter`（tarball 安装，不在 PATH），Android SDK 在 `~/android-sdk`（cmdline-tools + platform-tools + platforms;android-36/37.0 + build-tools;36.0.0），**每条命令都要显式 export PATH/ANDROID_HOME**
- **compileSdk 固定 37**（插件 receive_sharing_intent 1.9.0 的 AAR metadata 硬要求，低于 37 会在 checkDebugAarMetadata 失败）；**targetSdk 固定 34**（35+ 的 dataSync 前台服务有 6h/24h 限额）——两处都在 `android/app/build.gradle.kts`，改动前必读 docs/architecture/overview.md「关键决策」
- pub 下载卡住的表现是 hosted 包数不增长且 `_temp/` 残留——清 `_temp` 后重跑，勿盲目重试超过 2 次
- 模拟器/真机不在本机，涉及 UI/前台服务的验证只能真机侧载后人工确认，本机验证止步 analyze/test/build

## 插件 API 口径（改前先读 pub 缓存源码，勿凭旧版记忆）

- `receive_sharing_intent` 1.9.0：`SharedMediaFile{path, thumbnail, duration, type, mimeType, message}`（无 source 字段），类型枚举 `SharedMediaType.{image,video,text,file,url}`
- `flutter_foreground_task` 11.0.3：先 `init()` 再 `startService(serviceTypes: [ForegroundServiceTypes.dataSync], ...)`；manifest service 名不可改
- `share_plus` 13.3.0：`SharePlus.instance.share(ShareParams(text:, title:, files:))`
