---
dev-loop: memory
format: v1
epic: goodshare
total-merged: 4
last-merge: 2026-09-27
---

# goodshare · Android 分享收集器 + 内嵌 MCP 服务

## 目标
- 手机使用过程中，通过系统分享菜单把「好东西」（文本 / 链接 / 图片 / 视频 / 文件）一键收集进 app
- app 内可作为 MCP 服务（Streamable HTTP）运行，供桌面 AI 客户端（Claude Desktop / ZCode 等）检索与读取收集内容
- 链路：采集（分享菜单）→ 存储（sqflite）→ 浏览检索（Flutter UI）→ MCP 对外（tools）

## 技术决策（已定）
- [2026-09-27] 技术栈：Flutter (Dart) 一套代码——Android 首发，iOS 官方支持，鸿蒙走华为社区 OHOS 适配（Gitee flutter_flutter）；包名 com.zzh.goodshare，应用名「拾贝」（working title，可改）。动因：用户明确「以后移植 iOS + 鸿蒙」，三端选型经用户确认（2026-09-27）
- [2026-09-27] 存储：sqflite 单表 items + path_provider；图片/视频/文件复制进 app 私有目录（documents/shares/），不依赖源 app 的 content URI（防撤销/失效）
- [2026-09-27] MCP 传输：dart:io HttpServer 内嵌监听 0.0.0.0:8765，手写 Streamable HTTP + JSON-RPC 2.0（initialize / tools/list / tools/call / ping）；支持协议版本 2025-06-18 与 2025-03-26；GET/DELETE /mcp 返回 405（v1 无服务端主动推送）
- [2026-09-27] MCP 工具集 v1：`list_items`（分页/类型过滤/关键词）、`get_item`（全文；图片返回 base64 image 内容块，超大文件只给路径）、`add_item`（AI 侧写入文本/链接）
- [2026-09-27] 关键插件：receive_sharing_intent（分享接收）、flutter_foreground_task（前台保活，若接入受阻两轮即降级为「app 存活期可用」并记待办）、shared_preferences（设置/token）、share_plus（再分享）
- [2026-09-27] 服务防护：简单 token（X-Api-Key 头，默认开启、安装时随机生成）用于 LAN 暴露场景
- [2026-09-27] 桌面接入双通道：USB 用 `adb reverse tcp:8765 tcp:8765`；Wi-Fi 用手机局域网 IP 直连；仓库自带 Node stdio↔HTTP 桥（`mcp-bridge/stdio-bridge.mjs`）供 stdio 型 MCP 客户端使用
- [2026-09-27] 弃用项：Kotlin 原生（Compose/Room/Ktor）方案整体作废；ACTION_PROCESS_TEXT 采集移入后续待办（Flutter 端需插件/自定义通道）
- [2026-09-27] 文档评估修订 8 项决策（@confirm 台账全清，已落 PRD/V2/UI 规范）：①健康/日历聚合与 Vault 加密均推迟 V3，V2=离线双态 AI + 通用截图解析（健康章节移出 V2 文档）；②详情「同步到 PC」移除（无手机→PC 推送通道）；③update_item 可写 machine_json 但须过领域 Schema 强校验；④execute_action MVP 剔除（独立工具即结构化接口）；⑤delete_item 软删除（is_deleted 列 + 30 天恢复）；⑥STT 仅端侧探测（requiresOnDeviceRecognition 等）通过才启用，断网验收不豁免；⑦Markdown 渲染指 flutter_markdown 社区分叉（原包停更，实现前核 pub.dev）；⑧机械修复 9 处（PRD 表格结构/GBNF 残留/5 tab/goodshare-index 补登 design 域/self-update 补登/audio 入口/'health' 枚举顺延 V3 等）
- [2026-09-27] 二轮需求评估 8 项决策（F1–F8 台账全清；范围基准=三份文档本身，v1 旧功能未经设计、不构成冲突面，Schema 重建弃旧数据不迁移）：衍生机械批 10 处（Timeline 去步数、get_timeline_context 恒空标注、查询默认过滤 is_deleted、队列加 cancelled、task_action 补 transcribe_audio、空态/V2 标注、内联编辑走 handler、剪贴板风险入表）；reprocess_item 提前 MVP；FAB「先存后增强」（MVP 录音/相机=原始条目，record 类插件入栈）；待办勾选独立字段 todo_state_json（行 hash 关联，V2 可勾 MVP 仅渲染）；时光机与时间轴合并（MVP/V2 全部仅分类视图，V3 分化）；合并模式=同源 App+5min 窗、add_item 不参与；重分类纠正=手动 BottomSheet+update_item item_type 白名单（image→chatlog/document，须 source_type='image'）；PRD↔V2 双向补齐（截图解析入 PRD 模块二/§9，便签编辑器最小设计入 V2 §5）
- [2026-09-27] 分期调整（用户拍板）：OCR 与音频转写提前到 v1——图片走 ML Kit 端侧识别（google_mlkit_text_recognition 中文脚本，标准 GMS 设备；无 GMS 的 bundled 变体后续适配，入 V2 §8 风险表）；速记录音采集时同步端侧转写（speech_to_text onDevice 请求，不支持则 UI 明示仅存音频；Android 系统识别仅实时流故采集时同步，转写文本随 raw 层入库由消费者占位复制）；LLM 双态重构仍 V2。真机实测：OnePlus 13R（Android 16）无 AICore→系统模型档不可用但 GMS/ML Kit 可用，正好落在本次调整覆盖内。版本 1.2.0+4
- [2026-09-27] 设置页 AI 能力开关与一次性检测（用户拍板）：图片 OCR / 录音端侧转写两开关默认开；本机能力检测（google_api_availability 查 GMS + speech_to_text initialize）**首次执行后持久化、此后不再检测**（用户明确要求）；无能力置灰 + 小字提示；OCR 关闭走占位管线、转写关闭录音仅存音频。另登记：CI 分架构构建（整包兜底 + 分包精简，tag 自动 Release 附 sha256sums.txt）

