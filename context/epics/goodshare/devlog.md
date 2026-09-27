---
dev-loop: devlog
format: v1
epic: goodshare
total-merged: 3
last-merge: 2026-09-27
---
- [2026-09-27] [变更]: MVP 步骤 4 落地——lib/ai/ AI 管线：AiReconstructor 接口 + ReconstructInput/Result（含 itemType 重分类与 facets）+ PlaceholderReconstructor（raw 原样入 human_md）+ ReconstructorRegistry（首个 isAvailable 路由，占位兜底）+ QueueConsumer（3s 轮询排空 pending，claimTask 认领，失败置 failed/-1，已删竞态置 cancelled）；Repository 补 claimTask/finishTask；main 装配启动；goodshare-index 补「AI 管线」域行
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 34/34 通过（新增 queue_consumer_test 5 项：占位端到端/Registry 路由/失败路径/reprocess 链路/删除竞态）
- [2026-09-27] [变更]: MVP 步骤 5 落地——MCP 工具扩展至 §7 全量 10 工具：新增 query_machine_data（仅含机器态条目）、get_timeline_context（health/events 恒空 V3 填充 + listByDate 本机时区查询）、update_item（patch 全字段，machine_json 对象自动编码）、delete_item、set_vault（MCP 仅可移入，移出走 UI 生物识别——PRD 行同步）、reprocess_item、unlock_edit；全部写/改经 ItemActionHandler，ActionException→McpRpcError 映射；接入指南工具表更新 + frontmatter 归一（README ⚠️ 移除）
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 41/41 通过（新增 mcp_tools_test 7 项：patch/锁/Schema/Vault 边界/时间线/工具清单）；node mcp-bridge/e2e-check.mjs → E2E PASS
- [2026-09-27] [变更]: MVP 步骤 6 落地（UI 重构，MVP 代码收官）——依赖核实并接入 flutter_markdown_plus 1.0.12 / record 7.1.1 / image_picker（RECORD_AUDIO 权限入 manifest）；lib/ui/ 框架件（ItemViewTemplate 双态外壳 + ItemViewRegistry 按类型分发 + ContentCard）；页面重构（home_shell 5 tab + 中央 FAB、时光机按天分组、全部·分类视图 + 搜索/FilterChip、AI 分类空态、保险箱 vaultContext、设置树含文本收集模式开关与最近删除、详情页动作区全接 ItemActionHandler）；FAB 速记（文本走 TextCollector/录音存 audio 条目/拍照存 image 条目入 ocr 队列）；main 启动时 purge 过期删除；list_page 删除
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 41/41 通过；flutter build apk --debug → ✓ Built app-debug.apk（新插件 native 构建通过）；goodshare-index 浏览域与 workflow 模块结构表同步
- [2026-09-27] [变更]: 分期调整落地（用户拍板）——OCR/音频转写提前到 v1：OcrReconstructor 消费者实现（ML Kit 中文脚本端侧识别，非图片占位复制，OCR 失败优雅降级不置死信）+ ReconstructInput 补 rawFilePath；速记录音采集时同步端侧转写（speech_to_text onDevice 探测按 D7，不支持 UI 明示仅存音频，转写随 raw 层入库）；main Registry 换 [OcrReconstructor, Placeholder]；版本 1.2.0+4；文档分期同步（PRD 模块二/§9、V2 §3.1/§8 无 GMS 风险行、ui-spec §4.6）+ workflow 插件 API 口径补三插件
- [2026-09-27] [验证]: flutter analyze → No issues found；flutter test → 42/42 通过（新增 OcrReconstructor 降级路径测试）；flutter build apk --debug → ✓ Built（ML Kit/speech_to_text native 构建通过）
- [2026-09-27] [变更]: 新增 GitHub Actions 云端构建 .github/workflows/android.yml——push main/PR/手动触发 analyze+test+release 构建+产物上传，v* 标签自动发 GitHub Release（附 APK 与 sha256，供自更新下载）；JDK17+Flutter 3.47.5 锁定与本地一致，release 沿用 debug 签名约定无 secrets
- [2026-09-27] [验证]: YAML 语法解析通过（pyyaml safe_load）；未跑 CI（需推送后由 GitHub Actions 实际执行，首次运行结果待观察）
