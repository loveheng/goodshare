---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 1
last-merge: 2026-09-27
---
- [2026-09-27] [变更]: 完成拾贝 v1 全量交付——分享采集链路（文本/链接/图片/视频/文件归一+附件私有目录落盘）、sqflite 存储与列表搜索 UI、内嵌 MCP 服务（Streamable HTTP + list/get/add 三工具 + X-Api-Key + dataSync 前台保活）、桌面 stdio 桥接器、README/docs/workflow/index skill
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 6/6 通过；node mcp-bridge/e2e-check.mjs → E2E PASS 5/5；flutter build apk --debug → ✓ Built app-debug.apk（165MB debug 含全 ABI）
- [2026-09-27] [修复]: 真机反馈「文本分享后丢失」——根因 receive_sharing_intent 1.9.0 Android 侧 toJsonObject 把文本放进 path 字段（message 恒为 null），ShareIntake 只读 message 导致整条不入库；改为 classify() 以 path 为准、message 兜底，并抽成 @visibleForTesting 静态函数补回归测试
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 7/7 通过（含「文本在 path 字段」回归测试）
- [2026-09-27] [变更]: 新增更新体系三件套——应用内自更新（UpdateService 清单检查/流式下载+分块 sha256/异常体系，open_filex 拉起安装器，REQUEST_INSTALL_PACKAGES 权限）、配置热更（RemoteConfigStore 缓存，mcpInstructions 动态注入 MCP initialize，公告展示）、更新页 UI（版本/检查/进度/安装/更新源配置）；版本号提升 1.1.0+3；Shorebird 因安装脚本 404 + api 域名网络不通暂缓（手册已写入 docs/guide/self-update.md）
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 11/11 通过（新增清单解析/版本比较/流式下载+sha256 拒坏包/配置缓存 4 项）；flutter build apk --release 进行中（结果见下一条）
- [2026-09-27] [验证]: flutter build apk --release → ✓ Built app-release.apk（52.7MB 全 ABI，sha256 前缀 1c867ac9…）；自更新用分 ABI 构建可再降到 ~18MB（--split-per-abi，待办评估）
