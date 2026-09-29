---
status: active
updated: 2026-09-29
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

### Cloudflare R2（推荐：国内外均稳、免流量费、可控）

适合作为常驻更新源。前置：Cloudflare 后台对该 bucket 开启「公开访问」并绑定自定义域（如 `update.example.com`），确保 `https://<域>/updates/...` 可公开 GET。

1. 准备仓库根 `.env`（参考 `.env.example`）：填 `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_BUCKET` / `R2_PUBLIC_DOMAIN`。无需额外 CLI（上传由 `scripts/upload-r2.mjs` 用 Node 内置模块完成；脚本读取优先级：根 `.env` > `scripts/.env`）。
2. 仓库根执行：`bash scripts/release-r2.sh`（可选 `--commit` 把清单纳入版本管理）。
   脚本自动：读取 `pubspec.yaml` 版本 → `flutter build apk --release`（整包，跨 ABI 兜底）→ 算 sha256 → 生成 `updates/goodshare-update.json` → 用 `aws s3 cp`（R2 endpoint）上传 apk + json。
3. 脚本末尾打印「更新源 URL」，形如 `https://update.example.com/updates`，填进 App「更新」页。
   - `release-r2.sh` 已在 `flutter build` 时通过 `--dart-define=UPDATE_SOURCE_URL=...` 把该源编进 APK，因此**装上即自带默认更新源，首次无需手动填**；App「更新」页仍可手动改源覆盖。

> `r2.dev` 默认公开域有限速，不建议作生产更新源；生产请绑定自定义域（自定义域免 egress 流量费）。`R2_PUBLIC_DOMAIN` 与 `REMOTE_PREFIX` 共同决定最终 URL 与 App 端源地址，务必一致。

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
    "flags": {},
    "slogans": {
      "splash": "收下微小的喜欢，等待被需要的瞬间。",
      "empty": "把零碎的喜欢收进口袋，在需要的时候开成花。",
      "about": "时间会模糊记忆，但你的喜好，一直在这里安放。",
      "detailFooter": "未必次次有用，但每次想起，它都在这里等回应。"
    }
  }
}
```

- `versionCode` 与 `pubspec.yaml` 的 `+N` 比较，**大于**才提示更新
- `sha256` 生成：`sha256sum app-release.apk`
- `config.mcpInstructions` 非空时会覆盖 MCP `initialize` 返回的服务说明（下次客户端连接生效）
- 公告随「检查更新」刷新并缓存，更新页展示

### config.slogans（文青风口号热更）

`config.slogans` 是可选 map，按落点 key（`splash` / `empty` / `about` /
`detailFooter`）覆盖 App 内四处文青风口号的文案（`lib/ui/slogans.dart` 消费）。

- `splash`：首页「全部」**空态欢迎语**（原拟作启动闪屏，已改为融入主界面空态，无独立遮罩页）
- `empty`：各**类型页空态引导**
- `about`：设置「关于」区顶部
- `detailFooter`：详情页滚动底部
- **可部分覆盖**：只下发改动的 key，未覆盖的 key 仍用 App 内置的本地默认值。
- **缺失该段或某 key 为空**：回退本地默认口号，不会空白。
- 与公告同理，随「检查更新」刷新并缓存（`RemoteConfigStore` 持久化）。

### flags.llmManifestUrl（端侧大模型目录热更）

`config.flags` 加一键即可把 LLM 模型目录云端化（`lib/ai/llm_model_manager.dart` 消费）：

```json
"flags": {
  "llmManifestUrl": "https://<host>/llm-manifest.json"
}
```

manifest 格式（仓库内默认样例见 `updates/llm-manifest.json`）：

```json
{
  "models": [
    {
      "id": "qwen25-1.5b-q8",
      "name": "通用 · Qwen2.5-1.5B",
      "desc": "展示描述",
      "file": "xxx.litertlm",
      "size": 1597931520,
      "repo": "owner/repo",
      "url": "https://...（绝对地址，与 repo 二选一，优先于 repo）",
      "socModel": "SM8750（可选：仅该机型可见/可选更新）"
    }
  ]
}
```

- `id/name/file/size` 必填；`repo`（HF 仓库拼接 `{base}/resolve/main/{file}`，默认 hf-mirror）与 `url`（绝对地址，R2 自托管 / gated 中转用）**至少一个**
- `socModel` 填了则仅该机型可见（`ro.soc.model` 精确匹配）；不填为通用包
- 坏条目自动跳过；**空目录视为无效 manifest，绝不覆盖本地可用目录**；拉取失败静默保留 last-good（`documents/llm_manifest.json`），离线/首次安装回退内置兜底目录
- **本地可用性只由文件本身决定**（云端目录是建议不是许可）：旧文件永不禁用，同 id 换文件仅提示「云端有新版本可更新」，manifest 移除的条目以「本机保留」叠加展示照常可用

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
