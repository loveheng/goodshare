import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../doc/rich_text.dart';
import '../share/attachments.dart' show resolveLocalMediaSrc;
import 'audio_playback_service.dart';
import 'goodshare_image.dart';
import 'tokens.dart';

/// 行内媒体块渲染（SSOT：docs/design/rich-text-media.md §3）。
///
/// 由 `buildRichBlock`（rich_text_view.dart）按块类型分发；与顶级媒体区共用
/// 底层组件（播放服务、AspectRatio 占位、GoodshareImage 口径），禁两套实现。
/// 加载失败一律维持容器高度 + 统一重试/降级卡，严禁布局塌陷或红屏（三态硬规则）。

// ---------- ImageBlock ----------

/// 行内图片：首帧探测定版 + 显式 cacheWidth 降采样 + 失败重试。
///
/// 宽高比走「首帧探测」：ImageStream 首帧回调取真实宽高写入 session 级缓存并
/// 定版 `AspectRatio`，首帧前后高度变化由 `AnimatedSize` 吸收；重进页面/重滚动
/// 命中缓存零跳动。**禁止**将比例反写 machine_json（AI 回写整替冲刷）、新增
/// 专列或持久 sidecar（rich-text-media.md §3）。
class InlineMediaImage extends StatefulWidget {
  const InlineMediaImage({super.key, required this.block});

  final ImageBlock block;

  @override
  State<InlineMediaImage> createState() => _InlineMediaImageState();
}

class _InlineMediaImageState extends State<InlineMediaImage> {
  /// session 级 url → 宽高比（double 内存占用可忽略，无需 LRU）。
  static final Map<String, double> _ratioCache = {};

  /// 首帧到达前的默认占位比。
  static const double _defaultRatio = 4 / 3;

  /// 行内图片最大逻辑宽（乘 DPR 得 cacheWidth，显存红线：显式降采样）。
  static const double _maxLogicalWidth = 480;

  int _attempt = 0;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  double get _ratio => _ratioCache[widget.block.url] ?? _defaultRatio;

  /// 本地文件口径（便签作曲器产出的 `local://` 相对标记，SSOT：rich-text-media.md §2；
  /// 历史绝对路径存量块同样按本地渲染）。其余按网络 url 走原有链路。
  bool get _isLocal =>
      !widget.block.url.startsWith('http://') &&
      !widget.block.url.startsWith('https://');

