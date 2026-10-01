---
status: active
updated: 2026-09-30
---

# 富文本行内媒体块设计（Image / Audio / Video）

上位文档：[rich-text-component.md](rich-text-component.md)（三层架构与块编辑 SSOT）。本文档是其 §5「规则层语法扩展护栏」的媒体块延伸设计，护栏（三出口、UnknownBlock 数据无损防线）全部继承，与上位冲突时以上位为准。

## 1. 边界：顶级媒体 vs 行内媒体块

一个 `InboxItem` 的媒体有两种存在形式，责任方不同：

| 形态 | 例子 | 责任方 | 现状 |
|---|---|---|---|
| **顶级媒体**（payload 主体） | 抓取的 B 站视频、一段录音 | 调用层（`item_view_template.dart` 的封面卡/播放器），在 `ContentBody` **之外** | 已有，形态规范见 §6 |
| **行内媒体块**（正文混排） | 笔记中间插一张说明图、一段语音备注 | 呈现层（`ContentBody` 的块→widget 映射） | 本设计新增，见 §2-§5 |

两者共用底层播放/图片组件（播放服务、`GoodshareImage`、AspectRatio 占位），但入口、布局、虚拟化策略分开。

## 2. 块模型与语法出口（规则层，纯 Dart）

`lib/doc/rich_text.dart` 新增三个块类型：

```dart
class ImageBlock extends RichBlock { url, alt }
class AudioBlock extends RichBlock { url, label }
class VideoBlock extends RichBlock { url, label }
```

视频封面字段不进 MVP，封面提取落地（V2）时再议。三出口护栏（SSOT：rich-text-component.md §5）：

| 出口 | ImageBlock | AudioBlock / VideoBlock |
|---|---|---|
| `parse` 进得来 | 行首独立 `![alt](url)` 行 → ImageBlock | `[label](url)` 且 url 路径后缀命中白名单：音频（.mp3/.m4a/.aac/.wav/.opus/.amr）→ AudioBlock；视频（.mp4/.mov/.webm/.m3u8）→ VideoBlock |
| `serialize` 出得去 | 标准 `![alt](url)` | `[label](url)`（label 原话，无类型前缀） |
| `blockToPlain` 降级 | `[图片: alt]` | `[音频: label]` / `[视频: label]` |

约束：

- **后缀匹配规则**：经 `Uri.parse(url).path` 取路径（天然剥离 query 与 fragment）、toLowerCase 后与白名单比对；白名单为规则层常量。
- **音频白名单两档**：`.mp3/.m4a/.aac/.wav/.opus` 命中即可内嵌播放；`.amr` 等平台兼容性存疑的后缀 parse 照常归为 AudioBlock（AST 不携带能力信息），呈现层降级渲染为文件卡，不进 `just_audio`。
- **label/alt 保持原话**：规则层禁止注入 `🎤`/`🖼` 等类型前缀（类型视觉糖归呈现层），保证 parse→serialize→parse 块树逐节点相等、往返幂等。
- `serialize` 输出**标准 Markdown 链接语法**，MCP 桌面端零感知，`get_item` 契约零改动。
- **行内媒体 url 写入口径（2026-09-30 拍板①：`local://` 相对标记）**：远程 url 一律 http(s) 绝对地址；**便签作曲器**产出的本地行内媒体 url = **`local://<documents 内相对路径>`**（如 `local://shares/x.jpg`）——**绝不写绝对路径**（iOS 沙盒容器 UUID 段随 App 升级/恢复变动，绝对路径硬编码进内容下次打开全裂；鸿蒙同理）。渲染/IO 层经 `resolveLocalMediaSrc`（attachments.dart）动态拼接当前 documents 目录（main() 启动预热，同步解析）；多端同步确立时只需把 `local://` 整体替换为云端 url，AI 也能从占位符明确感知本地资源。历史绝对路径存量块由 resolver 原样透传兼容。parse 侧对任何口径均不拒绝（宁可渲染失败不丢内容，加载失败走三态降级）。桌面端经 `get_item` 读到的是 `local://` 占位符，与条目 `file` 字段同语义（Human-AI 对称性：降级呈现一致）。
- 段落中间混排的图片/音视频**降级为 `InlineLink`**，只识别「整行即媒体」的形态，控制解析复杂度。
- 顺带修复现状 bug：`![alt](url)` 目前被 parse 成「`!` 文本 + 链接」，渲染出带感叹号的结果；修复后行内混排图片 parse 为 `InlineLink(label: alt)`，渲染无 `!` 残留。

## 3. 呈现层（ContentBody 阅读态）

`buildRichBlock` 新增三个分支：

