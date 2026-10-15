---
status: active
updated: 2026-10-15
---

# MCP 接入指南

## 手机端准备

1. 安装 APK 后进入「设置」页，**长按「关于」标题**唤出调试菜单 → 「MCP 调试服务」，打开开关（首次会请求通知权限）。入口不进常规设置树（2026-10-15 起，服务仅内部调试用）
2. 记下页面上的 **访问令牌（X-Api-Key）**

前台通知会常驻显示服务状态；切换后台不影响服务。

> **仅绑定 loopback（2026-10-15 起）**：HTTP 服务只监听 `127.0.0.1:8765`，不对外（局域网）暴露，仅作内部调试通道；MCP 主机制走 goodhub 本地 Binder 插件（docs/design/goodhub-local-plugin.md）。桌面端唯一接入途径为 USB + adb reverse。

## 接入方式：USB + adb reverse（唯一途径）

```bash
adb reverse tcp:8765 tcp:8765
```

之后桌面访问 `http://127.0.0.1:8765/mcp` 即手机端服务。重新插拔 USB 后需重跑该命令。

## stdio 客户端配置（Claude Desktop / ZCode 等）

仓库自带 `mcp-bridge/stdio-bridge.mjs`（零依赖，Node ≥18）：

```json
{
  "mcpServers": {
    "goodshare": {
      "command": "node",
      "args": ["/home/zzh/app/goodshare/mcp-bridge/stdio-bridge.mjs"],
      "env": {
        "GOODSHARE_URL": "http://127.0.0.1:8765/mcp",
        "GOODSHARE_TOKEN": "<访问令牌>"
      }
    }
  }
}
```

也可命令行传参：`node stdio-bridge.mjs --url <端点> --token <令牌>`。

## 直接用 HTTP 客户端调试

```bash
curl -s http://127.0.0.1:8765/mcp \
  -H 'content-type: application/json' \
  -H 'x-api-key: <访问令牌>' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
```

## 工具一览

所有写/改动作与手机 UI 走同一实现（MCP 把 JSON 反序列化成 `ItemCommand`，交给与 UI 同一个 `ItemActionHandler`），校验语义完全一致。Vault 条目对 MCP 物理不可见——仅可 `set_vault(on=true)` 移入，无法读取或移出。**工具族共 42 个**（2026-10-15 对数）；`llm_summarize`/`llm_tags`/`block_summarize`/`template_apply` 为远程任务，由 AI 宿主 App 经 claim/touch/apply 三工具消费（docs/design/ai-app-split.md）。

写工具**返回修改后的最新条目快照**（与 `get_item` 同一形状），后续推理请以返回值而非记忆中的旧值为准；被拒时 `error.data` 带 `{code, hint}`，可据此自我纠正（如 `edit_locked` → 先调 `unlock_edit`）。详见 docs/architecture/human-ai-parity.md。

