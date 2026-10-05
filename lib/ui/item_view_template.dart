import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../ai/audio_extract.dart';
import '../ai/capability.dart';
import '../ai/video_clips.dart';
import '../ai/subtitle.dart';
import '../ai/url_extract.dart';
import '../ai/palette_reconstructor.dart' show colorFromMachineJson;
import '../data/block_artifacts.dart' show BlockArtifactKind;
import '../models/item.dart';
import 'block_capability_host.dart';
import 'content_body.dart';
import 'image_viewer.dart';
import 'media_blocks.dart';
import 'section_legend.dart';
import 'tokens.dart';

/// 详情查看模板 + 按类型注册表（设计 §4.3/§6）。
/// 通用外壳（tldr/标题/机器态切换/元信息/操作）由 ItemViewTemplate 承载，
/// 类型专属区由 ItemViewRegistry.resolve(itemType) 的实现填充——
/// 新增类型 = 实现专属区 + 注册，框架零改动（与 AiReconstructor 同构）。
///
/// 2026-09-30 Phase 1：视图函数返回 `List<Widget>`（sliver 兼容），文本类正文经
/// `SliverList` 虚拟化，媒体类走 `SliverToBoxAdapter`，由详情页 `CustomScrollView` 统一滚动。
typedef ItemViewBuilder = List<Widget> Function(
  BuildContext context,
  InboxItem item,
);

class ItemViewRegistry {
  ItemViewRegistry._();

  static final Map<String, ItemViewBuilder> _views = {
    InboxItem.typeNote: _textView,
    InboxItem.typeChatlog: _textView,
    InboxItem.typeDocument: _documentView,
    InboxItem.typeUrl: _urlView,
    InboxItem.typeImage: _imageView,
    InboxItem.typeVideo: _videoView,
    InboxItem.typeAudio: _audioView,
  };

  /// 注册/覆盖某类型的专属区（扩展点）。
  static void register(String itemType, ItemViewBuilder builder) =>
      _views[itemType] = builder;

  static ItemViewBuilder resolve(String itemType) =>
      _views[itemType] ?? _fallbackView;
}

/// 详情页模板：**文档形态**（SSOT ui-spec §4.3）。
///
/// 结构：标题（`headlineSmall` w600）→ 导语块（原 TL;DR）→ 正文 / 类型专属区。
/// 机器态改为**受控**（由页面 AppBar `⋯` 菜单切换），不再在正文流里常驻开关——
/// 双态是架构灵魂，入口保留但降权，不占正文的视觉主线。
class ItemViewTemplate extends StatelessWidget {
  const ItemViewTemplate({
    super.key,
    required this.item,
    this.machineMode = false,
  });

  final InboxItem item;

  /// 机器态开关（双态呈现：需显式切换）。由页面控制。
  final bool machineMode;

  @override
  Widget build(BuildContext context) =>
      CustomScrollView(slivers: bodySlivers(context));

