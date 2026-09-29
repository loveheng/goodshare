import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../ai/audio_extract.dart';
import '../ai/video_clips.dart';
import '../ai/subtitle.dart';
import '../models/item.dart';
import 'image_annotator.dart';
import 'rich_text_view.dart';
import 'tokens.dart';

/// 详情查看模板 + 按类型注册表（设计 §4.3/§6）。
/// 通用外壳（tldr/标题/机器态切换/元信息/操作）由 ItemViewTemplate 承载，
/// 类型专属区由 ItemViewRegistry.resolve(itemType) 的实现填充——
/// 新增类型 = 实现专属区 + 注册，框架零改动（与 AiReconstructor 同构）。
typedef ItemViewBuilder = Widget Function(BuildContext context, InboxItem item);

class ItemViewRegistry {
  ItemViewRegistry._();

  static final Map<String, ItemViewBuilder> _views = {
    InboxItem.typeNote: _textView,
    InboxItem.typeChatlog: _textView,
    InboxItem.typeDocument: _documentView,
    InboxItem.typeUrl: _textView,
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

/// 详情页模板：**文档形态**（2026-09-30 改版，SSOT ui-spec §4.3）。
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ① 标题置顶
        if (item.humanTitle?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              item.humanTitle!,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        // ② 导语块（原 TL;DR）：次级色 + 左侧细线，不再是顶部彩色文本
        if (item.humanTldr?.isNotEmpty ?? false)
          Container(
            margin: const EdgeInsets.only(bottom: Insets.md),
            padding: const EdgeInsets.only(left: Insets.md),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(width: 3, color: scheme.outlineVariant),
              ),
            ),
            child: Text(
              item.humanTldr!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        // ③ 正文：机器态 / 人类态（类型专属区）
        if (machineMode)
          _machineView(context, item)
        else
          ItemViewRegistry.resolve(item.itemType)(context, item),
      ],
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
        const JsonEncoder.withIndent('  ').convert(jsonDecode(item.machineJson!)),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

/// 通用文本/Markdown 专属区（note / chatlog / url / document 摘要）。
Widget _textView(BuildContext context, InboxItem item) {
  final body = item.bodyText;
  if (body.isEmpty) {
    return const _EmptyView();
  }
  return RichTextView(markdown: body);
}

/// 文档类型：显示落盘文件信息（结构化字段表单随 V2 machine_json 驱动）。
Widget _documentView(BuildContext context, InboxItem item) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.bodyText.isNotEmpty) ...[
        RichTextView(markdown: item.bodyText),
        const SizedBox(height: Insets.sm),
      ],
      _FileTile(path: item.rawFilePath),
    ],
  );
}

/// 图片专属区：查看/标注双态（标注业务优先，UI 暂最简）。
Widget _imageView(BuildContext context, InboxItem item) => _ImageView(item: item);

class _ImageView extends StatefulWidget {
  const _ImageView({required this.item});
  final InboxItem item;

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> {
  bool _annotating = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.hasAttachment)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => setState(() => _annotating = !_annotating),
                icon: Icon(_annotating ? Icons.check : Icons.edit_outlined),
                label: Text(_annotating ? '完成标注' : '标注图片'),
              ),
              if (_annotating) ...[
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    '选上方类型后在图上拖拽绘制；文字/序号点击图上输入',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        if (_annotating)
          ImageAnnotator(item: item)
        else ...[
          if (item.hasAttachment)
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.md),
              child: Image.file(
                File(item.rawFilePath!),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const _EmptyView(text: '图片文件已不存在'),
              ),
            ),
          if (item.bodyText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: SelectableText(item.bodyText),
            ),
        ],
      ],
    );
  }
}

/// 音频专属区：内嵌简单播放器（2026-09-27；转写文本随 V2 管线解锁后展示）。
Widget _audioView(BuildContext context, InboxItem item) {
  if (!item.hasAttachment) return const _EmptyView(text: '无音频文件');
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.bodyText.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.sm),
          child: SelectableText(item.bodyText),
        ),
      _AudioPlayer(path: item.rawFilePath!),
      _AudioExportRow(item: item),
      if (item.id != null) _SubtitleExportRow(itemId: item.id!),
    ],
  );
}