| 工具 | 参数 | 说明 |
|---|---|---|
| `list_items` | `query?` `type?` `limit?(≤100)` `offset?` | 关键词命中标题/正文/标签，时间倒序分页 |
| `get_item` | `id` | 全文（含人类态/机器态）；图片 ≤512KB 返回 base64 image 内容块，更大附件返回 `mcp-blob://` URI 经 `resources/read` 取字节；已转写的音/视频条目带 `subtitles` 字段（SRT/VTT 与译文文件内容内联，单文件 >256KB 只报 `size`）；含行内媒体块的条目带 `block_artifacts`（block_key/kind/text_size/file_path/meta）与 `block_tasks`（活跃块任务：job_id/action/block_key/status/enqueued_at/note?）两个兄弟字段——前者是产物数据、后者是进度，**任务态不混进产物数组** |
| `add_item` | `content` `title?` `tags?[]` | AI 侧写入文本/链接，自动识别纯 URL；不参与合并模式 |
| `query_machine_data` | `query?` `type?` `limit?` `offset?` | 机器态结构化数组（仅含已有 machine_json 的条目） |
| `get_timeline_context` | `date`（YYYY-MM-DD） | 当日多维上下文；健康/事件抓取已于 2026-10-15 砍除，`health`/`events` 恒为空（占位保留） |
| `update_item` | `id` `patch{title? tldr? tags? human_md? machine_json?}` `expected_version?` | 编辑；machine_json 须过领域 Schema 校验；合并锁定条目拒绝写入；`expected_version` 为乐观锁（见下）；~~`item_type` 改判~~已于 2026-10-09 退役，类型仅由摄入源 + 端侧管线回写决定 |
| `delete_item` | `id` | 软删除（30 天内用户可恢复），关联 AI 任务一并取消 |
| `set_vault` | `id` `on:true` | 移入保险箱（之后对 MCP 不可见）；移出仅限手机端操作 |
| `reprocess_item` | `id` | 重新触发双态重构（重置处理态并重新入队） |
| `unlock_edit` | `id` | 解除合并条目编辑锁，随后 `update_item` 方可写入 |
| `batch_items` | `commands[]`（1–20 条，形如 `{"op":"update","id":"...","title":"..."}`） | **原子批量**：全部成功才提交，任一条失败整批回滚；可用 op = `ItemCommand.fromJson` 全量 32 个：update / delete / set_vault / set_pin / reprocess / transcribe / summarize / clip / clip_process / extract_tags / ocr / translate / unlock_edit / restore / delete_forever / collect / append_segment / apply_ai_result / classify / scan_barcode / analyze_text / extract_audio / create_workspace / rename_workspace / delete_workspace / add_to_workspace / remove_from_workspace / migrate_attach / create_template / update_template / delete_template / apply_template（~~reclassify~~ 已于 2026-10-09 退役；set_ai_visible/set_ai_editable 为 UI 专属不可构造） |
| `append_segment` | `id` `text` `source_app?` `expected_version?` | 往合并链末尾追加一段（等价于手机端连续速记自动并链）；仅合并模式条目、末段在 5 分钟窗口内可追加，超窗改用 `add_item` |
| `translate_item` | `id` `target_lang?` `expected_version?` | 端侧离线翻译条目正文（与手机端「翻译」按钮同一入口）。**异步入队**：调用只返回入队结果，译文稍后落库，随后 `get_item` 的 `translation` 字段读取；目标语言受白名单约束，条目无正文（未 OCR 的图片 / 未转写的音频）会被拒绝 |
| `summarize_item` | `id` `expected_version?` | 生成条目摘要（与手机端「摘要」按钮同一入口）。**远程任务**（2026-10-14 ai-app-split M2 后本机无 LLM）：调用即入队 `llm_summarize`，由 AI 宿主 App 经 `claim_ai_task` 认领、`apply_ai_result` 回写 `summary_md`；宿主未就绪时任务滞留 pending（`get_job_status` 可观测）。摘要与原文并列存储，不覆盖原文；`get_item` 的 `summary`/`summary_stale` 字段读取 |
| `extract_tags` | `id` `expected_version?` | 从条目正文提取关键词，并入既有标签（不覆盖已有标签；与手机端「提取关键词」同一入口）。**远程任务**（llm_tags，宿主认领回写）：标签稍后落库，随后 `get_item` 的 `tags` 字段读取；条目无正文会被拒绝 |
| `classify_item` | `id` `expected_version?` | 端侧 ML Kit 给图片打分类标签（与手机端「识别分类」同一入口）。**异步入队**：标签落 `facets['分类']`，随后 `get_item` 读取 `facets`；仅图片可用 |
| `scan_barcode_item` | `id` `expected_version?` | 端侧 ML Kit 扫描图片中的条码/二维码。**异步入队**：`[类型:值]` 落 `facets['条码']`，随后 `get_item` 读取；仅图片可用 |
| `analyze_text_item` | `id` `expected_version?` | 端侧 ML Kit 分析笔记正文：语言识别 + 实体提取（日期/邮箱/电话/地址/URL/金额）。**异步入队**：落 `facets['语言']` 与 `facets['实体']`，随后 `get_item` 读取；仅笔记可用 |
| `transcribe_item` | `id` `subtitle_mode?` `target_lang?` `expected_version?` | 端侧 Sherpa 离线转写音频/视频（与手机端「转写」按钮同一入口）。**异步入队**：文本并入 `human_md`，SRT/VTT 字幕落盘，完成后 `get_item` 读 `human_md` 与 `subtitles` 字段（`get_job_status` 可轮询）；仅音/视频可用，模型须已在手机上下载（未下载任务 note 明示）；`subtitle_mode`（bilingual/separate/sourceOnly）与 `target_lang` 为单次任务覆盖——如 `subtitle_mode=bilingual` 直接产出双语字幕，省略沿用 App 设置 |
| `ocr_item` | `id` `expected_version?` | 端侧 ML Kit 识别图片文字（与手机端「识别文字」按钮同一入口）。**异步入队**：文本并入 `human_md`，随后 `get_item` 读取；仅图片可用 |
| `block_transcribe_item` | `id` `block_key` `subtitle_mode?` `target_lang?` `expected_version?` | **行内音/视频媒体块**转写（与三级能力页该块「转写」按钮同一入口）。`block_key` = 正文媒体行的 `local://` 路径（逐字相等）。**异步入队**：调用即返 `{status:"queued", task_id, message}`，一步双产物（transcript 文本 + SRT/VTT 字幕）落块级产物表、**不冲刷 `human_md`**，稍后 `get_item` 读 `block_artifacts`；同块同任务已在队列 → `invalid_request`（不必重试） |
| `block_ocr_item` | `id` `block_key` `expected_version?` | **行内图片块**端侧 OCR（与三级页该块「识别文字」同入口）。异步入队：返 queued + task_id，产 ocr_text 落 `block_artifacts`；仅图片块可用，非图片被拒 |
| `block_translate_item` | `id` `block_key` `source_kind` `target_lang?` `expected_version?` | 翻译**块已有文本产物**：`source_kind` 必填（transcript / ocr_text / subtitle 选源），源产物不存在或为空会被拒（提示先转写/识别文字）。异步入队：返 queued + task_id，产 translation 落 `block_artifacts` |
| `block_summarize_item` | `id` `block_key` `expected_version?` | 为**块文本产物**（transcript / ocr_text）生成摘要（与三级页「摘要」同入口），无可用源产物被拒。**远程任务**（block_summarize，宿主认领回写）：返 queued + task_id，产 summary 落 `block_artifacts` |
| `block_extract_audio_item` | `id` `block_key` `expected_version?` | 从**行内视频块**提取音轨（与三级页「提取音轨」同入口），产 audio_file（可播放/导出/继续处理）；非视频块被拒。异步入队：返 queued + task_id |

