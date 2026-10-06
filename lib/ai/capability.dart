import 'package:flutter/material.dart' show IconData, Icons;

import '../action/commands.dart';
import '../models/item.dart';

/// 区块类型（能力适用域的粒度）：正文富文本块 + 顶级媒体区。
///
/// 编译期封闭集合（detail-two-zone.md §5.2：抽象到位、注册从简）——
/// 出现第五种块再升级注册表。
enum BlockKind { text, image, audio, video }

/// 能力输入：链的后续步骤消费上一步产出（如翻译消费 OCR 文本）。
class CapabilityInput {
  const CapabilityInput({this.text});

  /// 上一步产出文本（人工修订后的 user_edited_output 优先）。
  final String? text;
}

/// 能力执行结果：有中间产出的能力（OCR/转写）捕获文本，
/// 无中间产出的（翻译写回译文段）返回 null text。
class CapabilityResult {
  const CapabilityResult({this.text});

  final String? text;

  bool get hasOutput => text != null && text!.trim().isNotEmpty;
}

/// 产出回注目标（detail-two-zone.md §5.3 显式回注，不自动写回）：
/// 追加为从属块（默认）/ 替换原块（仅文本块）/ 发送灵感区。
enum ReinjectTarget { append, replace, inspiration }

/// 用户/AI 可触达的内容能力（detail-two-zone.md §5.2）。
///
/// Human-AI 对称性（R2）：[command] 出口对接既有命令层——UI 按钮与
/// MCP 工具同源；链步骤经命令层自动进 `ai_task_queue` FIFO 串行
/// （多链互斥=队列化，禁止绕过队列自建并发）。
abstract class ContentCapability {
  const ContentCapability();

  String get id;

  /// 适用块类型自声明——页面/Host 不写类型判断，只问「你适用吗」。
  List<BlockKind> get appliesTo;

  /// 菜单/卡内展示文案。
  String get label;

  /// 命令化出口：组装既有 ItemCommand（唯一写入口，R2）。
  ItemCommand command(String itemId, {CapabilityInput? input});

  /// 执行并捕获中间产出。默认实现：命令入队即返回（队列异步消费，
  /// 产出经 Repository 通知回流）；有同步产出需求的能力覆写。
  Future<CapabilityResult> capture(
    ItemActionHandlerRef handler,
    String itemId, {
    CapabilityInput? input,
  }) async {
    await handler.execute(command(itemId, input: input));
    return const CapabilityResult();
  }
}

/// 动作层执行引用：避免能力层直接依赖完整 Handler（只暴露 execute）。
abstract class ItemActionHandlerRef {
  Future<Object?> execute(ItemCommand command);
}

/// 翻译：文本/图片 OCR 产出/音视频转写产出的下游通用能力。
class TranslateCapability extends ContentCapability {
  const TranslateCapability();

  @override
  String get id => 'translate';

  @override
  List<BlockKind> get appliesTo =>
      const [BlockKind.text, BlockKind.image, BlockKind.audio, BlockKind.video];

  @override
  String get label => '翻译';

  @override
  ItemCommand command(String itemId, {CapabilityInput? input}) =>
      TranslateCommand(itemId);
}

/// OCR：仅图片块。链首（OCR→翻译）。
class OcrCapability extends ContentCapability {
  const OcrCapability();

  @override
  String get id => 'ocr';

  @override
  List<BlockKind> get appliesTo => const [BlockKind.image];

  @override
  String get label => '识别文字';

  @override
  ItemCommand command(String itemId, {CapabilityInput? input}) =>
      OcrCommand(itemId);
}

/// 转写：音频/视频块。链首（转写→摘要）。
class TranscribeCapability extends ContentCapability {
  const TranscribeCapability();

  @override
  String get id => 'transcribe';

  @override
  List<BlockKind> get appliesTo => const [BlockKind.audio, BlockKind.video];

  @override
  String get label => '转写';

  @override
  ItemCommand command(String itemId, {CapabilityInput? input}) =>
      TranscribeCommand(itemId);
}

/// 摘要：全块类型（链尾或独立触发）。
class SummarizeCapability extends ContentCapability {
  const SummarizeCapability();

  @override
  String get id => 'summarize';

  @override
  List<BlockKind> get appliesTo =>
      const [BlockKind.text, BlockKind.image, BlockKind.audio, BlockKind.video];

