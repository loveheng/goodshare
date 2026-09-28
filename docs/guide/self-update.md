---
status: active
updated: 2026-09-27
---

# 自更新与热更指南

拾贝的更新体系分三层，按需启用：

| 层 | 机制 | 改什么 |
|---|---|---|
| 应用内自更新 | app 检查远程清单 → 下载 APK（带进度 + SHA-256 校验）→ 拉起系统安装器 | 一切（整包） |
| 配置热更 | 清单里的 `config` 段随检查更新下发并缓存 | 公告、MCP instructions、功能开关 |
| Shorebird | Dart 代码补丁，不重装生效（可选，需账号） | 仅 Dart 逻辑/UI |

## 1. 更新源托管（应用内自更新 + 配置热更）

任选一个静态托管（推荐 **gitee**，国内可达；github raw / 自建均可）：

1. 建一个仓库（可私有转公开 raw，或用 gitee Pages），建目录 `updates/`
2. 放两样东西：
   - `goodshare-update.json`（清单，格式见下）
   - APK 文件（如 `app-release.apk`）
3. 在 app「更新」页填入目录 URL，如 `https://gitee.com/<user>/<repo>/raw/master/updates`

### 清单格式 goodshare-update.json

```json
{
  "versionCode": 3,
  "versionName": "1.1.0",
  "apkUrl": "https://gitee.com/<user>/<repo>/raw/master/updates/app-release.apk",
  "sha256": "<apk 的 sha256，建议必填>",
  "changelog": "修复文本分享丢失；新增热更体系",
  "config": {
    "announcement": "公告文本，可省略",
    "announcementId": "2026-09-27-1",
    "mcpInstructions": "覆盖 MCP initialize 的 instructions，可省略",
    "flags": {}
  }
}
```

- `versionCode` 与 `pubspec.yaml` 的 `+N` 比较，**大于**才提示更新
- `sha256` 生成：`sha256sum app-release.apk`
- `config.mcpInstructions` 非空时会覆盖 MCP `initialize` 返回的服务说明（下次客户端连接生效）
- 公告随「检查更新」刷新并缓存，更新页展示

### 发布流程

```bash
flutter build apk --release           # 模板默认用 debug 签名，个人使用可用；正式分发请配 release 签名
cp build/app/outputs/flutter-apk/app-release.apk <更新源目录>/
sha256sum build/app/outputs/flutter-apk/app-release.apk
# 编辑 goodshare-update.json 的 versionCode/versionName/sha256/changelog
git add . && git commit && git push   # gitee raw 即时生效
```

## 2. Shorebird 代码热更（可选）

效果：Dart 代码补丁（UI/逻辑修复）免重装秒级生效；原生/插件/manifest 变更仍需走整包自更新。

前置：注册 shorebird.dev 账号；**注意 api.shorebird.dev 在国内部分网络不可直连**（2026-09-27 实测 TLS 握手失败），需自备代理。

```bash
# 安装 CLI（官方脚本，本机 2026-09-27 实测 404，以下载 release 包方式为准：
#   https://github.com/shorebirdtech/shorebird/releases 下载对应平台包解压到 ~/.shorebird/bin）
shorebird doctor
shorebird login                        # 浏览器授权
shorebird init                         # 在本仓库执行，生成 shorebird.yaml
shorebird release --flavor main -t lib/main.dart   # 用 shorebird 构建 release（替代 flutter build apk --release）
shorebird patch --flavor main -t lib/main.dart     # 改完 Dart 后推补丁，设备端自动生效
```

接入后日常迭代分工：**改 Dart → shorebird patch**；改插件/权限/原生 → 走上面整包自更新流程。

## 安全提示

- 清单与 APK 建议放同一可控源；`sha256` 校验已内置，**不要**留空发布
- 更新源可随时在 app 内修改；发现源被污染立即换源并重置