  /// local:// → 当前 documents 绝对路径；历史绝对路径 / http(s) 原样透传。
  String get _src => resolveLocalMediaSrc(widget.block.url);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenFirstFrame();
  }

  /// 手动 resolve 与渲染 widget 内部 resolve 命中同一 ImageStream（同
  /// provider key），监听不产生二次加载。
  void _listenFirstFrame() {
    final url = widget.block.url;
    if (_ratioCache.containsKey(url)) return;
    _stream?.removeListener(_listener!);
    final provider = _isLocal ? FileImage(File(_src)) as ImageProvider : NetworkImage(url);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final h = info.image.height;
        if (h > 0) _ratioCache[url] = info.image.width / h;
        if (mounted) setState(() {});
        stream.removeListener(listener);
      },
      onError: (_, _) {},
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: AspectRatio(
          aspectRatio: _ratio,
          child: Container(
            color: scheme.surfaceContainerHighest,
            child: _isLocal
                ? GoodshareImage(
                    file: File(_src),
                    fit: BoxFit.cover,
                    cacheWidth: (dpr * _maxLogicalWidth).round(),
                    key: ValueKey(_attempt),
                    errorBuilder: (_, _, _) => Center(
                      child: InkWell(
                        onTap: () => setState(() => _attempt++),
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: Padding(
                          padding: const EdgeInsets.all(Insets.md),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.broken_image_outlined,
                                  size: 16, color: scheme.onSurfaceVariant),
                              const SizedBox(width: Insets.xs),
                              Text('图片无法读取，点击重试',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                : GoodshareImage.network(
                    url: widget.block.url,
                    fit: BoxFit.cover,
                    cacheWidth: (dpr * _maxLogicalWidth).round(),
                    key: ValueKey(_attempt),
                    loadingBuilder: (context, child, progress) => progress == null
                        ? child
                        : const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                    // 失败维持 AspectRatio 容器高度不塌陷，提供重试出口
                    errorBuilder: (_, _, _) => Center(
                      child: InkWell(
                        onTap: () => setState(() => _attempt++),
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: Padding(
                          padding: const EdgeInsets.all(Insets.md),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.wifi_off, size: 16, color: scheme.onSurfaceVariant),
                              const SizedBox(width: Insets.xs),
                              Text('加载失败，点击重试',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ---------- AudioBlock ----------

/// 音频播放条（行内 AudioBlock 与顶级音频区共用，§3 单实例红线）。
///
/// 只订阅 [AudioPlaybackController] 画 UI，绝不自持 `AudioPlayer`；无服务
/// 作用域或后缀命中兼容性存疑档（.amr 等）时降级为静态文件卡。
class MediaAudioBar extends StatefulWidget {
  const MediaAudioBar({
    super.key,
    required this.blockId,
    required this.source,
    this.label,
    this.showSlider = false,
    this.degrade = false,
  });

  /// 播放身份（行内块用 State 身份生成；顶级区用稳定 id）。
  final String blockId;
  final String source;
  final String? label;

  /// 顶级区显示进度条；行内极简形态不显示。
  final bool showSlider;

  /// true = 兼容性存疑格式，渲染静态文件卡不进播放器。
  final bool degrade;

  @override
  State<MediaAudioBar> createState() => _MediaAudioBarState();
}

class _MediaAudioBarState extends State<MediaAudioBar> {
  AudioPlaybackController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = AudioPlaybackService.maybeOf(context);
  }

  @override
  void dispose() {
    // 滑出 sliver 缓存区即触发：正在播的块自动暂停（内存红线由机制保证）
    _controller?.release(widget.blockId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = _controller;

    // 降级档（.amr 等）或无服务作用域：静态文件卡，不进播放器
    if (widget.degrade || controller == null) {
      return _staticCard(context,
          note: widget.degrade ? '该格式暂不支持内嵌播放' : '音频附件');
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.isActive(widget.blockId);
        final playing = active && controller.playing;
        final error = active ? controller.error : null;
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.md, vertical: Insets.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: error != null
              ? Row(children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: Insets.sm),
                  Expanded(child: Text(error, style: theme.textTheme.bodySmall)),
                ])
              : Column(children: [
                  Row(children: [
                    IconButton.filledTonal(
                      onPressed: () => controller.toggle(widget.blockId, widget.source),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        widget.label?.isNotEmpty == true ? widget.label! : '音频',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: Insets.sm),
                      Text(
                        '${_fmt(controller.position)} / ${_fmt(controller.duration)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ]),
                  if (widget.showSlider &&
                      active &&
                      controller.duration > Duration.zero)
                    Slider(
                      value: controller.position.inMilliseconds
                          .toDouble()
                          .clamp(0, controller.duration.inMilliseconds
                              .toDouble()),
                      onChanged: (v) => controller
                          .seek(Duration(milliseconds: v.round())),
                    ),
                ]),
        );
      },
    );
  }

  Widget _staticCard(BuildContext context, {required String note}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.audiotrack_outlined, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            widget.label?.isNotEmpty == true ? '${widget.label}（$note）' : note,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }
}

String _fmt(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// 行内音频块包装：以 State 身份为播放身份（sliver 重建创建新 State，
/// dispose 钩子仍精确对应自身）。
class InlineMediaAudio extends StatefulWidget {
  const InlineMediaAudio({super.key, required this.block});

  final AudioBlock block;

  @override
  State<InlineMediaAudio> createState() => _InlineMediaAudioState();
}

class _InlineMediaAudioState extends State<InlineMediaAudio> {
  late final String _id = 'inline-audio-${identityHashCode(this)}';

  @override
  Widget build(BuildContext context) {
    final degrade = classifyMediaUrl(widget.block.url) == MediaSuffix.audioDegrade;
    return MediaAudioBar(
      blockId: _id,
      source: widget.block.url,
      label: widget.block.label,
      degrade: degrade,
    );
  }
}

// ---------- VideoBlock ----------

/// 行内视频：图标占位卡（主色底 + 播放图标 + label），行内不常驻播放器，
/// 点按进全屏浮层播放（封面提取 V2，rich-text-media.md §3/§5）。
class InlineMediaVideo extends StatelessWidget {
  const InlineMediaVideo({super.key, required this.block});

  final VideoBlock block;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => showInlineVideoPlayer(
        context,
        url: block.url,
        label: block.label,
      ),
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        padding: const EdgeInsets.all(Insets.md),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_circle_fill, size: 48, color: scheme.primary),
              if (block.label.isNotEmpty) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  block.label,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏浮层播放（行内视频唯一播放出口；不常驻）。
Future<void> showInlineVideoPlayer(
  BuildContext context, {
  required String url,
  String? label,
}) {
  return showDialog<void>(
    context: context,
    fullscreenDialog: true,
    barrierColor: Colors.black,
    builder: (_) => _InlineVideoPlayerPage(url: url, label: label),
  );
}

class _InlineVideoPlayerPage extends StatefulWidget {
  const _InlineVideoPlayerPage({required this.url, this.label});

  final String url;
  final String? label;

  @override
  State<_InlineVideoPlayerPage> createState() => _InlineVideoPlayerPageState();
}

class _InlineVideoPlayerPageState extends State<_InlineVideoPlayerPage> {
  late final VideoPlayerController _controller = _isLocal
      ? VideoPlayerController.file(File(resolveLocalMediaSrc(widget.url)))
      : VideoPlayerController.networkUrl(Uri.parse(widget.url));

  /// `local://`（或历史绝对路径）走本地文件播放；http(s) 走网络。
  bool get _isLocal =>
      !widget.url.startsWith('http://') && !widget.url.startsWith('https://');
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
    _controller.initialize().then((_) {
      if (mounted) setState(() => _ready = true);
    }).catchError((Object e) {
      debugPrint('[DEGRADE] inline_video_load_failed url=${widget.url} error=$e');
      // R1：失败原因原样给用户，不吞成统一文案（硬解不支持/文件缺失可分辨）
      if (mounted) setState(() => _error = '视频加载失败：$e');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          widget.label?.isNotEmpty == true ? widget.label! : '视频',
          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
        ),
      ),
      body: _error != null
          ? Center(
              child: Text(_error!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white)),
            )
          : !_ready
              ? const Center(child: CircularProgressIndicator())
              : Column(
              // 竖版视频（如 720×1280）在窄屏上 VideoPlayer 高约 588dp，控制行
              // 一加必然竖向溢出——曾以调试态黄黑斜纹「BOTTOM OVERFLOWED BY
              // 6.4 PIXELS」呈现（2026-10-01 真机「斜黄条」真身）。Expanded
              // 把视频区钉在剩余空间内（AspectRatio 居中 letterbox），控制行
              // 恒在底部。
              children: [
                Expanded(
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        _controller.value.isPlaying
                            ? _controller.pause()
                            : _controller.play();
                      },
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () {
                        _controller.value.isPlaying
                            ? _controller.pause()
                            : _controller.play();
                      },
                      icon: Icon(
                        _controller.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${_fmt(_controller.value.position)} / ${_fmt(_controller.value.duration)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