  @override
  String get label => '摘要';

  @override
  ItemCommand command(String itemId, {CapabilityInput? input}) =>
      SummarizeCommand(itemId);
}

/// 能力静态清单（四能力，均已有命令层实现）。
/// 查询入口：Host 按 appliesTo 过滤，页面零类型判断。
const List<ContentCapability> kContentCapabilities = [
  OcrCapability(),
  TranscribeCapability(),
  TranslateCapability(),
  SummarizeCapability(),
];

/// 按块类型取适用能力（保清单序）。**即三级能力页的链编排**——页内呈现
/// 该块全部适用能力（识别/转写 → 翻译 → 摘要），2026-10-01 拍板不再有
/// 预编排子链与长按能力菜单层。
List<ContentCapability> capabilitiesFor(BlockKind kind) =>
    [for (final c in kContentCapabilities) if (c.appliesTo.contains(kind)) c];

/// 独立能力（detail-two-zone.md §5.2 改版 2026-10-01：类型专属功能从
/// 二级详情页 chips 全部拆入三级能力页）：**链外单发**，不走产出回注——
/// 分类/条码/文本分析写 facets 标注，切片为媒体工具流。
/// 执行经执行作用域 `onRunStandalone(id)` 分发（命令入队或打开工具页）。
///
/// **2026-10-05 视频三级页 IA**：媒体类两项不再列独立 chip——
/// - 提取音轨：**升回工作流首步骤「提取音频」**（见 workflow.dart `_videoSpec`，
///   产 audio_file「音轨」卡，承载内联播放/导出/锚点切换）；
/// - 字幕导出：转写一步双产物已落字幕产物卡，卡上「导出」即此出口，再列
///   一枚 chip 是同一能力两个入口。
/// 故音 / 视频独立能力 = **切片**一项（2026-10-05 扩展：音频块/音频条目同享）。
/// 命令与执行函数保留（`ExtractAudioCommand` / `extractAudioTrack` /
/// `exportSubtitles`）供 MCP 与后续挂载点，非死代码待办。
class StandaloneCapability {
  const StandaloneCapability(this.id, this.label, this.icon, this.appliesTo);

  final String id;
  final String label;
  final IconData icon;
  final List<BlockKind> appliesTo;
}

const List<StandaloneCapability> kStandaloneCapabilities = [
  StandaloneCapability('annotate', '图片标注', Icons.edit_outlined, [
    BlockKind.image,
  ]),
  StandaloneCapability('classify', '识别分类', Icons.auto_awesome_motion_outlined,
      [BlockKind.image]),
  StandaloneCapability('scan_barcode', '识别条码', Icons.qr_code_scanner_outlined,
      [BlockKind.image]),
  // 分析文本（analyze_text）无人类 chip（2026-10-05 拍板）：facets（语言/实体）
  // 是机器维度（MCP get_item 消费、V2 AI 分类页聚类视角），人类展示与标签重复、
  // 产出无处看——命令与管线保留供 MCP（analyze_text_item）。
  // 音 / 视频独立能力：切片（2026-10-05 扩展音频）——提取音轨已升为「提取音频」
  // 首步骤（audio_file「音轨」卡），字幕导出并入字幕卡「导出」，均无需独立 chip。
  StandaloneCapability('clip', '切片', Icons.content_cut,
      [BlockKind.video, BlockKind.audio]),
];

/// 按块类型取适用独立能力（保清单序）。
List<StandaloneCapability> standaloneFor(BlockKind kind) => [
      for (final c in kStandaloneCapabilities)
        if (c.appliesTo.contains(kind)) c,
    ];

/// 块类型 → 展示名（三级能力页标题栏：图片 / 音频 / 视频 / 文本）。
String blockKindLabel(BlockKind kind) => switch (kind) {
      BlockKind.image => '图片',
      BlockKind.audio => '音频',
      BlockKind.video => '视频',
      BlockKind.text => '文本',
    };

/// inbox item_type → BlockKind（顶层媒体区/正文块共用）。
BlockKind blockKindOfItemType(String itemType) => switch (itemType) {
      InboxItem.typeImage => BlockKind.image,
      InboxItem.typeAudio => BlockKind.audio,
      InboxItem.typeVideo => BlockKind.video,
      _ => BlockKind.text,
    };
