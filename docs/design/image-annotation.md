---
status: draft
updated: 2026-09-28
---

# 图片标注工具设计

> 非破坏性标注：在原图之上叠加**视觉标记层（overlay）**，不改写原图像素。标注作为独立数据（JSON）与图片 item 关联；原图只读。与「改图」（裁剪/滤镜/模糊/马赛克）严格区分——本工具只做"标注"，不做像素编辑。
>
> **2026-10-01 交互层改版**：本文档的**元数据层架构（annotations JSON、随条目走、进备份、原图只读）全部沿用**；其上的**交互层已改版为对象化标注**（涂画 → 矢量对象操作：标注列表主入口、两级选择、锚点模型、loupe/吸附/触觉反馈栈、画布恒定、文字不合成、工具集四件套）——交互口径以 [image-markup.md](image-markup.md) 为准，schema 按其 §8 扩展对象化字段。图片**像素编辑**（裁剪/旋转）的最小集让位/集成策略亦见该系列评估（完整编辑器不做，系统相册承担）。

## 1. 背景与现状

图片条目现由 `lib/models/item.dart` 的 `InboxItem` 承载：原图存于 `rawFilePath`，OCR 文本写入 `humanMd`（`OcrReconstructor` 用 ML Kit 端侧识别）。图片详情 `_imageView`（`lib/ui/item_view_template.dart`）仅以 `Image.file` 显示原图 + OCR 文本。

现状缺少**视觉标记能力**：用户拿到一张截图/照片，想圈出重点、画箭头指向某处、写一句旁注，但当前只能看，不能标。需求明确为"标注"而非"改图"，即**原图永不被修改**，所有标记可独立增删、可随查看缩放对齐、可关闭/重开。

## 2. 需求界定

| 维度 | 本工具（标注） | 明确排除（改图） |
|---|---|---|
| 原图像素 | 只读，永不写入 | 裁剪 / 滤镜 / 调色 |
| 模糊/马赛克 | 不做（属像素破坏） | 敏感信息打码属改图，本期不做 |
| 标记性质 | 叠加层，独立存储 | —— |
| 可逆性 | 任意增删改，关层即无 | —— |

标注与 OCR 文本**共存**：OCR 产出文字流（人类态），标注产出空间标记（overlay）；二者分别服务于"读字"与"指位置"，互不替代。

## 3. 数据模型

**单条标注**（归一化坐标，独立于屏幕/图片显示尺寸）：

```dart
enum AnnotationType { rect, arrow, free, text, number }

class Annotation {
  final String id;              // uuid（复用 InboxItem.newId）
  final AnnotationType type;
  final List<Offset> points;    // 归一化坐标 [0,1] × 原图宽高
  final String color;           // hex，如 '#FF3B30'
  final double strokeW;         // 归一化线宽（相对原图短边比例），渲染时 × 显示尺寸
  final String? text;           // type==text / number 的标注内容
  final double fontSize;        // 归一化字号（同 strokeW 归一化规则）
  final int z;                  // 叠放次序
  final int createdAt;
}
```

> 类型分层：**基础绘制类**（rect / arrow / free / text / number）覆盖系统截图批注（微信/QQ 截图、Snipaste、系统标记）已有能力，保证可用性；**goodshare 差异化类**是系统自带 app 提供不了的、依赖「结构化 + AI + 同步」底座的能力（见 §3.1）。本期至少交付基础五类，差异化类逐期纳入。

### 3.1 goodshare 差异化能力（系统截图/标记 app 提供不了）

系统工具只做"画图"，goodshare 的标注额外拥有以下系统做不到的属性，根植于本应用的「结构化 + AI + 多端同步」底座：

1. **OCR 文本锚定**：标注框可关联到 OCR 已识别的文字块（`humanMd` 结构化），点击框高亮对应文字、反之亦可——系统工具无 OCR 结构化数据；
2. **语义标签**：标注除颜色外可挂语义（待办 / 重点 / 疑问 / Action），支撑后续筛选与 AI 摘要；
3. **结构化导出**：标注序列化为机器态（纳入 `machineJson` / 独立 JSON），可被 AI 队列与 MCP 工具消费——系统只能导出扁平位图；
4. **跨设备同步**：标注跟随 inbox item 同步（iCloud / 跨端），系统批注只存在于单张图；
5. **关联其他 item**：标注可链接到知识库另一张卡片，使"标注即笔记"；
6. **触发 AI 再处理**：标注区域可提交 AI 解读（"解释这个框里的内容"），复用既有 AI 队列。

差异化能力中哪些纳入本期见 §10。

**集合与存储**

- 路径：`documents/annotations/{itemId}.json`，内容为 `List<Annotation>` 序列化；
- **不新增 inbox_items 字段**：与字幕方案（§6 of `asr-subtitle.md`）一致——「标注是否存在」按 JSON 文件是否存在判定，详情页据此显隐「标注」入口，避免为可选能力扩张主 schema；
- 读写为纯文件 IO（与 OCR 文本落 `humanMd` 解耦），不进 AI 队列、不需 `ReconstructInput`；
- 坐标全部归一化：存储时除以原图宽高，渲染/导出时乘回。即便原图被替换或在不同分辨率屏幕查看，标记位置恒定对齐。

