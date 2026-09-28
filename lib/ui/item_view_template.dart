import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../ai/subtitle.dart';
import '../models/item.dart';
import 'image_annotator.dart';
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

/// 详情页模板：双态呈现 + 类型专属区。
class ItemViewTemplate extends StatefulWidget {
  const ItemViewTemplate({super.key, required this.item});

  final InboxItem item;

  @override
  State<ItemViewTemplate> createState() => _ItemViewTemplateState();
}

class _ItemViewTemplateState extends State<ItemViewTemplate> {
  bool _machineMode = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部固定 TL;DR（人类态摘要）
        if (item.humanTldr?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              item.humanTldr!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        if (item.humanTitle?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(item.humanTitle!, style: theme.textTheme.titleLarge),
          ),
        // 机器态切换（双态呈现：机器态需显式切换；空态明示 V1 基础模式）
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.sm),
          child: Row(
            children: [
              Text('机器态', style: theme.textTheme.labelLarge),
              Switch(
                value: _machineMode,
                onChanged: (_) => setState(() => _machineMode = !_machineMode),
              ),
              if (_machineMode && (item.machineJson == null || item.machineJson!.isEmpty))
                Text('暂无机器态（基础模式）', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (_machineMode && (item.machineJson?.isNotEmpty ?? false))
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Insets.md),
            margin: const EdgeInsets.only(bottom: Insets.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(jsonDecode(item.machineJson!)),
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          )
        else
          ItemViewRegistry.resolve(item.itemType)(context, item),
      ],
    );
  }
}

/// 通用文本/Markdown 专属区（note / chatlog / url / document 摘要）。
Widget _textView(BuildContext context, InboxItem item) {
  final body = item.bodyText;
  if (body.isEmpty) {
    return const _EmptyView();
  }
  return MarkdownBody(
    data: body,
    selectable: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
  );
}

/// 文档类型：显示落盘文件信息（结构化字段表单随 V2 machine_json 驱动）。
Widget _documentView(BuildContext context, InboxItem item) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.bodyText.isNotEmpty) ...[
        MarkdownBody(
          data: item.bodyText,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
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
      _VideoPlayer(path: item.rawFilePath!),
      if (item.id != null) _SubtitleExportRow(itemId: item.id!),
    ],
  );
}

/// 「导出字幕」入口：字幕文件存在才显示（按存在性判定，不新增 schema，
/// 见 asr-subtitle.md §6）。SRT 与 VTT 双份各自分享。
class _SubtitleExportRow extends StatelessWidget {
  const _SubtitleExportRow({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: SubtitleStore.exists(itemId),
      builder: (context, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: Insets.sm),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final f = await SubtitleStore.fileFor(itemId, 'srt');
                  await SharePlus.instance.share(
                      ShareParams(files: [XFile(f.path)]));
                },
                icon: const Icon(Icons.subtitles_outlined, size: 18),
                label: const Text('导出 SRT'),
              ),
              const SizedBox(width: Insets.sm),
              OutlinedButton.icon(
                onPressed: () async {
                  final f = await SubtitleStore.fileFor(itemId, 'vtt');
                  await SharePlus.instance.share(
                      ShareParams(files: [XFile(f.path)]));
                },
                icon: const Icon(Icons.subtitles, size: 18),
                label: const Text('导出 VTT'),
              ),
            ],
          ),
        );
      },
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
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player.positionStream.listen((p) => setState(() => _position = p));
    _player.durationStream.listen((d) {
      if (d != null) setState(() => _duration = d);
    });
    _player.playerStateStream.listen((s) {
      if (mounted) setState(() => _playing = s.playing);
    });
    _player.setFilePath(widget.path).catchError((Object e) {
      debugPrint('[AudioPlayer] load failed: $e');
      if (mounted) setState(() => _error = '音频文件加载失败');
      return Duration.zero;
    });
  }

  @override
  void dispose() {
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
  const _VideoPlayer({required this.path});

  final String path;

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
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