  /// 详情页主体 slivers：标题 / 导语 / 正文区（类型专属）。
  ///
  /// 正文文本经 [SliverList] 虚拟化（Phase 1）；媒体类型仍走普通 widget 包进
  /// [SliverToBoxAdapter]。由 `item_detail_page` 的 `CustomScrollView` 组合。
  List<Widget> bodySlivers(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final out = <Widget>[];
    // ① 标题已上移至页面 AppBar 最顶部（2026-10-02 拍板：内容区只留导语 + 正文，
    // 版式更干净；标题长按 = 编辑，由 AppBar 承载），此处不再渲染。
    // ② 导语块（原 TL;DR）：骑框 legend 描边卡（ui-spec §2.3，mymind TLDR
    // 形态——小签嵌框顶边 + 延长线，共享组件 SectionLegendCard）。
    if (item.humanTldr?.isNotEmpty ?? false) {
      out.add(
        SliverToBoxAdapter(
          child: SectionLegendCard(
            legend: 'TLDR',
            child: Text(
              item.humanTldr!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }
    // ③ 正文：机器态 / 人类态（类型专属区）
    if (machineMode) {
      out.add(SliverToBoxAdapter(child: _machineView(context, item)));
    } else {
      out.addAll(ItemViewRegistry.resolve(item.itemType)(context, item));
    }
    // ④ 标签展示区（mymind MIND TAGS 形态，ui-spec §4.3）：AI 提取标签
    // 圆角标签流只读展示（骑框 legend 复用 SectionLegendCard）；无标签不渲染
    // （不做假数据）。点击筛选跳主列表为 V2。
    if (!machineMode && item.tags.isNotEmpty) {
      out.add(
        SliverToBoxAdapter(
          child: SectionLegendCard(
            legend: '标签',
            child: Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [for (final t in item.tags) _tagBadge(context, t)],
            ),
          ),
        ),
      );
    }
    return out;
  }

  /// 只读标签（mymind 深色无边框；选中态不存在，操作归「标签」底栏项）。
  /// 2026-10-01 全系统去胶囊：Stadium → md12 大圆角矩形。
  static Widget _tagBadge(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _machineView(BuildContext context, InboxItem item) {
    final theme = Theme.of(context);
    if (item.machineJson == null || item.machineJson!.isEmpty) {
      return Text('暂无机器态（基础模式）', style: theme.textTheme.bodySmall);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: SelectableText(
        const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(item.machineJson!)),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

/// 通用文本/Markdown 专属区（note / chatlog / url / document 摘要）：虚拟化正文。
/// 长文经 [ContentBodySliver] 转 Isolate 异步解析（Phase 3）；解析为空的
/// body 回退空态。文章类正文走衬线阅读态（ui-spec §2.2 P0，serif）。
List<Widget> _textView(BuildContext context, InboxItem item) {
  final body = item.bodyText;
  if (body.isEmpty) return const [SliverToBoxAdapter(child: _EmptyView())];
  return [
    ContentBodySliver(
      markdown: body,
      serif: true,
      emptyView: const _EmptyView(),
    ),
  ];
}

/// URL 专属区：OG 卡片（rich-text-component.md §6.1 V2）+ 正文虚拟化。
/// 无 OG 元数据（未抓取/页面无标签）时与通用文本区完全一致。
List<Widget> _urlView(BuildContext context, InboxItem item) {
  final og = ogFromMachineJson(item.machineJson);
  final out = <Widget>[];
  if (og != null) out.add(SliverToBoxAdapter(child: _OgCard(meta: og)));
  out.addAll(_textView(context, item));
  return out;
}

/// OG 元数据卡片：封面图（网络图，加载失败整块隐藏）+ 站点名/标题/描述。
class _OgCard extends StatelessWidget {
  const _OgCard({required this.meta});

  final OgMeta meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (meta.image != null)
            Image.network(
              meta.image!,
              fit: BoxFit.cover,
              cacheWidth: 720,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : Container(height: 8, color: scheme.surfaceContainerHighest),
            ),
          Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (meta.siteName != null)
                  Text(
                    meta.siteName!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                if (meta.title != null)
                  Padding(
                    padding: EdgeInsets.only(
                      top: meta.siteName != null ? Insets.xs : 0,
                    ),
                    child: Text(
                      meta.title!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (meta.description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.xs),
                    child: Text(
                      meta.description!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 文档类型：显示落盘文件信息（结构化字段表单随 V2 machine_json 驱动）。
List<Widget> _documentView(BuildContext context, InboxItem item) {
  final out = <Widget>[];
  if (item.bodyText.isNotEmpty) {
    out.add(ContentBodySliver(markdown: item.bodyText));
  }
  out.add(SliverToBoxAdapter(child: _FileTile(path: item.rawFilePath)));
  return out;
}

/// 图片专属区：纯展示（查看态）。标注编辑已迁三级能力页「独立能力」
/// 入口（detail-two-zone.md §5.2 拍板 2026-10-01）——看在二级、动在三级。
List<Widget> _imageView(BuildContext context, InboxItem item) => [
  SliverToBoxAdapter(child: _ImageView(item: item)),
];

class _ImageView extends StatelessWidget {
  const _ImageView({required this.item});
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.hasAttachment)
          // 顶级图片也包能力外壳（detail-two-zone.md §5.1 拍板：
          // 长按进三级能力页——整条图片条目与行内图片块同一入口）。
          // 点按 = 全屏查看（2026-10-03 拍板「图片区域点击之后图片全屏查看」
          // 在二级详情页的兑现——此前只接了作曲器编辑器）。
          wrapWithCapabilityHost(
            GestureDetector(
              onTap: () =>
                  showImageFullScreen(context, file: File(item.rawFilePath!)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md),
                // 尺寸前置（§6.1 V1）+ 主色调占位（V3）：提前摆好版面且以图片
                // 主色铺底，解码完成无白闪、无布局跳动
                child: item.aspectRatio != null
                    ? Container(
                        color:
                            colorFromMachineJson(item.machineJson) ??
                            scheme.surfaceContainerHighest,
                        child: AspectRatio(
                          aspectRatio: item.aspectRatio!,
                          child: Image.file(
                            File(item.rawFilePath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const _EmptyView(text: '图片文件已不存在'),
                          ),
                        ),
                      )
                    : Image.file(
                        File(item.rawFilePath!),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            const _EmptyView(text: '图片文件已不存在'),
                      ),
              ),
            ),
            kind: BlockKind.image,
            anchorLabel: '图片条目',
            // 顶级条目统一（§2.7）：长按进工作流页（OCR→翻译→摘要，与行内块同通道）
            blockKey: BlockArtifactKind.topLevelKey,
            trigger: BlockCapabilityTrigger.longPress,
            previewFile: item.rawFilePath,
          ),
        if (item.bodyText.isNotEmpty)
          // 媒体附文与文本类正文共用 ContentBody（消除裸 SelectableText 渲染降级）
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: ContentBody(markdown: item.bodyText),
          ),
      ],
    );
  }
}

/// 音频专属区：内嵌简单播放器（转写文本随 V2 管线解锁后展示）。
List<Widget> _audioView(BuildContext context, InboxItem item) {
  if (!item.hasAttachment) {
    return const [SliverToBoxAdapter(child: _EmptyView(text: '无音频文件'))];
  }
  return [
    SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.bodyText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: ContentBody(markdown: item.bodyText),
            ),
          // 走页面级播放服务单例（rich-text-media.md §6：行内块与顶级区共用唯一播放器）
          wrapWithCapabilityHost(
            _AudioPlayer(
              path: item.rawFilePath!,
              itemId: item.id?.toString() ?? item.rawFilePath!,
              initialDurationMs: item.mediaDurationMs,
            ),
            kind: BlockKind.audio,
            anchorLabel: '音频条目',
            trigger: BlockCapabilityTrigger.longPress,
            // 顶级条目统一（§2.7）：同视频区，长按进工作流页
            blockKey: BlockArtifactKind.topLevelKey,
          ),
        ],
      ),
    ),
  ];
}

/// 视频专属区：内嵌简单播放器（转写文本随 V2 管线解锁后展示）。
List<Widget> _videoView(BuildContext context, InboxItem item) {
  if (!item.hasAttachment) {
    return const [SliverToBoxAdapter(child: _EmptyView(text: '无视频文件'))];
  }
  return [
    SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.bodyText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: ContentBody(markdown: item.bodyText),
            ),
          wrapWithCapabilityHost(
            _VideoPlayer(
              path: item.rawFilePath!,
              itemId: item.id?.toString(),
              initialDurationMs: item.mediaDurationMs,
              jumpTargets: [
                for (final c in parseClipsJson(item.clipsJson)) c.startMs,
              ],
            ),
            kind: BlockKind.video,
            anchorLabel: '视频条目',
            trigger: BlockCapabilityTrigger.longPress,
            // 顶级条目统一（§2.7）：固定 key='item'，长按进工作流页（与行内
            // 块同通道，产物落 block_artifacts 的 item 分组）
            blockKey: BlockArtifactKind.topLevelKey,
          ),
          if (parseClipsJson(item.clipsJson).isNotEmpty) _ClipsList(item: item),
        ],
      ),
    ),
  ];
}

