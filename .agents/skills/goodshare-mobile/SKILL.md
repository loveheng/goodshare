---
name: goodshare-mobile
description: 拾贝 goodshare（Flutter 分享收集器+MCP）移动端健壮性底层规则：AppLifecycleManager 生命周期枢纽、状态恢复与后台保活（AiQueueService/前台服务单实例/设备状态门控/内存压力中断）、富媒体内存水位（imageCache 限额/cacheWidth 陷阱/长列表）、Vault 物理防线（遮罩+FLAG_SECURE+加密落盘）、离线优先队列与僵尸回收、动态排版与无障碍。改生命周期/退后台行为/图片渲染/保活/Vault/离线队列前先读；写路径与分层见 goodshare-arch。
---

# goodshare 移动端健壮性规范

移动端内存吝啬、进程随时被杀、富媒体易 OOM、弱网普遍。以下五条是 App 健壮性**底线**，共同的架构枢纽是 `AppLifecycleManager`。写路径 / 分层口径见 `goodshare-arch`，UI 渲染口径见 `goodshare-ui`。

## 用法

1. 动生命周期、退后台行为、图片渲染、保活、Vault、离线队列前先读本文件对应节。
2. 收尾跑 `toolbox run arch-guard`（口径见 `goodshare-arch`），它机械拦「另起 `WidgetsBindingObserver`」「裸 `Image.file`」等违规。

## 架构枢纽：AppLifecycleManager

- **禁止在 `main` / 顶层 `StatefulWidget` 直接堆 `WidgetsBindingObserver` 回调**：统一用 `lib/app/lifecycle_manager.dart` 的 `AppLifecycleManager`（单例 + `WidgetsBindingObserver` mixin + 广播 `Stream<AppLifecycleState>`）。
- 暴露 `onResumed` / `onBackgrounded` / `onMemoryPressure` 便捷流；各模块（队列回收、安全中心、草稿管理、AI 后台调度）自行 `where` 订阅关心的状态，逻辑解耦。
- 新增「退后台行为」一律订阅 `onBackgrounded`，**不得另写 observer**；系统内存紧张（Android `onTrimMemory` 由 Flutter `didHaveMemoryPressure` 暴露）订阅 `onMemoryPressure`。
- 涉及平台的观察逻辑（Vault blur / `FLAG_SECURE`）走多平台接口，不在此散写 `Platform` 分支。

## 一、状态恢复与后台保活

- 草稿 / 大段输入**禁止只存内存 `State`**：进程被杀即丢。须防抖写本地草稿表（`lib/models/draft_store.dart` + `lib/ui/draft_controller.dart`，800ms 防抖落盘），退后台经 `onBackgrounded` 强制 `flush()` 绕过防抖；重开面板自动恢复半成品（`quick_note_sheet` / `item_detail_page` 已接）。`RestorationMixin` 依赖 Android restoration service，对底部 Sheet 作用域未必传递，DB 草稿更稳。
- AI 管线是**端侧**模型，断点续传 = 冷启动排空 + resumed 排空；`workmanager` 真后台仅当需要「用户永不打开也跑」时再上（**[V3] 评估**，注意系统模型多不允许后台调用）。
- **退后台继续 AI 处理（已落地）**：由 `lib/ai/ai_queue_service.dart` 的 `AiQueueService` 统一收口——消费者启动 / 僵尸回收 / resumed 排空全部搬进来，**禁止在 `main` 内联堆消费**。退后台且 `pendingCount>0` 且设备状态允许时拉起前台服务保活主 isolate；回前台且 MCP 未运行时停服。设置页「退后台继续 AI 处理」开关（默认开）+ 通知栏显示剩余条数。
- **前台服务单实例约束（硬规则）**：`flutter_foreground_task` 只支持**一个**前台服务，MCP 与 AI 队列必须共用——两边都只能 `startService`，`init` 由 `lib/service/foreground_task_init.dart` 的 `ensureForegroundTaskInit()` 幂等统一执行，**禁止各处各自 `init` 互相覆盖**。判定是否已被 MCP 持服用 `mcp.running`，`stopService` 前必查，否则会把 MCP 服务打掉。
- **设备状态感知调度**：推理受 `canProcess` 门控（`QueueConsumer.canProcess`，注入自 `AiQueueService.inferenceAllowed`）——充电 / 满电 / 电量 ≥40% 且非内存压力才认领任务，否则**停留 `pending` 等待时机**（不是 failed，不入死信）；电量跌破阈值时退后台会主动停服省电。`battery_plus` 取值失败须 try/catch 并回落到「允许」（桌面 / 模拟器取不到电量）。
- **内存压力优雅中断（硬规则）**：`onMemoryPressure` 触发时暂停认领新任务 + 当前 `processing` 任务回滚 `pending` 待续跑，**不得抛未捕获异常**；60s 后或下次 resumed 自动恢复。

## 二、富媒体内存水位

