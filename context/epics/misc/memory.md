---
dev-loop: memory
format: v1
epic: misc
total-merged: 1
last-merge: 2026-10-09
---

# misc（散修/小改动挂靠）

## 决策与状态
- [2026-10-03] 速记转盘三轮迭代后于 2026-10-08 **退役**（格式引导层替代：聚焦段侧轨语义角标 + 贴键浮层打样面板 `_blockFormatPanel` 5 档瓦片）；**[SSOT 修正 2026-10-08]** 旧结论「去掉待办列表」已废弃 ➔ 待办保留，回归浮层建行档（LineKindTarget.todo，直设写 '- [ ] '）；保存期整段逐行转待办的 _todoMode 入口仍不恢复
- [2026-10-08] 格式档位收口：LineKindTarget 6 档按语义序（plain/h1/h2/bullet/todo/quote）；标题标记显隐回归隐藏态（#G 淡显困惑修复后定版）；动作行改造=撤销/重做钉左端 + 其余横滚区（右缘 16dp 渐隐 affordance）
- [2026-10-08] 死代码清偿：edit_session/format_toolbar/转盘注释块删除后，format_dial/smart_floating_hub 组件本体经用户拍板**恢复保留**（「组件留着、只删编辑区调用」），零消费方待复用清偿登记 todos
- [2026-10-03] 编辑器统一（note-editor-unification.md）：共享 NoteComposerEditor + noteTitleOf（标题与 md 解耦）+ 图片全屏查看（image_viewer）+ 视频封面（MediaBridge.videoCover + VideoCoverImage 缓存）
- [2026-10-08] quick_note_bar 保存路由按 R5 拆分：UI 侧 _FakeCollector 替身、落库断言搬数据侧 text_collector_test（修 2 红的根）

## 断点
- [断点] 下一步：真机验收浮层 B/I 档、H2 主色辨识度与动作行横滚；其余等待散修任务
