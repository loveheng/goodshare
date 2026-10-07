---
memo: todos
format: v3
---

# 待办列表

<!-- 格式约定 v3 · SSOT = 全局 skill memo-collector（~/.agents/skills/memo-collector/SKILL.md §0）
- 每条：`- [ ] [YYYY-MM-DD] (类型)[(状态)?](层:Ln)?(重:轻/中/重)? 标题 (src: ...)`
- 状态枚举：降级 / 暂缓 / 候（机器可解析，勿用 emoji）
- 层 L0 引擎 · L1 平台 · L2 数据 · L3 加工 · L4 UI；重 轻/中/重
- 版本绑定项(V3/V4)可省日期，保留 [ ]
- 长期行为：每会话结束按 @todo-groom 仪式归并去重；每周一自动化巡检防回潮
-->

## misc

- [ ] [2026-10-05] (功能)(层:L1)(重:重) 独立 MCP 日程 app「拾光/shiguang」（**已立项**，仓库 ~/app/shiguang，设计冻结稿 e72b737）：大脑在桌面 AI 客户端（零端侧 LLM，复刻 goodshare Human-AI 对称架构）；三表模型（plans 带 spec/open_items/importance、fixed_slots 带星期集合、blocks 带 source/pinned/label）、九工具面、三层行为层（instructions/prompts/skill）、确定性 Housekeeper 管家；SSOT=~/app/shiguang/docs/design/schedule-app.md（**已冻结**，十轮评审 392ea83：九工具面不变、模型仅 plans+5 字段 blocks+3 标志位）；下一步=flutter create + dev-init 起骨架、MCP 框架层搬运 (src: 用户发起，十轮评审后冻结)
- [ ] [2026-10-02] (测试)(层:L0)(重:中) 端侧 LLM 4B 档真机实测（定 R1/R3 实现深度）：Qwen3-4B/3B int4 GPU 包在 8 Gen 3（OnePlus 13R）跑分（decode tk/s、内存峰值、发热）+ OCR 修正小样评估（命中率/误改率，含数字保护校验）；设备基线=8 Gen 3/天玑 9400 + 12GB（on-device-llm.md §3.1a） (src: ai, 4B/NPU 讨论链拍板)
- [ ] (功能)(层:L3)(重:重) app 内 agent/自动化引擎（**已划 V4**，2026-10-02 拍板）：app 兼作 MCP host（第四 `CommandActor.agent` 槽位）+ 对外连其他本地 MCP 服务（日历等）；起步=固定工作流引擎（确定性管道+局部 LLM 判断点，离线可靠），通用 LLM agent 后置（端侧 1.5B 多步调用可靠性不足/云 API 破坏离线承诺）；价值=住进手机生命周期（充电/后台/定时，复用 AiQueueService 基建），补桌面 host 不在线空档。硬纪律：独立成层、业务层零耦合，其他 app 只出现在工作流配置数据里。前置：V2 素材加工（event.v1 等）+ V3 分域授权。SSOT：PRD §9 V4 行
- [ ] (功能)(层:L1)(重:重) MCP 客户端分域授权（**已划 V3**，2026-10-02 拍板「V2 先把加工链路走通」）：客户端注册表（按客户端发 token）+ 三维权限域——工具域（tools/list 按 scope 过滤）、数据域（类型/工作区白名单，沿用 Vault 排除）、内容形态（raw/processed 二档，processed 与 V2 打码层协同）；默认新客户端=只读+processed+Vault 排除，预设 2-3 档避免细粒度矩阵；设置页「接入客户端」管理区（生成/吊销/选档）。方案评估见 2026-10-02 会话，SSOT：PRD §9 V3 行
- [ ] (功能)(层:L1)(重:重) iOS 端适配：需 macOS 构建；验证 receive_sharing_intent iOS 行为与前台服务限制（预期「app 前台时 MCP 可用」）
- [ ] (功能)(层:L1)(重:重) 鸿蒙 OHOS 适配：flutter_flutter fork + receive_sharing_intent/flutter_foreground_task 插件 ohos 化
- [ ] (功能)(层:L1)(重:中) ACTION_PROCESS_TEXT：任意 app 选中文本一键收集（需自定义平台通道）
- [ ] (功能)(层:L4)(重:中) 标签管理（编辑/筛选）；数据量大后评估 FTS 全文索引替换 LIKE
- [ ] (风险)(层:L1)(重:中) 国产 ROM 省电策略可能杀前台服务：真机验证华为/小米等存活情况，必要时引导加白名单
- [ ] (功能)(层:L4)(重:轻) 启动页 splash 自定义（自「图标与启动页」拆出，待办）
- [ ] (文档)(层:L1)(重:轻) release 签名配置文档化（keytool + signingConfig）
- [ ] (功能)(层:L1)(重:中) Shorebird 接入收尾：本机被两件事挡住——官方安装脚本 404（改用 GitHub release 包手动装）+ api.shorebird.dev TLS 握手失败（需代理）；用户侧网络可用时按 docs/guide/self-update.md §2 走 shorebird init/login/release
- [ ] (风险)(层:L1)(重:轻) 自更新 release 包当前用 debug 签名（模板默认），正式分发前配置 release keystore 并在 shorebird 流程中统一
- [ ] (优化)(层:L4)(重:轻) 更新页增加「强制最低版本」逻辑（清单 minVersionCode，低于即全屏提示必须升级）
- [ ] (优化)(暂缓)(层:L0)(重:轻) ASR 模型源迁移 R2 + 换新版（低优先/暂缓）：模型改为 csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09（model.int8.onnx 237,115,547 / tokens.txt 315,894）+ csukuangfj/sherpa-onnx-paraformer-zh-int8-2025-10-07（238,429,929 / 75,756，川渝方言版）；分发方式改为 Cloudflare R2 自托管 tar.gz 包（域名 https://r2.oklhj.eu.org，包的完整 URL 待用户提供），lib/ai/asr_model.dart 改「单包 + entries」结构、lib/ai/model_manager.dart 改下载→解压→逐文件校验→删包（需加 archive 依赖）。未决：是否保留 whisper-small 多语种档、方言版是否契合场景（否则换 paraformer-zh-2024-03-09，227,330,205 / 75,354）。现状可用（hf-mirror 三档已能下载），无需紧急处理
- [ ] [2026-10-03] (环境)(层:L0)(重:轻) @todo-groom 洗盘：待办 35 条 > 30 阈值（context-lint GROOM 告警），归并去重、清理陈条 (src: ai, media-native ::done 审计)
- [ ] [2026-10-03] (环境)(层:L0)(重:轻) goodshare epic memory.md 157 行 > 150 软上限（context-lint SIZE 告警）：考虑 ::done 收尾或拆分新 epic (src: ai, media-native ::done 审计)
- [ ] [2026-10-03] (文档)(层:L0)(重:轻) 收敛复盘提议待确认：lessons「Scaffold body 内避让/高度手算」三连坑多次复现且表述稳定，拟固化进 goodshare-ui skill，确认后原条目降级 Ref (src: ai, media-native ::done 收敛复盘)
- [ ] [2026-10-03] (功能)(候)(层:L3)(重:轻) 录音弹框语言选择：参考稿的「中文 ▼」暂未做——转写语言现状=ASR 模型档位 SSOT（asr.dart language:'auto'），「语言随条目走」管线未建，不做假下拉；待 item 级语言标注→transcribe 任务透传落地后补 (src: 用户参考稿, ai 权衡)
- [ ] [2026-10-03] (环境)(层:L0)(重:轻) 编辑器统一死代码清偿：lib/doc/edit_session.dart（块模型/EditOp 家族，edit_session_test 约 40 钉子）与 lib/ui/format_toolbar.dart 已标 DEPRECATED 无 UI 消费，下一轮连同其单测删除；SSOT：docs/design/note-editor-unification.md §2 (src: 用户拍板「暂留标废弃」)