- **imageCache 必须限额**：`PaintingBinding.instance.imageCache.maximumSizeBytes` + `maximumSize`；`lib/main.dart` 已设 `100MB / 500`（默认 `1000` 张 / `100MB` 过高，长列表必爆）。
- **cacheWidth 陷阱（硬规则）**：同一张图在列表缩略图用 `cacheWidth`、详情大图不用，Flutter 当**两个缓存对象**重复解码、内存翻倍。统一走 `lib/ui/goodshare_image.dart` 的 `GoodshareImage`，调用方显式声明解码尺寸；`ContentCard` 缩略图已 `cacheWidth:96`。**新增图片渲染一律用 `GoodshareImage`，禁止裸 `Image.file` / `Image.network`**。
- **长列表严禁 `ListView` / `SingleChildScrollView` 渲染海量**：必须用 `ListView.builder` / `Sliver` 族（inbox / vault / timeline / recent_deleted 已合规）。
- 超长 `human_md` 渲染（flutter_markdown）每次 build 重解析有重绘代价，极长文本关注抽子组件 / 缓存解析结果。

## 三、Vault 物理级防线（遮罩 + FLAG_SECURE 已落地，加密落盘 V3）

- 当前仅 `is_vault=0` 过滤 + `local_auth` 视图隐藏（应用层），**非物理加密**，真机 root / 文件管理器可读 SQLite。
- **退出即遮罩**：订阅 `onBackgrounded` 盖高斯模糊（`lib/ui/privacy_blur_overlay.dart` 挂 `MaterialApp.builder` 最外层，`ImageFilter.blur(20)` + 锁图标）+ 清理内存中 Vault 明文 / 密钥；重入重认证（见下）。
- Android 动态 `FLAG_SECURE` 防截屏（已落地：`lib/service/secure_window.dart` 平台通道 + `MainActivity.kt` addFlags/clearFlags；进入 VaultPage / vaultContext 详情 `setSecure(true)`，离开置 false，普通页保持可截图分享）。
- **加密落盘（[V3]）**：整库 `SQLCipher`（`sqflite_sqlcipher`，迁移成本高）或字段级 AES（Vault 的 `human_md` / `machine_json`）+ 密钥存 `flutter_secure_storage`（KeyStore/Keychain）；非 Vault 数据保持明文以保性能。

## 四、离线优先与队列重放

- **写操作队列化底座**：`ai_task_queue` 表（DB 持久）+ `QueueConsumer` 轮询消费；所有 AI 重构经队列，进程被杀任务不丢。
- **僵尸任务回收（硬规则）**：`claimTask` 置 `processing` 后若进程被杀会永久卡死；`ai_task_queue` 加 `updated_at` 列，处理中每 5s `touchTask` 心跳，`reclaimStaleTasks` 将 `processing` 且 `updated_at` 超 30s 重置 `pending`；冷启动 + resumed 各调一次。**新增耗时任务须维持心跳**，否则会被误杀。
- **乐观 UI / 网络门控（[V3] 待评估）**：local-first 已靠落盘 + 仓库通知（见 `goodshare-ui`「Local-first 交互拉齐」），无远端依赖时不必乐观占位；若将来加云端同步 / 远端写，须 Intent 入队 + 连通重放。

## 五、动态排版与无障碍

- **字号缩放钳制（已落地）**：`MaterialApp.builder` 用 `data.textScaler.clamp(minScaleFactor:1.0, maxScaleFactor:1.5)` 全局钳制（**勿用已弃用 `textScaleFactor`**）；`ContentCard` 用 `maxLines` + `TextOverflow.ellipsis` 已 overflow 安全。
- **固定高度容器必须自适应**：写死 `height` 的卡片 / 面板在 1.5x 下必 `RenderFlex overflowed`；容器改自适应高度，固定面板可单独锁 `textScaler`。
- **图标按钮无障碍（已落地 `floating_ball.dart`）**：纯图标表意的 FAB / `IconButton` 必须 `Semantics(label:…, button:true)` 或 `tooltip`，确保 TalkBack / VoiceOver 可读；新增图标按钮一律补。

## Vault 安全生命周期

- **监听 App 生命周期**（`AppLifecycleManager.instance.onBackgrounded`，勿另写 observer）：`paused` / `inactive`（退后台 / 锁屏）时，**立即清理内存中驻留的 Vault 解密数据**（明文 / 密钥 / 解密态），不得留存。
- **UI 强制收口**：上述状态触发时盖模糊蒙版或路由弹回保险箱外，重入须重新 `local_auth` 认证。
- **MCP 边界**：MCP 前台服务与 UI 生命周期解耦（退后台仍可能持续服务）；Vault 对 MCP 须有**独立重认证闸门**，不能因 UI 已解锁就长期免认证暴露给桌面客户端。

## 自查清单（移动端健壮性自查）

1. 退后台 / 回到前台逻辑是不是直接写了 `WidgetsBindingObserver`？→ 改订阅 `AppLifecycleManager`。
2. 新增图片渲染是不是裸 `Image.file` / `Image.network`？→ 改 `GoodshareImage` 并显式 `cacheWidth`。
3. 长列表是不是 `ListView` / `SingleChildScrollView` 一把梭？→ 改 `ListView.builder` / `Sliver`。
4. 耗时后台任务有没有维持心跳？→ 借 `QueueConsumer` 心跳模式，否则会被僵尸回收误杀。
5. 图标按钮有没有 `Semantics` / `tooltip`？→ 补。
6. 固定高度容器在 1.5x 下会不会 overflow？→ 改自适应或锁 `textScaler`。
7. 大段输入是不是只存 `State`？→ 接 `DraftStore` 防抖落盘 + 退后台 flush。
8. 前台服务是不是各自 `init`？→ 统一 `ensureForegroundTaskInit()`，`stopService` 前查 `mcp.running`。
