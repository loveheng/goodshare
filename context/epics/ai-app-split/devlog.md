---
dev-loop: devlog
format: v1
epic: ai-app-split
total-merged: 0
last-merge: none
---

（追加区：≥5 条自动归并进 memory.md）
- [2026-10-10] [决策]: 方向拍板（四轮收敛：worker → 纯 MCP 客户端 → 分治模型 → 只拆 LLM）：AI 宿主 App = 独立新仓、master/交互式 MCP 客户端；goodshare 不再持有 LLM。范围 = {llm_summarize, llm_tags, block_summarize}（同一 LiteRT 引擎物理绑定三分支）；ML Kit/Sherpa/非模型任务全留原地。用户确认 A 方案（tags 随 LLM 同拆，「留原地」物理不可行）并同意 C（改接 ML Kit）登待办。
- [2026-10-10] [变更]: M0 契约文档落盘 docs/design/ai-app-split.md（124 行，active）：接缝 = 3 新增 MCP 工具（claim 纯文本载荷/无任务 idle、touch 5s 心跳复用 30s 僵尸回收、apply 经 ItemActionHandler 统一落库 + finishTask）+ 占位守卫（QueueConsumer SQL 层排除远程集合——否则 PlaceholderReconstructor handles 恒真吞掉远程任务，宿主永远 claim 不到）+ M2 行为变化 6 条（R1 串联摘要走既有静默跳过/clip s 步降级 note/按钮双轨/孤儿模型文件不强制清）+ 引擎搬迁清单（含 proguard keep `-keep class com.google.ai.edge.**` JNI 教训随迁）+ 附件通道延后 + 同令牌安全口径 + M1/M2 验收标准。
- [2026-10-10] [变更]: v2-pipeline devlog 归并（18 条 → memory.md，total-merged: 1，断点原样保留），::bind 切换至本 epic（CURRENT = ai-app-split）。
- [2026-10-10] [验证]: 纯文档+context 轮，无代码验证项。docs-lint OK（提示 1 项：quick-note-format-dial tombstone，提示级）；context-lint 显式 --root 重跑 0 违规 3 告警——GROOM 52 条/SIZE goodshare 198 行均为已登记存量残留；MOUNT 4 条假阳性坐实为脚本默认根解析问题（ai-app-split.md 等文件实际存在，docs-lint README 双向覆盖已佐证），显式 --root 后归零。
- [2026-10-10] [验证]: M1 三接缝工具已实施并验证——flutter analyze 0 issue；flutter test mcp_tools/action_handler/llm_reconstructor 三组 86 项全过（含 claim idle/载荷正确/轻量任务不认领、touch 心跳、apply 同出口落库/乐观锁冲突/参数校验、占位守卫一致性）。工具总数 37（+3）。未提交，待用户拍板宿主仓命名后一并提交。
- [2026-10-10] [决策]: 宿主 App 仓库名拍板：goodhub。
- [2026-10-10] [变更]: M1 提交落盘 d34dda5（feat(ai-split): 三接缝工具+占位守卫，23 文件 +868），含 epic context 三件与契约文档。
