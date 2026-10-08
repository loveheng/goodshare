---
dev-loop: devlog
format: v1
epic: misc
total-merged: 0
last-merge: none
---

（散修/小改动按行追加；≥5 条自动归并进 memory.md）
- [2026-09-30] [变更]: 全局 devlog 记账脚本落地（toolbox devlog.sh：change/verify/note/lesson/bp/count 六子命令，--json 预检不落盘、幂等去重、单趟 awk 断点替换+恒1行校验、自测 11 条沙箱断言；金丝雀曾逮住日期格式缺方括号 bug 后修复）；dev-loop SKILL 实现口径与断点规则已指针化到该工具（保留 cat>>/sed 降级路径）
- [2026-09-30] [验证]: sh devlog.sh --self-test → 11/11 通过；toolbox check → exit 0 已登记；goodshare 真实冒烟 count=5/--json 预检正常
- [2026-10-03] [变更]: 速记转盘真机反馈二轮落地：①修 format_dial 角锚象限反转（右缘锚误向右上扇出，命中/迟滞/painter/文字定位四处同源修正）+ 行内置灰真值错读常量表改接 widget.inlineDisabled；②圆钮可拖动换缘（touch slop 分流+过中线实时翻转+AnimatedPositioned 吸附+SharedPreferences 持久化 quick_note_dial_dock_left）；③展开期全屏命中层「点空白自动闭合」拍板落地（替代显式 toggle，_collapse 连带收转盘）；④format_dial_test 迁移角锚四分之一圆几何，新增双环同显/左缘镜像/置灰/点空白收合/拖动换缘用例；设计稿 §1/§2.1/§2.6/§5 回写转 active
- [2026-10-03] [验证]: flutter analyze → 0 issue；format_dial_test + quick_note_bar_test → 24 绿；全量 flutter test → 455 绿（441+14）；docs-lint OK
- [2026-10-03] [变更]: 三项 UI 拍板落地：①新建统一录音弹框 audio_record_sheet（计时/振幅驱动波形/暂停继续/停止回传/5min 自动停/×丢弃即删半成品），速记条录音与详情页编辑点音频块（重录替换，MediaAudioBar 增 onTap 覆盖位）两处统一接入；②去待办：速记条动作行「待办」按钮移除（_todoMode 状态机保留供存量待办草稿序列化）+ 详情页编辑态待办勾选块移除（CommitTextOp.todoDone 管线保留供 MCP/机器态）；③搜索页类型 chips 整行移除，回归纯关键词（类型浏览由首页 tab 承担）
- [2026-10-03] [验证]: flutter analyze → 0 issue；全量 flutter test → 455 绿；dart format 已过
- [2026-10-03] [变更]: 编辑器统一落地（docs/design/note-editor-unification.md）：①抽共享 NoteComposerEditor（lib/ui/note_composer_editor.dart，段序列/媒体卡/动作行/录音弹框/可拖动转盘/点空白收合，onDirty/onChanged/onMediaReplace/audioController 解耦面），QuickNoteBar 减为面板外壳；②新增 noteMdToDraftRows（human_md→草稿行，local:// 媒体行识别+转义往返，旧结构字面保留）+ 草稿行扩展第 3 位 alt/label；③详情编辑切换作曲器（SliverFillRemaining+UpdateItemCommand(humanMd) 链路不变），长按换媒体/点音频重录经钩子保留，FormatToolbar 摘除、EditSession/format_toolbar 标 DEPRECATED 暂留
- [2026-10-03] [验证]: flutter analyze → 0 issue；全量 flutter test → 461 绿（+6 转换器往返单测）；速记条 56 用例迁移后零回归；docs-lint OK
- [2026-10-03] [变更]: 详情编辑态顶栏标题去重（用户反馈「标题重复显示」）：速记条目标题=正文首行（noteTitleOf 口径），编辑态首行已进统一作曲编辑器，顶栏标题与正文首行相同时不再重复显示（_buildTitle 编辑态分支首行比对）；标题与首行不同的条目（网页收集类）编辑态照常显示顶栏标题
- [2026-10-03] [变更]: 标题独立+媒体卡滑删（用户反馈二项）：①noteTitleOf 重写——标题与 md 解耦，取第一个一级标题行纯文本（## 不算），无则 null→详情页落时间标题（速记保存不再写「图文便签」兜底，humanTitle 可空透传）；②编辑态顶栏标题恒隐藏（正文首行常即标题行，顶栏再显即重复）；③媒体卡移除改手势——去右上角叉号，按住卡横滑超 72dp 或快甩即删（音频条 Slider 区域竞技场优先不误删），移除后光标自动定位到相邻段合并点（原媒体位置），不再丢光标
- [2026-10-03] [验证]: flutter analyze → 0 issue；全量 flutter test → 461 绿（noteTitleOf 语义单测同步更新）
- [2026-10-03] [变更]: 图片卡点击全屏查看（用户拍板）：新建 lib/ui/image_viewer.dart（黑底+InteractiveViewer 双指缩放 maxScale 5+点按关闭，解码宽度按屏宽走统一 cacheWidth 口径），编辑器图片卡 onTap 接入（长按替换/横滑移除/点按查看三手势并存，草稿态与详情编辑同源）
- [2026-10-03] [验证]: flutter analyze → 0 issue；quick_note_bar_test → 12 绿
- [2026-10-03] [变更]: 视频封面（用户拍板「视频加封面」）：MediaBridge 增 videoCover（MediaMetadataRetriever 首帧 SYNC→CLOSEST 回落，JPEG 压缩宽≤720 等比降采样，字节透传，null 非阻断契约不变）+ MediaToolkit.videoCover 接口；新建 VideoCoverImage（url 进程级缓存含失败缓存防重试、inflight 去重、本地文件存在性预判），作曲层视频卡与 InlineMediaVideo 行内块接入（封面+中央播放钮+label 阴影叠字，点按仍全屏播放）；无新第三方依赖（走 media-native 能力接口）
- [2026-10-03] [验证]: flutter analyze → 0 issue；全量 flutter test → 462 绿（+videoCover 契约单测）；compileDebugKotlin ✓
- [2026-10-08] [变更]: 编辑器格式档位收口：待办 2026-10-08 拍板回归浮层显式档（LineKindTarget 增 todo，直设写 '- [ ] ' 前缀），档位 5→6 按语义序排（plain/h1/h2/bullet/todo/quote，正文回退档置首），列表与待办段同样显示侧轨角标（入口一致性，左缘共 52dp），设计稿 note-format-guidance-layer 同步
- [2026-10-08] [验证]: flutter analyze → No issues found (8.8s); flutter test --timeout 60s (set_line_kind + op_log + ordered_deletion + block_presentation) → 29/29 All tests passed
- [2026-10-08] [SSOT 修正]: 旧结论「去掉待办列表」（2026-10-03，动作行待办入口移除）已废弃 ➔ 新结论：待办保留，2026-10-08 回归浮层建行档（BlockKind.todo → LineKindTarget.todo，直设写 '- [ ] '）；保存期整段逐行转待办的 _todoMode 入口仍不恢复
- [2026-10-08] [变更]: 标题标记区显隐回归隐藏态：废弃中困惑 #G 淡显，标题与列表/引用/待办同口径走透明占位隐藏（编辑区不再显示 '# '），判据方法公开包装 hiddenMarkerRangesFor 供单测钉住，新增 test/span_text_controller_marker_test.dart 7 条
- [2026-10-08] [验证]: flutter analyze → No issues found (8.7s); flutter test --timeout 60s (span_text_controller_marker 新增 7 + quick_note_text_actions + composer_list_enter) → 74/74 All tests passed
- [2026-10-08] [变更]: 动作行改造（2026-10-08 拍板：钉住高频 + 其余横滚）：撤销/重做钉左端恒可见；拍照/相册/录音/视频/导入md/软换行/标签进横向滚动区（插入类聚合，md 紧跟视频）；可滚时右缘 16dp 渐隐作 affordance（IgnorePointer 不吞点击，不可滚不画）；标签文本改限宽截断，避免 Expanded 撑满使滚动失效
- [2026-10-08] [验证]: flutter analyze → No issues found (8.6s); flutter test --timeout 60s 全量 → 547 passed / 5 failed（5 条均属转盘退役遗留死测试，见同日 [暂停] 行，与本轮改动无因果关系）
- [2026-10-08] [暂停]: 越界失败自动暂停：全量测试 5 红 = composer_input_friction_test 4 条 + underline_roundtrip_test 1 条，断言均为 Found 0 widgets（悬浮球/转盘 widget 已于格式引导层改造中注释退役），失败文件不在本会话 diff 且与本轮动作行/显隐改动无因果链 → 未越界修改，挂待办待用户确认后整段清偿
- [2026-10-08] [变更]: 死代码清偿 + 行内格式回归：删除转盘体系（format_dial/smart_floating_hub/format_toolbar/edit_session 四组件与各自单测、编辑器内转盘注释块与停靠持久化）并清 10 条遗留死测试；浮层新增 B/I 行内档（标题二之后，细分隔分组，开关型先选后打单选制），新增 test/composer_inline_mark_test.dart 4 条，设计稿与 ui-spec/unification 同步
- [2026-10-08] [验证]: flutter analyze → No issues found; flutter test --timeout 60s 全量 → 702 passed / 2 failed（2 红为 quick_note_bar 保存路由既有脆弱 + 其连带的保存按钮感知；已用 git stash 对照验证：回到清理前 HEAD 状态该用例同样失败，非本次引入）
- [2026-10-08] [订正]: 同日早先 [暂停] 行统计有误（输出被 head 截断）：转盘遗留死测试实为 10 条 = quick_note_bar 5 + composer_input_friction 4 + underline_roundtrip 1，非 5 条；现已全部清偿
- [2026-10-08] [变更]: 恢复转盘组件本体（用户拍板「组件留着、只删编辑区调用」）：git checkout 还原 lib/ui/format_dial.dart 与 test/format_dial_test.dart，编辑器调用侧保持已清理；三处文档口径由「已删除」改回「组件保留待复用」
- [2026-10-08] [验证]: flutter analyze → No issues found; flutter test --timeout 60s test/format_dial_test.dart → 30/30 All tests passed
- [2026-10-08] [变更]: 恢复 smart_floating_hub 组件与单测（用户拍板「组件留着」）；H2 辨识度：改 block_presentation 为字号档+w700+主色（md 编辑器三件套），标记隐藏后仍一眼可辨，设计稿 §2 同步
- [2026-10-08] [验证]: flutter analyze → No issues found; flutter test --timeout 60s (block_presentation + span_text_controller_marker + composer_inline_mark) → 15/15 All tests passed; smart_floating_hub_test → 3/3 All tests passed
- [2026-10-08] [变更]: 按 R5 拆分 quick_note_bar「保存路由」：UI 侧改用 _FakeCollector 替身（只守内容交动作层唯一写入口+反馈+清空，不碰真实 sqlite），落库断言搬到数据侧 test/text_collector_test.dart 普通 test（速记保存=单条 note 且 preview 含原文）；pumpShell 支持注入 collector
- [2026-10-08] [验证]: flutter analyze → No issues found; flutter test --timeout 60s 全量 → 738/738 All tests passed（此前 2 红已消）