## 进度
- [2026-09-27] dev-init 接入完成：git 仓库 + context/ 记忆体系 + 白名单骨架 + 项目池（首次 scaffold 因 cwd 漂移落到了 workspace 根，已整体迁回——教训：Bash 一律显式 cd）
- [2026-09-27] 环境就绪：Android SDK（platform-36/37.0 + build-tools 36，~/android-sdk）+ Flutter 3.47.5 stable（~/flutter）；工程最终落位 ~/app/goodshare（用户指定，从 ZCode 默认工作区迁入）
- [2026-09-27] v1 代码全量落地并四项验证通过：analyze 0 issue / test 6/6 / bridge e2e 5/5 / assembleDebug ✓（app-debug.apk 165MB，在 build/app/outputs/flutter-apk/）。构建踩坑：receive_sharing_intent 1.9.0 要求 compileSdk ≥37（高于 flutter 默认 36，已提为 37）；pub 下载偶发停滞（清 _temp 重跑可解）
- [2026-09-27] 真机验证（分享接收/前台服务存活/MCP 实连）未做——本机无设备

## 进度（追加）
- [2026-09-27] MVP 实现推进（三步全绿：analyze 0 issue，测试 29/29）：①数据层——Schema v2 重建（inbox_items/daily_metrics/ai_task_queue，弃旧不迁移；含 is_deleted/deleted_at/collect_mode/appendix_json/facets_json/todo_state_json）+ InboxItem 模型（canonical 枚举、uuid 自实现）+ Repository（默认过滤 Vault/已删、软删+队列取消+30 天 purge、update/listDeleted/restore/enqueueTask/pendingTasks）；测试隔离修复 Db.overridePath 内存库。②共用动作层 lib/action/——ItemActionHandler（edit/delete/reclassify/setVault/reprocess/unlockEdit；编辑锁、重分类白名单 image→chatlog/document、machine_json Schema 校验、vaultContext 双口径）。③摄入链路——TextCollector（合并/分散：同源 App+5min 滚动窗、appendix 每段记录含首段、纯 URL 不并链、MCP add_item 不参与）+ text_parse 独立 + 附件/文本/add_item 入库即入队（taskActionFor 收进 Repository）
- [2026-09-27] 更新体系落地：自更新（清单/流式下载/分块 sha256/open_filex 安装）+ 配置热更（公告/MCP instructions 注入）+ 更新页；版本 1.1.0+3；release 包 52.7MB（sha256 前缀 1c867ac9）。Shorebird 被安装脚本 404 + api.shorebird.dev 网络不通挡住，手册在 docs/guide/self-update.md
- [2026-09-27] 文档体系扩展：新增 docs/design/ui-spec.md（UI 设计规范）+ goodshare-ui skill；PRD/V2 文档按上述 8 项决策修订落盘；docs-spec lint 仅剩 3 个既有旧文档（overview/mcp-integration/self-update）frontmatter 待归一。release 优化线索：分 ABI 构建（--split-per-abi）可降至 ~18MB（待办评估）
- [2026-09-27] MVP 完成（步骤4-6 + 分期调整 + 真机反馈修复；analyze 0 / 测试 47 绿）：④AI 管线 lib/ai/（AiReconstructor 抽象+占位+Registry+QueueConsumer，OCR 失败优雅降级）；⑤MCP 工具族 PRD §7 全量 10 个接 ItemActionHandler（set_vault 仅可移入；接入指南工具表更新 + frontmatter 归一）；⑥UI 重构（5 tab + FAB 速记、ItemViewTemplate/Registry 双态详情、设置树、最近删除）；分期调整——图片 OCR（ML Kit 中文）与速记录音端侧转写提前 v1；真机反馈修复——设置 AI 能力开关（一次性检测持久化）、文本收集模式选择（late final 缓存致 setState 不下传）、最近删除彻底删除/清空；R8 修复（ML Kit 中文脚本依赖 + dontwarn，arm64 分包 31M）；GitHub Actions（整包+分架构，tag 自动 Release）

## 断点
- [断点] 下一步：真机验证 1.2.0+4（新增：设置 AI 能力开关/最近删除彻底删除/文本收集模式切换；速记录音转写与图片 OCR 实测）；release 构建与自更新闭环