| 块 | Widget | 约束 |
|---|---|---|
| ImageBlock | 首帧探测定版 + `cacheWidth` 降采样 | 见下「行内图片宽高比」 |
| AudioBlock | 固定高度极简播放条 | 块 widget 不持有播放器，订阅页面级播放服务（见下） |
| VideoBlock | 图标占位卡（主色底 + 播放图标 + label） | **行内不常驻播放器**，点按进全屏浮层播放（`video_player` 全屏 dialog）；封面提取属 V2 |

**行内图片宽高比（防抖动口径）**：渲染用 `Image.network` 且显式 `cacheWidth`（按设备 DPR 降采样，复用 `GoodshareImage` 封装口径）；经 `ImageStream` 首帧回调取真实宽高，写入 session 级 `url → ratio` 内存缓存并定版 `AspectRatio`，首帧前后的高度变化由 `AnimatedSize` 吸收；重进页面、重滚动命中缓存零跳动。**禁止**将行内图片比例反写 `machine_json`（AI 回写整替冲刷）、新增专列或持久 sidecar——顶级媒体的 `inbox_items.aspect_ratio` 专列机制按条目建立，不适用于任意行内 url。

**音频播放服务（单实例红线）**：严禁在 SliverList 块 widget 内实例化 `AudioPlayer`。详情页 State 持有页面级单例 `AudioPlaybackService`（`InheritedWidget` 下发，不引状态管理新依赖）：唯一 `AudioPlayer` 实例 + `ValueNotifier<String?> currentPlayingBlockId`；播放条 widget 只订阅 notifier 画 UI。块 widget 被滑出缓存区 dispose 时，若 `currentPlayingBlockId` 指向自己即自动暂停——sliver 回收即停，内存水位红线由机制保证而非纪律约定。顶级音频播放器同源复用该服务（现状 `item_view_template.dart` 的 `_AudioPlayer` 每实例一个 player，收敛进服务）。服务对 `AudioPlayer` 的依赖收敛在接口之后，测试注入 fake 统计实例数（§7）。

**嵌套透传**：`QuoteBlock` 子块经同一 `buildRichBlock` 递归映射，引用内媒体块照常渲染（单测硬性覆盖，见 §7）。

性能硬约束继承：`.sliver` 面虚拟化路径不得破坏，媒体块走块级 widget 通道；行内图片必须有显式 `cacheWidth`，4K 原图不得按原始尺寸解码进 imageCache。

## 4. 编辑态（批 B 块编辑器）

三种块统一形态：**本体预览 + 删除按钮 + alt/label 小输入框**（直接操纵，不退化成 `![...](...)` 源码）。

- 图片：显示图片本体（同阅读态渲染口径，含 `cacheWidth`），下方 alt 输入框。
- 音频：播放条 + label 输入框；播放条即阅读态 widget，走同一播放服务（预览态可播），激活态只切换输入框。
- 视频：占位卡（与阅读态同源）+ label 输入框；编辑态不启播放。

与批 B Tap-to-Edit 口径一致：预览态即阅读态 widget，激活态全局至多一个。

编辑器打磨项（已落地）：

- **粘贴多段拆块**：一次变更（= 一次粘贴，含 Ctrl+V / 输入法整段上屏）插入片段含 `\n\n` 时按段界拆成多个段落块——首段并入当前块，中间段成新块，末段+光标后原文成尾块并保持激活；粘贴全是空白段则块被清空删除。仅段落块参与；手敲回车逐事件只插入单个 `\n` 永不触发，拆块仍是显式粘贴行为的后果（md 块级语法自动检测拆块已驳回）。
- **激活块 IME 避让**：激活块不在视口内时 `Scrollable.ensureVisible` 滚至视口顶缘（键盘弹起后仍在上半可见区）；已完整可见不滚动，键盘高度变化（MediaQuery viewInsets 差量）重触发。

## 5. 插入链路排期（防工作量失控）

MVP 交付「解析 + 渲染 + 编辑」+ **便利贴作曲器本地插入**（2026-09-30 用户拍板「便签页多媒体编辑、媒体不分散保存」提前了原 V2 的本地行内插入）：

| 阶段 | 内容 | 理由 |
|---|---|---|
| MVP | 三种媒体块的 parse / 渲染 / 删除 / 改 alt·label（远程 url 口径）+ `!` 残留修复 | 显示与编辑一次到位；零新权限、零上传链路 |
| MVP+（2026-09-30） | **便利贴作曲器**：拍照 / 相册 / 录音就地插入，整条序列化为一个 note（`lib/share/note_composer.dart` + `quick_note_bar.dart`）；`InlineMediaImage` 支持本地文件 | 图片（相机权限）与录音（麦克风）链路全部现成，零上传；视频因体积与无封面提取继续 V2 |
| V2 | 图片相册选取 + 压缩 + OSS 上传链路（产出 https url 后写入 ImageBlock） | 多端同步确立后远程口径补齐 |
| V2 | 视频行内插入 + 视频封面提取（顶级 + 行内）+ VideoBlock 封面字段 | 封面提取是新依赖/重开销（耗时路径 Job 化约束），独立排期；**视频插入双路径与门槛规则见 [note-video.md](note-video.md)，VideoBlock 渲染形态以本文档 §3 为准** |