/// 「关键区间」区块（视频切片产物展示）：
/// 每段起止 + 转写文本 + 摘要；note 优先于状态推断——失败 / 空产出 / 摘要未生成都明说。
class _ClipsList extends StatelessWidget {
  const _ClipsList({required this.item});

  final InboxItem item;

  String _fmt(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final clips = parseClipsJson(item.clipsJson);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '关键区间（${clips.length}）',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.sm),
          for (final c in clips)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: Insets.sm),
              padding: const EdgeInsets.all(Insets.sm),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_fmt(c.startMs)} → ${_fmt(c.endMs)}（时长 ${_fmt(c.durationMs)}）',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  if (c.status == kClipStatusMarked) ...[
                    const SizedBox(height: 4),
                    Text(
                      '已标记（未处理）——标记仅记时间点，处理后才算收藏完成',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ] else if ((c.text ?? '').isEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      c.note ??
                          (c.status == kClipStatusProcessing
                              ? '处理中…（AI 任务队列可查进度）'
                              : '暂无文本'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: c.status == kClipStatusFailed
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 4),
                    SelectableText(c.text!),
                    if ((c.summary ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: SelectableText(
                          '摘要：${c.summary}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (c.note != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          c.note!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 字幕导出（视频条目切片转写产物）：列文件 → 选一个分享。
/// 由三级能力页「字幕导出」独立能力调用（从二级详情页拆入，detail-two-zone.md §5.2）。
Future<void> exportSubtitles(BuildContext context, String itemId) async {
  final files = await SubtitleStore.listFiles(itemId);
  if (!context.mounted) return;
  if (files.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('暂无字幕产物')));
    return;
  }
  final picked = await showModalBottomSheet<SubtitleFile>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(Insets.md),
            child: Text('选择字幕文件分享'),
          ),
          for (final f in files)
            ListTile(
              leading: Icon(
                f.lang == null ? Icons.subtitles_outlined : Icons.translate,
                size: 18,
              ),
              title: Text('导出 ${f.label}'),
              onTap: () => Navigator.pop(ctx, f),
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await SharePlus.instance.share(ShareParams(files: [XFile(picked.path)]));
}

/// 提取音轨（音频 / 视频条目）：选格式 → 提取 → 分享。
/// 由三级能力页「提取音轨」独立能力调用（从二级详情页拆入，detail-two-zone.md §5.2）。
Future<void> extractAudioTrack(BuildContext context, InboxItem item) async {
  final path = item.rawFilePath;
  if (path == null || path.isEmpty) return;
  final fmt = await showModalBottomSheet<AudioExportFormat>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(Insets.md),
            child: Text('导出为（默认无损复制，不重编码）'),
          ),
          for (final f in AudioExportFormat.values)
            ListTile(
              leading: const Icon(Icons.audio_file_outlined),
              title: Text(f.label),
              onTap: () => Navigator.pop(ctx, f),
            ),
        ],
      ),
    ),
  );
  if (fmt == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('正在提取音轨…')));
  final res = await AudioExtractor.extract(path, format: fmt, itemId: item.id);
  messenger.hideCurrentSnackBar();
  if (!res.ok) {
    messenger.showSnackBar(
      SnackBar(content: Text('提取失败：${res.error ?? '未知原因'}')),
    );
    return;
  }
  await SharePlus.instance.share(ShareParams(files: [XFile(res.path!)]));
}

