---
status: draft
updated: 2026-10-02
---

# 速记条草稿持久化（方案蓝本，未实现）

> [!NOTE] 状态：**draft**——2026-10-02 定稿，与 `card-batch-selection.md`、`block-format-input.md` 同属整体改造蓝本族；落地验收后转 active。

## 1. 背景与缺口

全部页底部速记条 `QuickNoteBar`（`lib/ui/quick_note_bar.dart`，分段作曲器：文字/图片/录音/视频混排）的「不点保存内容就留在便签里」目前靠 **static 内存字段**（`_draftSegsPersisted` 等，:102 起）实现——能扛收合/切 tab/面板销毁/Activity 重建，但**进程被杀（用户划掉、系统回收、重启手机）草稿全丢**。硬要求：草稿是未保存的创作内容，重启 app 后必须原样回来。

仓库草稿基建**已建成且正为此场景设计**，缺口仅是速记条未接入：

| 既有件 | 位置 | 能力 |
|---|---|---|
| `drafts` sqlite 表 | `lib/data/repository.dart:698` | 大段输入防抖落盘，进程被杀可恢复（规则一 SSOT） |
| `DraftStore` | `lib/models/draft_store.dart` | drafts 表读写删封装，UI 不直连 sqflite |
| `DraftController` | `lib/ui/draft_controller.dart` | 800ms 防抖 + `flush()` 立即落盘 + `clear()` 提交后清除 |
| 生命周期联动 | `AppLifecycleManager.onBackgrounded` → flush | 退后台强制落盘（消费方订阅，参照 `quick_note_sheet.dart:64`） |
| 接入先例 | `quick_note_sheet.dart`（全屏速记页，draftId=`quick_note`） | 完整套路可照抄 |

## 2. 方案（零新机制，纯接入）

1. **序列化**：草稿 = 段序列 JSON——文本段（文字）/ 媒体段（`local://` 相对标记 + 类别）+ 标签列表 + 待办模式 + 面板展开态。写 `drafts.content`，draftId=`quick_note_bar`（与全屏页 `quick_note` 区分，二者互不覆盖）。
2. **落盘时机三层**：
   - 文字变更：800ms 防抖（复用 `DraftController` 模式）；
   - 段结构变更（加/删段、插媒体、改标签、切待办模式）：**立即落盘**——低频高价值，把进程被杀的丢失窗口压缩到「最后 800ms 纯打字」的几个字符；
   - 退后台：`onBackgrounded` → flush。
3. **恢复**：initState 读 JSON 重建段序列。媒体段 `local://` 为相对标记（SSOT：rich-text-media.md §2），文件在 app 私有目录、重启不动，恢复后照常渲染/播放——媒体不丢。
4. **事实源收口**：接入后 `drafts` 表为草稿唯一事实源，static 持久字段**退役**（运行时态即 widget state，重建一律从表恢复），杜绝双写漂移。
5. **清除**：点保存成条成功即 clear（同全屏页口径）。

## 3. 边界说明

- **备份**：`drafts` 表随 DB 快照进 S3 备份，草稿跨机恢复属合理行为，无需排除；Vault 条目草稿已有清理先例（repository 既有 DELETE 分支），速记条草稿无 Vault 语义不涉。
- **丢失窗口**：系统杀进程无回调场景下，未落盘的最后 ≤800ms 纯文字是理论丢失上限；结构变更即时落盘后，实际暴露面只剩连续打字中途被杀。不做逐字符同步写（sqlite 写频换不来体验）。
- 全屏速记页与速记条并存期间各管各的草稿 id，不做合并。

## 4. 落点

| 层 | 变更 | 位置 |
|---|---|---|
| UI | QuickNoteBar 变更点接 DraftStore（序列化/恢复/清除） | `lib/ui/quick_note_bar.dart`（static 字段退役） |
| 生命周期 | onBackgrounded → flush 订阅 | 同上（消费方订阅，同 quick_note_sheet 模式） |
| 存储 | 无变更 | `drafts` 表原样复用 |

## 5. 未实现项清单（转 active 的验收对照）

- [x] 草稿 JSON 序列化/恢复（含媒体段 local:// 重建）（组合G 2026-10-02）
- [x] 三层落盘时机（防抖 / 结构变更即写 / 退后台 flush）（组合G 2026-10-02）
- [x] static 字段退役，drafts 表唯一事实源（组合G 2026-10-02，static 降级为 Activity 重建同步热缓存、与磁盘同源同点写入）
- [ ] 保存成功清除；杀进程重开恢复实测（含媒体段）（清除已落地；杀进程重开恢复待真机实测）