## 6. 顶级媒体区块形态（对齐 mymind，调用层规范）

顶级媒体是 payload 主体，渲染在调用层（`item_view_template.dart`），**不走块树、不进 ContentBody**——视觉形态以 mymind 详情页为对齐目标（全 App 视觉以 mymind 风格为基准，旧审美作废）。行内视频块（§3）可即行采用占位卡形态，顶级视频则因转录稿联动延后：

| 媒体类型 | 目标形态 | 要点 |
|---|---|---|
| video | **MVP 保持常驻播放器**（单实例、离页即释放）：OCR 转录稿跳转（`jumpTargets`）依赖播放器常驻可 seek，「占位卡 + 点按进浮层」会割裂「点转录稿跳转播放」的联动，属交互重设计 | 随封面提取一并 V2 再议占位卡形态；届时浮层须携带转录稿跳转能力 |
| audio | 波形/播放条卡片区置于正文上方，附文（转录稿）在 `ContentBody` 内 | 播放器收敛进页面级播放服务单例（§3 同一服务），离页即释放（内存水位红线；现状每实例一个 player，须改造） |
| image | 大图卡 `AspectRatio` 占位 + 底色（V1 尺寸前置已落地），多图走**纵向块流**（虚拟化友好）；横滑为 V2 增强 | 加载中不塌陷高度 |

硬约束：

- 顶级媒体区与正文（`ContentBody`）之间只有**布局顺序**关系，无数据耦合——媒体渲染不读 human_md，正文不读媒体字段。
- 详情页 `CustomScrollView` 内，顶级媒体区走 `SliverToBoxAdapter`，正文继续走 `SliverList` 虚拟化，互不破坏（超长文本 Phase 1 成果不回退）。
- 行内媒体块（§3）与顶级媒体区**共用**底层组件（播放服务、图片封装、AspectRatio 占位），代码落点收在共享 widget，禁止两套实现。

## 7. 验收

- 三种媒体块 parse→serialize→parse 往返**块树逐节点相等**；label/alt 原话往返不变（无前缀注入）。
- 后缀边界用例：`.mp4?token=x`、`.MP4`、`#fragment` 均正确归类；不命中白名单的 `[label](url)` 保持 `InlineLink`。
- `QuoteBlock` 内嵌 `ImageBlock`：parse 树正确，呈现层嵌套渲染不遗漏。
- 含 `![alt](url)` 的 md 渲染无「`!`+链接」残留；段落混排媒体降级 `InlineLink` 不丢内容（UnknownBlock 既有用例不回归）。
- 播放服务：同页两个 AudioBlock 先后播放互斥（切换自动停前一个）；长文含 10+ AudioBlock 全程滚动，注入 fake 统计播放器实例数恒为 1；块滑出视野 dispose 自动暂停（widget test）。
- 行内图片首帧定版后重滚动零跳动（ratio 缓存命中）；所有行内图片带显式 `cacheWidth`（对渲染配置断言，高分辨率图不按原始尺寸进 imageCache）。
- 块编辑器保存链路产出的行内媒体 url 全部 http(s)（保证口在写路径，`serialize` 对 url 原样透传不擅自改写）；parse 对 `file://` url 不崩溃不丢内容。
- 顶级媒体区形态达 §6 规范，渲染路径与行内块共用底层组件（无两套实现）。
- `UpdateItemCommand` / MCP `get_item` 契约零改动（`test/mcp_server_test.dart` 通过）；长文 sliver 虚拟化不回退。
- 便利贴作曲器（MVP+，`test/note_composer_test.dart`）：段序列化产物 parse 回块树正确（图→ImageBlock / 音→AudioBlock）；alt·label 转义不破坏媒体行；parse→serialize 往返 alt·label 原话不变；含媒体路由直发 `CollectCommand`（mode=scatter，永不并链）、纯文本走 `TextCollector`（合并不变）。
- **AI 防冲刷护城河**（2026-09-30 拍板叮嘱②）：`apply_ai_result` 回写前经 `lostMediaUrls`（规则层纯函数）比对原文与产出的行内媒体 url 集合，丢失即保留原文 human_md（其余字段照常应用），原因进 result.note 可感知（`test/rich_text_parser_test.dart` + `test/action_handler_test.dart`）；UI/MCP `update` 走块编辑器不受限（用户手动删媒体是合法操作）。
- **备份不漏行内媒体**（2026-09-30）：`collectBackupFiles` 解析条目 human_md 的 `local://` 媒体收进白名单（同 rel 去重；Vault 条目随既有口径排除；视频源排除策略不波及，`test/video_clips_test.dart`）。