> 五个块能力工具**与三级页五步骤一一对应**（docs/design/block-artifact-workflow.md §7）；`block_key` 一律取自 `get_item` 返回正文里的媒体行 `local://` 路径，逐字相等。旧通道 `batch_items` + 同名 op 仍可用，不废弃。
| `get_job_status` | `job_id?` 或 `id?` | 查询条目最近一次 AI 后台任务状态（pending/processing/completed/failed/paused/cancelled），含失败原因 `note`；耗时工具（summarize/translate/reprocess/transcribe 等）返回的 `job_id` 凭此确认进度 |
| `list_jobs` | `limit?(≤50)` | 列出最近的 AI 后台任务（最新在前），总览队列积压或排查失败 |
| `set_pin` | `id` `on:bool` | 置顶/取消置顶（显示层能力，对应手机端「全部」页顶部置顶区）；返回最新快照 |
| `ai_suggest_tags` | `id` | **纯只读**：经 MCP sampling 反向请求宿主大模型即时建议标签，不落库、不入队；宿主不支持 sampling/超时返回结构化 status（sampling_unavailable 等）。要落库用 `extract_tags` |
| `claim_ai_task` | — | **AI 宿主 App 专用**：认领一条待远程处理的 LLM 任务（llm_summarize / llm_tags / block_summarize / template_apply），原子转 processing 并返回纯文本载荷 + version；无任务返回 idle |
| `touch_ai_task` | `task_id` | 认领任务的存活心跳（每 5s）；30s 无心跳被僵尸回收重置 pending |
| `apply_ai_result` | `task_id` `id` `expected_version?` `summary_md?`/`tags?`/`template_output?`/`note?`/`block_key?` | 回写认领任务的推理产出，经与手机 UI 同一 `ItemActionHandler` 出口落库（乐观锁/打码/标签并集自动生效） |
| `list_template` / `create_template` / `update_template` / `delete_template` | `workspace_id?`/`id`/`name`/`body_md`/`expected_version?` | 内容生产模板 CRUD（AI 托管：人类端只读预览，管理权归 AI——ADR 见 context/decisions.md「ai-template」）；`body_md` 为单一事实源，`goodshare://templates/{id}` resource 派生 skill 文件只读 |
| `list_workspaces` / `create_workspace` / `rename_workspace` / `delete_workspace` | — | 工作区 CRUD（删除级联清理关系记录，条目不受影响；非空工作区删除须人类 UI 确认） |
| `add_to_workspace` / `remove_from_workspace` | `workspace_id` `id` | 条目加入/移出工作区（重复加入幂等；Vault 条目加入被拒） |

**乐观锁（`expected_version`）**：`get_item` / 写工具返回值里的 `version` 即当前版本号。多步规划时把读到的 `version` 原样带回，若期间条目已被用户或他人改动，写入会被拒绝并返回 `version_conflict`（而不是静默覆盖）——此时重新 `get_item` 取最新状态再决策即可。不传则不校验。

## 安全提示

- 令牌泄露即等同手机收集内容泄露，怀疑泄露立即在 app 内重置（旧令牌即时失效）
- 服务仅绑定 loopback（127.0.0.1），局域网不可达；桌面端只能经 USB + adb reverse 接入（无 TLS，仅限本机调试链路）
- Vault 条目对 MCP 物理隔离：大模型只能建议「移入」，永远读不到内容，也不能自行移出
