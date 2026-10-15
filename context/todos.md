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

- [ ] [2026-10-15] (清理)(层:L1)(重:轻) LLM 迁出遗留物清理：仓库样例 `updates/llm-manifest.json` 已无代码消费（self-update.md 该节已标退役）；用户设备上已下载的 ~1.5GB 模型文件成孤儿（不强制清理，M2 已知残留）——自更新「清理缓存」入口或下次发版时一并处理 (src: ai, 2026-10-15 文档漂移对账)

- [ ] [2026-10-05] (功能)(层:L1)(重:重) 独立 MCP 日程 app「拾光/shiguang」（**已立项**，仓库 ~/app/shiguang，设计冻结稿 e72b737）：大脑在桌面 AI 客户端（零端侧 LLM，复刻 goodshare Human-AI 对称架构）；三表模型（plans 带 spec/open_items/importance、fixed_slots 带星期集合、blocks 带 source/pinned/label）、九工具面、三层行为层（instructions/prompts/skill）、确定性 Housekeeper 管家；SSOT=~/app/shiguang/docs/design/schedule-app.md（**已冻结**，十轮评审 392ea83：九工具面不变、模型仅 plans+5 字段 blocks+3 标志位）；下一步=flutter create + dev-init 起骨架、MCP 框架层搬运 (src: 用户发起，十轮评审后冻结)
- [ ] [2026-10-02] (测试)(层:L0)(重:中) ~~端侧 LLM 4B 档真机实测~~**迁出至宿主仓**（2026-10-15）：goodshare 已不持有端侧 LLM（ai-app-split M2），4B/NPU 选型归 goodhub 账本（宿主 BYOK 云端已通、端侧模型档选型待宿主侧排期）；本仓不再跟进 (src: ai, 4B/NPU 讨论链拍板 → 2026-10-15 归属更正)
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
- [ ] [2026-10-03] (环境)(层:L0)(重:轻) goodshare epic memory.md 198 行 > 150 软上限（context-lint SIZE 告警，2026-10-09 归并后仍超）：V2 开工时新 epic 承接，本 epic 届时归档 (src: ai, 2026-10-09 ::done 审计)
- [ ] [2026-10-03] (文档)(层:L0)(重:轻) 收敛复盘提议待确认：lessons「Scaffold body 内避让/高度手算」三连坑多次复现且表述稳定，拟固化进 goodshare-ui skill，确认后原条目降级 Ref (src: ai, media-native ::done 收敛复盘)
- [ ] [2026-10-03] (功能)(候)(层:L3)(重:轻) 录音弹框语言选择：参考稿的「中文 ▼」暂未做——转写语言现状=ASR 模型档位 SSOT（asr.dart language:'auto'），「语言随条目走」管线未建，不做假下拉；待 item 级语言标注→transcribe 任务透传落地后补 (src: 用户参考稿, ai 权衡)
- [ ] [2026-10-08] (功能)(候)(层:L4)(重:轻) 行内加粗 B 档是否进浮层：受 pending-confirm D5 约束（格式模型＝先选后打，不做给已有文字套格式/选区交互），只能做成「先选后打」开关瓦片而非选区菜单；待用户拍板 (src: 2026-10-08 格式档位评估)
- [ ] [2026-10-08] (功能)(候)(层:L4)(重:轻) lib/ui/rotary_dial.dart（可旋转圆盘，stepped/continuous 双模式）从未接入消费方，有独立单测——与已恢复的 format_dial / smart_floating_hub 同为「零业务语义待复用件」；长期无宿主则再评估清偿 (src: 2026-10-08 死代码清偿)
- [ ] [2026-10-08] (功能)(候)(层:L4)(重:轻) lib/ui/format_dial.dart（三级径向盘）保留但**当前无消费方**：零业务语义可复用件（DialSpec 三节注入），单测 30 条守护；若长期找不到宿主会退化成新死代码——复用或再次清偿二选一。同源的 smart_floating_hub.dart **仍在**（原记「已删」有误——并行会话成果经 9801461 合入带回，同样零消费方） (src: 2026-10-08 死代码清偿；2026-10-13 groom 纠正)
- [ ] [2026-10-08] (优化)(候)(层:L4)(重:中) 标题标记透明隐藏后的 H2 辨识度：H2=titleMedium w600 与正文 bodyLarge(16sp) 仅差字重，标记隐去后非焦点行几乎看不出是标题；待真机确认，必要时拉开 H2（字重 700 / 换字号档 / 主色） (src: 2026-10-08 标题标记显隐拍板)
- [ ] [2026-10-09] (功能)(暂缓)(层:L2)(重:中) mermaid 在线渲染的**隐私口径待收紧**（随渲染件停用而暂缓，重新启用时生效）：当前把 mermaid 块源码明文发给第三方 mermaid.ink 且不区分条目（用户拍板「先试效果」）。上线前须补：保险箱/上锁条目禁发（直接退代码块）+ 设置项开关 + 端点可换自建 kroki (src: 2026-10-09 在线方案拍板)；可用性兜底同批：服务不可用/限流时全量退代码块，需评估自建 kroki（超时与重试策略），避免「图全变码」
- [ ] [2026-10-09] (功能)(候)(层:L4)(重:轻) mermaid 在线载荷真机确认：pako（zlib+base64）若为 400 会自动退回明文 base64 重试一次——真机需确认哪种载荷实际生效，锁定后删掉另一条 (src: 2026-10-09 在线方案拍板)
- [ ] [2026-10-09] (功能)(候)(层:L4)(重:轻) `lib/ui/mermaid_view.dart`（mermaid 在线渲染件）**已摘出渲染路径、零消费方**：用户拍板「加载好慢」改回代码块显示，组件保留待复用（在线方案完整）；与 rotary_dial / format_dial 同为「零业务语义待复用件」，长期无宿主则清偿 (src: 2026-10-09 mermaid 还原拍板)
- [ ] (功能)(暂缓)(层:L1)(重:轻) 图文同分享文案修复（2026-10-09 移出 V2 二次收敛）：receive_sharing_intent 的 toJsonObject 只取 uri 丢文案（小红书/微博类图文帖）；需 fork 插件或自写 intent 解析——Android 原生层插件 fork 维护成本极高，延后待真实使用反馈再评估；goodshare epic 同名重复条目已于 2026-10-13 groom 销项，以本条为准 (src: v2-requirements §1.3 配套③ 移出拍板)
