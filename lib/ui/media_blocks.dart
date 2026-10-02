import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
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
    this.initialDuration,
  });

  /// 播放身份（行内块用 State 身份生成；顶级区用稳定 id）。
  final String blockId;
  final String source;
  final String? label;

  /// 顶级区显示进度条；行内极简形态不显示。
  final bool showSlider;

  /// true = 兼容性存疑格式，渲染静态文件卡不进播放器。
  final bool degrade;

  /// 预存总时长（顶级媒体摄入时探测写入，rich-text-media.md §3）：非空即秒显，
  /// 跳过播放前临时建播放器探测；播放时仍由控制器实时覆盖。
  final Duration? initialDuration;

  @override
  State<MediaAudioBar> createState() => _MediaAudioBarState();
}

class _MediaAudioBarState extends State<MediaAudioBar>
    with SingleTickerProviderStateMixin {
  AudioPlaybackController? _controller;
  Ticker? _ticker;
  Duration _duration = Duration.zero;
  bool _probed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = AudioPlaybackService.maybeOf(context);
    if (!_probed) {
      _probed = true;
      // 预存时长优先：秒显且省去临时播放器探测；否则回退播放前探测
      if (widget.initialDuration != null && widget.initialDuration! > Duration.zero) {
        _duration = widget.initialDuration!;
      } else {
        _probeDuration();
      }
    }
  }

  /// 播放前探测总时长并缓存，供未播放时也展示时长（不实例化播放器——红线由
  /// controller.durationFor 的集中一次性探测 + 会话缓存保证）。
  void _probeDuration() {
    if (widget.degrade) return;
    final c = _controller;
    if (c == null) return;
    final cached = c.cachedDuration(widget.source);
    if (cached > Duration.zero) {
      if (mounted) setState(() => _duration = cached);
      return;
    }
    c.durationFor(widget.source).then((d) {
      if (mounted) setState(() => _duration = d);
    });
  }

  @override
  void dispose() {
    _ticker?.dispose();
    // 滑出 sliver 缓存区即触发：正在播的块自动暂停（内存红线由机制保证）
    _controller?.release(widget.blockId);
    super.dispose();
  }

  /// 播放态逐帧刷新，保证进度条/时长绝对实时（不依赖 positionStream 下发节流）。
  /// 暂停或非激活即停 Ticker，零常驻开销（单实例同时仅一首在播）。
  void _ensureTicking(bool playing) {
    if (playing) {
      _ticker ??= createTicker((_) => setState(() {}))..start();
    } else {
      _ticker
        ?..stop()
        ..dispose();
      _ticker = null;
    }
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
        // 播放态逐帧刷新，进度绝对实时（兜底 positionStream 节流）
        _ensureTicking(playing);
        // 未播放时显示已探测/缓存的总时长；播放时显示实时 位置/总时长
        final shownDuration = active ? controller.duration : _duration;
        final Widget body;
        if (error != null) {
          body = Row(children: [
            Icon(Icons.error_outline, size: 18, color: scheme.error),
            const SizedBox(width: Insets.sm),
            Expanded(child: Text(error, style: theme.textTheme.bodySmall)),
          ]);
        } else {
          body = Column(children: [
            // 手势区：点按整块切换播放/暂停（无播放按钮，mymind 手势控制）
            GestureDetector(
              onTap: () => controller.toggle(widget.blockId, widget.source),
              behavior: HitTestBehavior.opaque,
              child: Column(children: [
                // 顶部：label（左）+ 实时时长（右，仅激活）
                Row(children: [
                  Expanded(
                    child: Text(
                      widget.label?.isNotEmpty == true
                          ? widget.label!
                          : '音频',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (active) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      '${_fmt(controller.position)} / ${_fmt(shownDuration)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ] else if (shownDuration > Duration.zero) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      _fmt(shownDuration),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ]),
                const SizedBox(height: Insets.sm),
                // 状态指示（非按钮）：暂停/空闲显示播放箭头提示可点按
                Icon(
                  playing ? Icons.pause : Icons.play_arrow,
                  size: 28,
                  color: scheme.onSurfaceVariant,
                ),
              ]),
            ),
            // 进度条（仅 showSlider 的顶部区/录音；实时跟随 Ticker）
            if (widget.showSlider &&
                active &&
                controller.duration > Duration.zero)
              Slider(
                // max **必须**显式给总时长：Slider 默认 max=1.0 而 value 是毫秒数，
                // 漏了 max 会让 value 被钳到上界 1.0 —— 一播放进度条就跳到末尾。
                value: controller.position.inMilliseconds
                    .toDouble()
                    .clamp(0, controller.duration.inMilliseconds.toDouble()),
                max: controller.duration.inMilliseconds.toDouble(),
                onChanged: (v) =>
                    controller.seek(Duration(milliseconds: v.round())),
              ),
          ]);
        }
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.md, vertical: Insets.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: body,
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
///
/// **返回退出时的播放位置**供调用方回写续播；`null` = 未就绪即退出或走了系统
/// 返回手势（调用方应保持原位不动，不猜测）。
///
/// [startAt] 用于「从区块内当前进度接着播」——顶级视频是**常驻播放器**（设计
/// §6：转录稿跳转依赖它可 seek），进全屏**必须带进度**，否则体验是「点了全屏
/// 却从头开始」。就绪后自动播放：进全屏本身就是「我要看」的意图表达。
Future<Duration?> showInlineVideoPlayer(
  BuildContext context, {
  required String url,
  String? label,
  Duration startAt = Duration.zero,
}) {
  return showDialog<Duration>(
    context: context,
    fullscreenDialog: true,
    barrierColor: Colors.black,
    builder: (_) =>
        _InlineVideoPlayerPage(url: url, label: label, startAt: startAt),
  );
}

class _InlineVideoPlayerPage extends StatefulWidget {
  const _InlineVideoPlayerPage({
    required this.url,
    required this.startAt,
    this.label,
  });

  final String url;
  final String? label;
  final Duration startAt;

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
    _controller.initialize().then((_) async {
      if (!mounted) return;
      // 带调用方的进度续播（顶级视频常驻播放器场景：点了全屏不该从头开始）
      if (widget.startAt > Duration.zero) {
        await _controller.seekTo(widget.startAt);
      }
      if (!mounted) return;
      setState(() => _ready = true);
      // 进全屏本身就是「我要看」的意图表达，就绪即自动播放
      await _controller.play();
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
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        // 显式关闭出口：全屏 dialog 无返回箭头，必须有可见的关闭方式；
        // 关闭时回传当前位置供调用方续播（走系统返回手势则拿不到，null 兜底）
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '关闭',
          onPressed: () => Navigator.pop(
            context,
            _ready ? _controller.value.position : null,
          ),
        ),
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
                    // 手势点按切换播放/暂停（无播放按钮，mymind 手势控制）
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        GestureDetector(
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
                        // 暂停态居中播放箭头（手势提示，非按钮）
                        if (!_controller.value.isPlaying)
                          GestureDetector(
                            onTap: () => _controller.play(),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              padding: const EdgeInsets.all(20),
                              child: const Icon(Icons.play_arrow,
                                  size: 48, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // 实时进度条（点击视频手势切换播放/暂停；进度逐帧跟随监听器）
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Insets.md, vertical: Insets.sm),
                  child: Row(children: [
                    Text(
                      _fmt(_controller.value.position),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white),
                    ),
                    Expanded(
                      child: Slider(
                        // 同上：max 必须显式给总时长，否则 value(毫秒) 被钳到默认
                        // 上界 1.0，进度条会直接跑到末尾。未初始化时 duration=0，
                        // 退化取 1 避免 max==min 的除零（与 clip_editor_sheet 同口径）。
                        value: _controller.value.position.inMilliseconds
                            .toDouble()
                            .clamp(
                                0,
                                _controller.value.duration.inMilliseconds
                                    .toDouble()),
                        max: _controller.value.duration.inMilliseconds > 0
                            ? _controller.value.duration.inMilliseconds
                                .toDouble()
                            : 1,
                        onChanged: (v) => _controller
                            .seekTo(Duration(milliseconds: v.round())),
                      ),
                    ),
                    Text(
                      _fmt(_controller.value.duration),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white),
                    ),
                  ]),
                ),
              ],
            ),
    );
  }
}