String _fmtTime(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// 顶级音频播放器：收敛进页面级播放服务单例（rich-text-media.md §6）——
/// 自持 `AudioPlayer` 的旧实现已废，与行内 AudioBlock 共用 [MediaAudioBar]。
class _AudioPlayer extends StatelessWidget {
  const _AudioPlayer({
    required this.path,
    required this.itemId,
    this.initialDurationMs,
  });

  final String path;

  /// 播放身份（页内稳定）。
  final String itemId;

  /// 预存总时长（毫秒）；非空即秒显、跳过播放前探测。
  final int? initialDurationMs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: MediaAudioBar(
        blockId: 'top-audio-$itemId',
        source: path,
        showSlider: true,
        initialDuration: initialDurationMs != null
            ? Duration(milliseconds: initialDurationMs!)
            : null,
      ),
    );
  }
}

/// 视频简单播放器：画面 + 播放/暂停 + 进度条 + 时间；加载/解码失败给错误态。
class _VideoPlayer extends StatefulWidget {
  const _VideoPlayer({
    required this.path,
    this.itemId,
    this.jumpTargets = const [],
    this.initialDurationMs,
  });

  final List<int> jumpTargets;
  final String path;

  /// 所属条目 id（块字幕装载用；顶级播放器暂无块 key，传 null 无字幕轨）。
  final String? itemId;