/// 视频专属区：内嵌简单播放器（2026-09-27；转写文本随 V2 管线解锁后展示）。
Widget _videoView(BuildContext context, InboxItem item) {
  if (!item.hasAttachment) return const _EmptyView(text: '无视频文件');
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.bodyText.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.sm),
          child: SelectableText(item.bodyText),
        ),
      _VideoPlayer(
        path: item.rawFilePath!,
        jumpTargets: [
          for (final c in parseClipsJson(item.clipsJson)) c.startMs,
        ],
      ),
      _AudioExportRow(item: item),
      if (item.id != null) _SubtitleExportRow(itemId: item.id!),
      if (parseClipsJson(item.clipsJson).isNotEmpty) _ClipsList(item: item),
    ],
  );
}

/// 「关键区间」区块（2026-09-29，视频切片产物展示）：
/// 每段起止 + 转写文本 + 摘要；note 优先于状态推断（与 _AiTaskStatusLine 同口径）——
/// 失败 / 空产出 / 摘要未生成都明说，不静默。
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
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                  Text('${_fmt(c.startMs)} → ${_fmt(c.endMs)}（时长 ${_fmt(c.durationMs)}）',
                      style: Theme.of(context).textTheme.labelMedium),
                  if (c.status == kClipStatusMarked) ...[
                    const SizedBox(height: 4),
                    Text(
                      '已标记（未处理）——标记仅记时间点，处理后才算收藏完成',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
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
                          color: c.status == kClipStatusFailed ? scheme.error : scheme.onSurfaceVariant),
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
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
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

/// 「字幕产物」清单：该条目的每个字幕文件都列出来并各自可分享——主文件
/// （仅原文 / 双语）+ `separate` 模式产出的各语言译文文件（`{itemId}.{lang}.srt|.vtt`）。
///
/// 此前译文文件只落盘、UI 不展示，等于翻译产出用户拿不到；翻译产物必须可见才有用。
/// 按文件存在性判定显隐，不新增 schema（见 asr-subtitle.md §6）。
class _SubtitleExportRow extends StatelessWidget {
  const _SubtitleExportRow({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SubtitleFile>>(
      future: SubtitleStore.listFiles(itemId),
      builder: (context, snap) {
        final files = snap.data;
        if (files == null || files.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: Insets.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '字幕产物${files.length > 2 ? '（含译文）' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Insets.sm),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: [
                  for (final f in files)
                    OutlinedButton.icon(
                      onPressed: () async {
                        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
                      },
                      icon: Icon(
                        f.lang == null ? Icons.subtitles_outlined : Icons.translate,
                        size: 18,
                      ),
                      label: Text('导出 ${f.label}'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 「提取音轨」入口（音频 / 视频条目）：把音轨导出成独立音频文件并分享。
///
/// 默认**跟随原格式无损复制**（`-c:a copy`，不需要编码器，所以 min 版 ffmpeg
/// 也能直接导出 mp3 / ogg / flac），也可重编码为 m4a / flac / wav（内置编码器）。
/// 详见 `lib/ai/audio_extract.dart` 顶部的依赖约束说明。
class _AudioExportRow extends StatelessWidget {
  const _AudioExportRow({required this.item});

  final InboxItem item;

  Future<void> _pick(BuildContext context, String path) async {
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
    // ffmpeg 是原生进程，长音频要几秒——先给反馈，避免「点了没反应」
    messenger.showSnackBar(const SnackBar(content: Text('正在提取音轨…')));
    final res = await AudioExtractor.extract(path, format: fmt, itemId: item.id);
    messenger.hideCurrentSnackBar();
    if (!res.ok) {
      // 失败原因直接来自 AudioExtractor，原样告知（错误要被用户感知，不自己猜一句）
      messenger.showSnackBar(
        SnackBar(content: Text('提取失败：${res.error ?? '未知原因'}')),
      );
      return;
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(res.path!)]));
  }

  @override
  Widget build(BuildContext context) {
    final path = item.rawFilePath;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: OutlinedButton.icon(
        onPressed: () => _pick(context, path),
        icon: const Icon(Icons.audiotrack_outlined, size: 18),
        label: const Text('提取音轨'),
      ),
    );
  }
}

String _fmtTime(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// 音频简单播放器：播放/暂停 + 进度条 + 时间；加载/解码失败给错误态。
class _AudioPlayer extends StatefulWidget {
  const _AudioPlayer({required this.path});

  final String path;

  @override
  State<_AudioPlayer> createState() => _AudioPlayerState();
}

class _AudioPlayerState extends State<_AudioPlayer> {
  late final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 流订阅必须存引用并在 dispose 取消：页面退出后流仍会回调，
    // 无 mounted 防护会抛 setState() called after dispose()。
    _subs.add(_player.positionStream
        .listen((p) => mounted ? setState(() => _position = p) : null));
    _subs.add(_player.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.playerStateStream.listen((s) {
      if (mounted) setState(() => _playing = s.playing);
    }));
    _player.setFilePath(widget.path).catchError((Object e) {
      debugPrint('[AudioPlayer] load failed: $e');
      if (mounted) setState(() => _error = '音频文件加载失败');
      return Duration.zero;
    });
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: Insets.xs),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: _error != null
          ? Row(
              children: [
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.error),
                const SizedBox(width: Insets.sm),
                Expanded(child: Text(_error!, style: theme.textTheme.bodySmall)),
              ],
            )
          : Column(
              children: [
                Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: _toggle,
                      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        '音频 ${_fmtTime(_position)} / ${_fmtTime(_duration)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                if (_duration > Duration.zero)
                  Slider(
                    value: _position.inMilliseconds.toDouble()
                        .clamp(0, _duration.inMilliseconds.toDouble()),
                    onChanged: (v) =>
                        _player.seek(Duration(milliseconds: v.round())),
                  ),
              ],
            ),
    );
  }
}

/// 视频简单播放器：画面 + 播放/暂停 + 进度条 + 时间；加载/解码失败给错误态。
class _VideoPlayer extends StatefulWidget {
  const _VideoPlayer({required this.path, this.jumpTargets = const []});

  /// 切片标记的时间点（毫秒）：点击快速跳转（标记 ≠ 处理，导航用途）。
  final List<int> jumpTargets;

  final String path;

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  String _fmtMs(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  late final VideoPlayerController _controller =
      VideoPlayerController.file(File(widget.path));
  bool _ready = false;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.initialize().then((_) {
      if (!mounted) return;
      final desc = _controller.value.errorDescription;
      setState(() {
        _ready = true;
        _playing = _controller.value.isPlaying;
        if (desc != null) _error = '视频文件加载失败';
      });
    }).catchError((Object e) {
      debugPrint('[VideoPlayer] initialize failed: $e');
      if (mounted) setState(() => _error = '视频文件加载失败');
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
                      child:
                          const Center(child: CircularProgressIndicator()),
                    )
                  : AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
        ),
        if (_error == null && widget.jumpTargets.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.xs, Insets.xs, 0),
            child: Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: [
                for (final ms in widget.jumpTargets)
                  ActionChip(
                    label: Text('标记 ${_fmtMs(ms)}', style: theme.textTheme.labelSmall),
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
                IconButton.filledTonal(
                  onPressed: _ready ? _toggle : null,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: Insets.xs),
                Text(_fmtTime(pos), style: theme.textTheme.bodySmall),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: dur > Duration.zero
                      ? Slider(
                          value: pos.inMilliseconds.toDouble()
                              .clamp(0.0, dur.inMilliseconds.toDouble()),
                          onChanged: (v) => _controller.seekTo(
                              Duration(milliseconds: v.round())),
                        )
                      : const SizedBox.shrink(),
                ),
                Text(_fmtTime(dur), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }
}

Widget _fallbackView(BuildContext context, InboxItem item) => _textView(context, item);

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
      subtitle: Text(path!, style: Theme.of(context).textTheme.bodySmall, maxLines: 1),
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