## 4. 能力与 UI（查看 / 标注双态）

图片详情 `_imageView` 升级为「查看模式 / 标注模式」可切换；标注态由新增 `lib/ui/image_annotator.dart` 承载：

- **底层**：`InteractiveViewer` 包裹原图，支持双指缩放/平移（标注在缩放后仍可精确绘制与拖拽）；
- **叠加层**：`CustomPainter` 绘制所有 annotation；`GestureDetector` 捕获落笔/拖动；
- **工具栏**（标注态底部）：类型选择（矩形 / 箭头 / 笔迹 / 文字 / 序号）、颜色、线宽、撤销（删除最近一条）、清空、完成；
- **选中与编辑**：点选已有标注可拖动整体、改色/改字、删除；文字类点击后弹输入框；
- **关闭层**：切换回查看模式即只显示原图，标注数据保留。

OCR 文本仍在标注模式下方照常展示（标注层只覆盖图片区，不遮挡文字）。

## 5. 渲染与坐标归一化

- 渲染：`CustomPainter` 遍历 annotation，将归一化 `points` 乘当前图片显示矩形得屏幕坐标后绘制（rect/箭头用 `canvas.drawRect`/`drawLine`+箭头头部；free 用 `drawPath`；text/number 用 `drawParagraph`）；
- 命中测试：选中/拖拽时按屏幕坐标反归一化比较，阈值取归一化线宽 + 固定容差；
- 缩略图（可选）：列表 `content_card.dart` 可在图片缩略图右下角加「有标注」角标（不叠加缩略渲染，避免重绘开销）；标注缩略渲染留 V2。

## 6. 与现有能力关系

- **OCR**：共存，互不读写彼此数据；标注框对 OCR 文字块的锚定（§3.1 第1项）属差异化能力，是否纳入本期见 §10；
- **重分类**：详情页 `⋯` 菜单的「重分类」按钮已于 2026-10-02 摘除（改由 AI 管线特权 / MCP `update_item(item_type)` 承担）；标注 JSON 随 itemId 走，重分类后路径不变；
- **分享/MCP**：标注暂不作为机器态对外暴露（与字幕一致，体积/消费方未定）。

## 7. 导出（可选，非改原图）

- 本期：仅 overlay 显示 + JSON 存储，**不导出**；
- 后续可选「烧录导出副本」：用 `image` 包在 Dart 侧合成标注到**新文件**（副本），原图不动；仍属"不改原图"范畴。是否引入 `image` 依赖待定。

## 8. 跨平台

纯 Flutter `CustomPainter` + `GestureDetector` + `InteractiveViewer`，**跨平台统一，无平台分流**——与字幕引擎结论（§9 of `asr-subtitle.md`）一致。无原生代码、无系统 API 差异。

## 9. 代码落点

| 文件 | 改动 |
|---|---|
| 新增 `lib/models/annotation.dart` | `AnnotationType` 枚举 + `Annotation` 模型 + 序列化/反序列化 + 读写 `documents/annotations/{id}.json` |
| 新增 `lib/ui/image_annotator.dart` | 标注画布：InteractiveViewer + CustomPainter + 手势 + 工具栏（查看/标注双态） |
| `lib/ui/item_view_template.dart` `_imageView` | 改为「查看/标注」可切换；标注态委托 `ImageAnnotator` |
| `lib/pages/item_detail_page.dart` | 图片条目详情新增「标注」入口/模式切换 |
| `lib/ui/content_card.dart`（可选） | 缩略图标注重标 |

**实现状态（2026-09-28 原型）**：`annotation.dart`（模型 + `AnnotationStore` 文件读写）与 `image_annotator.dart`（最简画布，承载参数采集）已落地；`_imageView` 已改为查看/标注双态。UI 为临时占位（工具栏/布局待美化），业务逻辑与参数获取已可验证。`content_card` 角标随正式 UI 阶段补。

## 10. 决策汇总（含分期策略）

- [已确认方向] 标注类型 = **基础五类**（矩形/箭头/笔迹/文字/序号，系统也有）+ **goodshare 差异化类**（系统提供不了，见 §3.1）；
- [已确认方向] 差异化能力（§3.1 六项）均纳入设计范围；具体哪些本期实现、哪些留 V2，落地时按工作量分期确认，不阻塞基础五类先行；
- [已确认] 列表缩略图本期**仅加「有标注」角标**（零重绘，靠 `documents/annotations/{id}.json` 存在性判定）；标注缩略渲染留 V2（见 §5）；
- [已确认] 导出烧录副本**本期不做**：仅 overlay 显示 + JSON 存储；烧录（image 包 / ffmpeg）留 V2（见 §7）；
- [已确认] 标注组织能力本期**仅平铺列表 + z 序**；隐藏单条 / 分组标签留 V2，避免过早抽象；
