---
dev-loop: devlog
format: v1
epic: misc
total-merged: 1
last-merge: 2026-10-09
---

（散修/小改动按行追加；≥5 条自动归并进 memory.md）

<!-- 2026-10-09 归并：32 条已提炼进 memory.md（含 SSOT 修正 1 条已即时生效），此处归零重开 -->
- [2026-10-15] 详情页视觉/HCI 对账蓝本落盘（docs/design/detail-page-visual-audit.md，draft）：读态结构盘点 + 优点保持 + P0 三连（分区语言双轨：译文附录裸标题 vs 骑框签卡；AI 任务状态条离触发点远；TLDR 卡 vs 摘要卡语义重叠）+ P1 三条（空态与来源行同色、机器态切换断层、灵感卡恒占位）+ P2 两条（底栏 331dp 密度真机核对、口号页脚 24px 魔法数）。顺带修 docs/README ui-spec 条目「5 底 tab」过期描述（实际 3 tab）。docs-lint OK；未拍板未开工。
- [2026-10-15] 详情页对账蓝本 v2 修订（用户评审）：① 三条次生问题全部属实并修正——译文卡卡片化建议撤回（译文=全量正文镜像，现行无卡附录口径正确，v1 建议错）；状态条移位不充分→改卡内微观态+AppBar 2dp 线性进度；灵感卡行内折叠有键盘陷阱→改 BottomSheet 输入。② 三盲点核实：底栏「Wrap」前提有误（代码实为 Row+5 Expanded 于 :1597，:1528「Wrap 而非 Row」是 _actionBar 注释孤儿残片=注释漂移，真问题 5 格横溢 1.4px），结论保留（单行 3 胶囊+⋯ 溢出）；机器态降级二级页/抽屉成立（v1 chip 建议驳回）；媒体倒置部分成立——图片已 media-first（指控不成立），audio/video 转写文压播放器之上成立（:324-328/:358-362，与图片口径矛盾）。③ 拍板表（§6）落 7 条决策，含 P0-3 收敛数据源（human_tldr 核实：本机无写入方，仅 MCP update_item(tldr) 可写）。蓝本保持 draft（已拍板未实施）。
- [2026-10-15] 详情页底栏单行化落地（audit 蓝本 §7 第 1 项，盲点 A）：常驻裁 3 项（编辑/分享/⋯）——331dp 逻辑屏 5 格≈63dp/格<74dp 内容宽横溢（集成测试 1.4px RenderFlex 溢出即此），3 格≈105dp/格单行无隐患；删除/工作区经 ItemActions.overflowSheet 移入 ⋯ 面板（删除首位红字→工作区→重新处理→权限开关组，扩 onDelete/onOpenWorkspace 两回调）；`:1528`「Wrap 而非 Row」注释孤儿残片清理（原粘错 _buildTitle 注释）。SSOT 同步：ui-spec §4.3 三处（公共区描述/⋯第 3 项/基本操作表行，收敛历史「2 项 vs 5 项」矛盾层）+ detail-two-zone.md §3 表行 + audit 蓝本 §7 标已落地 + integration_test 溢出过滤注释更新。验证：analyze 0 + 全量 816 过 + docs-lint OK。真机验收项：底栏无溢出、⋯ 面板 7 项可达性。
- [2026-10-15] 详情页 TLDR/摘要收敛落地（audit 蓝本 §7 第 2 项，P0-3 拍板）：bodySlivers 撤 TLDR 导语卡（item_view_template.dart，SectionLegendCard import 清理，类/方法注释记录收敛口径）；摘要卡回退链 = summary_md → 摄入期 human_tldr → 空态引导（卡名统一「摘要」，深度摘要生成后自动覆盖粗导语）；ui-spec §4.3 文档形态 ② 标撤。核实补丁：human_tldr 本机无写入方（仅 MCP update_item(tldr)），折叠成本极低。验证：analyze 0 + 全量 816 过 + docs-lint OK。列表预览 preview 的 tldr 优先级不受影响（preview_plain_test 照过）。
- [2026-10-15] 详情页卡内微观态 + 顶栏微进度落地（audit 蓝本 §7 第 3 项，P0-2 拍板）：①`_activeActions` 本条目 active 任务动作集（listTasks 过滤 item_id+pending/processing，_reload/initState 两口刷新——任务态变化经条目写回广播间接受益）；②摘要/标签/模板卡 refresh 位进行中替换 18px spinner（sectionActions 加 running 参数，模板卡图标位同构）；③Stack 顶层钉 2dp LinearProgressIndicator（有 active 任务即现，不随 SliverAppBar 隐显，长文任意滚动位置恒可见）；④全局状态条收敛为仅终态（失败/暂停/取消/完成无产出 note 保留=R1，进行中行不渲染；纯函数 aiTaskStatusText 契约不变、widget 层收敛，audio_extract_test 锚定文案不动）。验证：analyze 0 + 全量 816 过。真机验收：spinner 出现/消失时机（入队→_run→_reload 即现；宿主 apply 回写→notify 即消）、顶栏线不遮挡标题。
- [2026-10-15] 详情页对账蓝本 §7 第 4-7 项全部落地：④audio/video 播放器前置（_audioView/_videoView Column 子序调换——核实 ui-spec 工具矩阵「播放器→转写文本」本有此规，代码漂移本次对齐；图片条目本已 media-first 不动）；⑤机器态降级二级页（新建 lib/ui/machine_view_page.dart；ItemViewTemplate 撤 machineMode 参数与 _machineView；ItemActions.machineMode 改导航入口撤勾选态；ItemActionContext.machineMode 字段移除——唯一构造点 item_detail_page 同步；⋯ 面板动作改名「机器态」；ui-spec 3 处陈述更新）；⑥灵感卡 BottomSheet 化（Sliver 内 TextField 撤除，_inspirationCtrl/_saveInspiration 失焦即存/dispose 兜底全退场；卡改展示态=文本+编辑图标/空态轻入口；新增 _InspirationSheet 键盘跟随浮层，显式保存/取消、未改动跳过写入）；⑦译文轻分隔（_appendix 加 outlineVariant Divider + Insets.xxl）。验证：analyze 0 + 全量 816 过 + docs-lint OK。真机验收：音/视频条目播放器首屏可见、灵感 BottomSheet 键盘不跳屏、机器态二级页、译文分隔线。