  /// 预存总时长（毫秒）；未初始化前先以此显示总时长，避免「0:00」。
  final int? initialDurationMs;

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  String _fmtMs(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  late final VideoPlayerController _controller = VideoPlayerController.file(
    File(widget.path),
  );
  bool _ready = false;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          final desc = _controller.value.errorDescription;
          setState(() {
            _ready = true;
            _playing = _controller.value.isPlaying;
            // R1：失败原因原样给用户，不吞成统一文案
            if (desc != null) _error = '视频文件加载失败：$desc';
          });
        })
        .catchError((Object e) {
          debugPrint('[VideoPlayer] initialize failed: $e');
          if (mounted) setState(() => _error = '视频文件加载失败：$e');
        });
  }

  void _onChanged() {
    if (mounted) setState(() => _playing = _controller.value.isPlaying);
  }

  Future<void> _toggle() async {
    try {
      if (_controller.value.isPlaying) {
        await _controller.pause();
      } else {
        await _controller.play();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    }
  }

  /// 进全屏播放：复用行内视频同一全屏播放器（`showInlineVideoPlayer`）。
  ///
  /// 两个必须处理的点：①**先暂停**常驻播放器——否则两个 `VideoPlayerController`
  /// 同时解码出声；②**带当前进度进、退出后同步回来**（`startAt`/返回值），否则
  /// 「点了全屏从头开始」「退出后进度丢失」。
  /// 退出**不自动续播**：位置已同步，继续播放与否交给用户，避免退出后突然出声。
  Future<void> _openFullscreen() async {
    final from = _controller.value.position;
    if (_controller.value.isPlaying) {
      try {
        await _controller.pause();
      } catch (_) {}
    }
    if (!mounted) return;
    final end = await showInlineVideoPlayer(
      context,
      url: widget.path,
      itemId: widget.itemId ?? '',
      label: '视频',
      startAt: from,
    );
    if (!mounted || end == null) return;
    try {
      await _controller.seekTo(end);
    } catch (e) {
      if (mounted) setState(() => _error = '跳转失败：$e');
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pos = _controller.value.position;
    final dur = _controller.value.duration;
    // 未初始化前用预存时长显示总时长；初始化成功后以真实值为准
    final total = dur > Duration.zero
        ? dur
        : (widget.initialDurationMs != null && widget.initialDurationMs! > 0
              ? Duration(milliseconds: widget.initialDurationMs!)
              : Duration.zero);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: _error != null
              ? Container(
                  height: 160,
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Text(_error!, style: theme.textTheme.bodySmall),
                  ),
                )
              : !_ready
              ? Container(
                  height: 160,
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Center(child: CircularProgressIndicator()),
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    // 点按视频 = 切换播放/暂停（与音频条同口径：**整块可点按**，
                    // 不再有实体播放按钮）。长按仍归三级能力页（外层 Host 手势）。
                    GestureDetector(
                      onTap: _toggle,
                      behavior: HitTestBehavior.opaque,
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                    // 暂停态居中播放箭头（**手势提示，非按钮**——可发现性兜底）：
                    // 静止的视频帧极易被当成一张图片，须明确「可点按播放」；样式与
                    // media_blocks 视频块同款（半透明黑圆 + 白色播放箭头）。
                    if (!_playing)
                      GestureDetector(
                        onTap: _toggle,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          padding: const EdgeInsets.all(20),
                          child: const Icon(
                            Icons.play_arrow,
                            size: 48,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        if (_error == null && widget.jumpTargets.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xs,
              Insets.xs,
              Insets.xs,
              0,
            ),
            child: Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final ms in widget.jumpTargets)
                  ActionChip(
                    label: Text(
                      '标记 ${_fmtMs(ms)}',
                      style: theme.textTheme.labelSmall,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _ready
                        ? () => _controller.seekTo(Duration(milliseconds: ms))
                        : null,
                  ),
              ],
            ),
          ),
        if (_error == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
            child: Row(
              children: [
                // 状态指示（**非按钮**，与音频条同口径）：暂停/空闲显示播放箭头，
                // 提示「视频可点按播放」——播放控制已移交给视频区点按手势。
                Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Text(_fmtTime(pos), style: theme.textTheme.bodySmall),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: dur > Duration.zero
                      ? Slider(
                          // max **必须**显式给总时长：Slider 默认 max=1.0 而 value
                          // 是毫秒数，漏了 max 会让 value 被钳到 1.0 —— 一播放进度
                          // 条就跳到末尾，而不是按时间推进。
                          value: pos.inMilliseconds.toDouble().clamp(
                            0.0,
                            dur.inMilliseconds.toDouble(),
                          ),
                          max: dur.inMilliseconds.toDouble(),
                          onChanged: (v) => _controller.seekTo(
                            Duration(milliseconds: v.round()),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Text(_fmtTime(total), style: theme.textTheme.bodySmall),
                IconButton(
                  tooltip: '全屏播放',
                  onPressed: _ready ? _openFullscreen : null,
                  icon: const Icon(Icons.fullscreen, size: 20),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

List<Widget> _fallbackView(BuildContext context, InboxItem item) =>
    _textView(context, item);

class _FileTile extends StatelessWidget {
  const _FileTile({this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    if (path == null || path!.isEmpty) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.attach_file),
      title: Text(path!.split('/').last, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        path!,
        style: Theme.of(context).textTheme.bodySmall,
        maxLines: 1,
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({this.text = '暂无内容'});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall);
}
