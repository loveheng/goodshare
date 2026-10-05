---
memo: done
format: v2
---

# 完成列表
- [2026-09-30] 行内媒体块 MVP 真机侧载验收全绿（图片首帧定版/双音频互斥/.amr 降级卡/视频全屏浮层/滚动零跳动，用户逐项确认）；验收环境=回环媒体服务器+分享 intent 注入；顺手修 firstUrl 尾部括号剥离 (域: goodshare)
- [2026-09-30] 块编辑器打磨完成：激活块 IME 避让（ensureVisible 视口顶缘+键盘差量重触发）+ 粘贴多段按空行拆块（单次变更检测，手敲回车不触发）；md 语法自动拆块维持驳回 (域: goodshare)
- [2026-09-28] OCR 国内适配完成：bundled 中文库切换 + 真机断网验证通过（用户确认） (域: goodshare)
- [2026-09-28] 翻译层国内可用性拍板：接受 source-only 默认，文档三处同步 (域: goodshare)
- [2026-09-28] 翻译产物可见化：字幕译文文件逐个列出可分享 + 文本译文可导出 .md + 翻译入队前预检与任务状态条 (域: goodshare)
- [2026-10-01] 便签页内嵌视频双路径：主路径相册选择（后置校验 5min/100MB/白名单）+ 次路径相机直拍（60s 自动停），用户只感知时长；mp4/mov 直入库不转码、封面占位卡、100MB 阈值（人工打勾回收） (域: goodshare)
- [2026-10-02] MCP 媒体加工工具补齐：transcribe_item / ocr_item 两工具落地（动作层校验/门控核已备，仅补 MCP 定义+调用分支，工具数 26→28） (域: goodshare)
- [2026-10-02] 字幕产物对 MCP 暴露（asr-subtitle §10 待定项，方案 1）：get_item 内联 subtitles 字段（SRT/VTT+译文文件内容，>256KB 只报 size，字幕层容错不拖挂主路径） (域: goodshare)
- [2026-10-02] LLM 任务失败原因不可观测：OnDeviceLlmEngine 增 unavailableReasonAsync 真值进任务 note（c12797c，附 3 用例单测） (域: goodshare)
- [2026-10-02] 编辑态媒体块精细化（图/音/视频）：`_EditBody` 按块类型分流，媒体块渲染 `MediaBlockEditor`（预览+标签编辑+替换媒体），替换媒体走 `ReplaceMediaOp` 经 `EditSession.apply` 事务一致（人工打勾回收）(域: goodshare)
- [2026-10-03] 自定义 app 图标：flutter_launcher_icons 已接入，源图 assets/icon/app_icon.png（1024²），生成 Android ic_launcher 五套 mipmap + iOS AppIcon（remove_alpha_ios） (域: misc)（人工打勾回收）
