---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 4
last-merge: 2026-09-27
---
- [2026-09-27] [变更]: 三项新功能落地——①速记改悬浮球贴边（lib/ui/floating_ball.dart 可拖拽吸附左右边，取代中央 FAB；跨 app 系统悬浮窗为后续项）；②全部 tab 各分类 ＋ 按钮直接添加对应内容（QuickNoteSheet 类型化重构：便签文本/链接地址/拍照相册/聊天截图/视频/音频/文档 file_picker 13.x，全走摄入路径入库即入队）；③链接离线抓取正文（lib/ai/url_extract.dart 零依赖 HTML→文本，消费者 url 分支，设置「链接离线抓取正文」开关默认开，失败回退原文）；caps 增 urlFetchEnabled；ui-spec/PRD 同步
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 47/47 通过；构建未跑（延续用户指示），推送 CI 验证
- [2026-09-27] [变更]: CI 红转绿——purgeDeleted 清理比较改 <=（同毫秒漏删导致 delete 类测试 CI 随机挂）；工作流按用户要求只构建 arm64（--target-platform android-arm64 单 APK）；.gitignore 补 .dart_tool/（此前 160 个文件被误跟踪）
- [2026-09-27] [验证]: flutter test 全量 47/47 + 此前失败的两个测试文件重复 3 次全过；flutter analyze → No issues found（本轮无新代码路径外改动）
