import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:video_player/video_player.dart';

import '../ai/subtitle.dart' show AsrCue, SubtitleMode;
import '../doc/rich_text.dart';
import '../share/attachments.dart' show resolveLocalMediaSrc;
import 'audio_playback_service.dart';
import 'feedback_views.dart';
import 'goodshare_image.dart';
import 'image_viewer.dart';
import 'tokens.dart';
import 'video_cover.dart';

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
    final provider = _isLocal
        ? FileImage(File(_src)) as ImageProvider
        : NetworkImage(url);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final h = info.image.height;
      if (h > 0) _ratioCache[url] = info.image.width / h;
      if (mounted) setState(() {});
      stream.removeListener(listener);
    }, onError: (_, _) {});
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
    // 点按 = 全屏查看（2026-10-03 拍板「图片区域点击之后图片全屏查看」在
    // 行内阅读态的兑现，与作曲器图片卡同语义）；失败重试钮在 errorBuilder
    // 内层，优先级高于本手势。
    return GestureDetector(
      onTap: () => showImageFullScreen(
        context,
        file: _isLocal ? File(_src) : null,
        networkUrl: _isLocal ? null : widget.block.url,
      ),
      child: AnimatedSize(
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
                      errorBuilder: (_, _, _) => ErrorRetryView(
                        message: '图片无法读取，点击重试',
                        onRetry: () => setState(() => _attempt++),
                      ),
                    )
                  : GoodshareImage.network(
                      url: widget.block.url,
                      fit: BoxFit.cover,
                      cacheWidth: (dpr * _maxLogicalWidth).round(),
                      key: ValueKey(_attempt),
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                          ? child
                          : const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                      // 失败维持 AspectRatio 容器高度不塌陷，提供重试出口
                      errorBuilder: (_, _, _) => ErrorRetryView(
                        message: '加载失败，点击重试',
                        onRetry: () => setState(() => _attempt++),
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
///
/// 手势（2026-10-04 拍板）：**整块点按 = 播放/暂停**，无例外——编辑态也不
/// 再「点按即重录」（重录归宿主长按）。组件因此**不提供点按覆盖口**，
/// 播放手势不允许被别的语义借走。
class MediaAudioBar extends StatefulWidget {
  const MediaAudioBar({
    super.key,
    required this.blockId,
    required this.source,
    this.label,
    this.showSlider = false,
    this.degrade = false,
    this.initialDuration,
    this.backgroundColor,
    this.expandBody = false,
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

  /// 背景色覆盖（缺省 surfaceContainerHighest）。宿主面板与卡片同色时
  /// （速记面板=Highest）传低一档色避免「卡片融进面板」。
  final Color? backgroundColor;

  /// true = 点按手势区撑满卡片剩余高度（作曲器卡内内容居中；须宿主给
  /// bounded 高度，阅读态流式布局不可开）。
  final bool expandBody;

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
      if (widget.initialDuration != null &&
          widget.initialDuration! > Duration.zero) {
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
      return _staticCard(
        context,
        note: widget.degrade ? '该格式暂不支持内嵌播放' : '音频附件',
      );
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
          body = Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: Insets.sm),
              Expanded(child: Text(error, style: theme.textTheme.bodySmall)),
            ],
          );
        } else {
          // 紧凑单行（2026-10-04 拍板）：原「label 行 + 44dp 大播放图标」
          // 两段式近 100dp，与相邻内容失衡——收成
          // [播放指示] 标题 …… 时长 一行，播放时下方接一条细进度条。
          final bar = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // 状态指示（**非按钮**，整块可点按）：主色 = 动作语义
                  //（ui-spec §2.1 橘红仅动作与选中），兼作「可播放」提示。
                  Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    size: 22,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: Insets.sm),
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
                      '${_fmt(controller.position)} / ${_fmt(shownDuration)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ] else if (shownDuration > Duration.zero) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      _fmt(shownDuration),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              // 细进度条（仅 showSlider 的顶部区/录音；实时跟随 Ticker）
              if (widget.showSlider &&
                  active &&
                  controller.duration > Duration.zero)
                _compactSlider(context, controller),
            ],
          );
          final gestureArea = GestureDetector(
            onTap: () => controller.toggle(widget.blockId, widget.source),
            behavior: HitTestBehavior.opaque,
            child: Center(child: bar),
          );
          // expandBody：手势区撑满卡片剩余高度（须宿主 bounded —— 作曲器
          // 卡）；阅读态流式布局无界，只包内容本身——无条件 Expanded 会抛
          // unbounded flex（audio_playback 回归）。
          body = widget.expandBody ? Expanded(child: gestureArea) : gestureArea;
        }
        return _cardShell(scheme: scheme, child: body);
      },
    );
  }

  /// 卡壳（圆角 + 描边 + 波形底纹）：播放条与降级静态卡**同壳**，禁两套观感。
  ///
  /// 描边是**结构分层**（2026-10-04 用户实证「音频条和背景色太接近不好区
  /// 分」）：单靠色阶差在深/浅主题下都可能与页面背景糊在一起，描边恒定可见。
  /// 底纹走 CustomPainter 而非位图资产：随主题槽位取色，换主题零维护
  ///（ui-spec §2.4 装饰色纪律：源图彩色不落一色进代码）。
  Widget _cardShell({required ColorScheme scheme, required Widget child}) {
    return Container(
      // clipBehavior：底纹（内层 DecoratedBox 画满整卡）随圆角裁切，
      // 否则直角底纹会从圆角处露出来。
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      // 底纹走 Decoration 而非 Stack+CustomPaint：内容里可能有 Expanded
      //（expandBody），一旦夹一层 Stack，Expanded 就因父级不是 Flex 而抛
      // ParentData 冲突（audio_playback 回归的翻版）。Padding 同理不是
      // Flex——统一包一层 Column 作 Expanded 的直接 Flex 父级
      //（2026-10-05 修：shell 重构后 Expanded 直放 Padding 下必抛）。
      child: DecoratedBox(
        decoration: _AudioWaveDecoration(
          lineColor: scheme.onSurfaceVariant.withValues(alpha: 0.18),
          washColor: scheme.onSurfaceVariant.withValues(alpha: 0.07),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Column(children: [child]),
        ),
      ),
    );
  }

  /// 细进度条：Slider 默认 48dp 高（含拇指热区），放进紧凑卡会把卡片顶到
  /// 100dp 以上——压到显式 20dp + 细轨小拇指，可拖可点的手感保留。
  Widget _compactSlider(
    BuildContext context,
    AudioPlaybackController controller,
  ) {
    return SizedBox(
      height: 20,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: SliderComponentShape.noOverlay,
        ),
        child: Slider(
          // max **必须**显式给总时长：Slider 默认 max=1.0 而 value 是毫秒数，
          // 漏了 max 会让 value 被钳到上界 1.0 —— 一播放进度条就跳到末尾。
          value: controller.position.inMilliseconds.toDouble().clamp(
            0,
            controller.duration.inMilliseconds.toDouble(),
          ),
          max: controller.duration.inMilliseconds.toDouble(),
          onChanged: (v) => controller.seek(Duration(milliseconds: v.round())),
        ),
      ),
    );
  }

  /// 降级静态卡（无播放服务作用域 / 兼容性存疑格式）：同壳底纹，观感一致。
  Widget _staticCard(BuildContext context, {required String note}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _cardShell(
      scheme: scheme,
      child: Row(
        children: [
          Icon(
            Icons.audiotrack_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              widget.label?.isNotEmpty == true
                  ? '${widget.label}（$note）'
                  : note,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 音频卡内置底纹（横向浅晕 + 波形点阵）：**装饰**，非真实振幅——真实振幅
/// 只在录音弹框（audio_record_sheet）里采，两者不可混淆。
///
/// 作用是把卡片从页面背景里「托」出来（2026-10-04 拍板）：底纹 + 描边组合
/// 分层，不依赖色阶差。纯代码绘制 = 随主题槽位取色，换主题零维护、不引入
/// 位图资产（ui-spec §2.4 装饰色纪律：装饰不走橘红）。
class _AudioWaveDecoration extends Decoration {
  const _AudioWaveDecoration({
    required this.lineColor,
    required this.washColor,
  });

  final Color lineColor;
  final Color washColor;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _AudioWaveBoxPainter(lineColor: lineColor, washColor: washColor);
}

class _AudioWaveBoxPainter extends BoxPainter {
  _AudioWaveBoxPainter({required this.lineColor, required this.washColor});

  final Color lineColor;
  final Color washColor;

  /// 装饰波形：固定 20 点图案（非真实振幅），横向铺满、竖向居中。
  static const List<double> _pattern = <double>[
    0.30,
    0.55,
    0.85,
    0.45,
    0.70,
    0.35,
    0.95,
    0.50,
    0.65,
    0.28,
    0.80,
    0.40,
    0.60,
    0.90,
    0.32,
    0.72,
    0.48,
    0.85,
    0.38,
    0.58,
  ];

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    // 横向浅晕（左重右淡）：静态卡有一点「声波扩散」方向感，不抢内容
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[washColor, washColor.withValues(alpha: 0)],
        ).createShader(rect),
    );
    final bar = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final spacing = size.width / _pattern.length;
    for (var i = 0; i < _pattern.length; i++) {
      final h = size.height * _pattern[i] * 0.72;
      final x = rect.left + spacing * (i + 0.5);
      final mid = rect.top + size.height / 2;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), bar);
    }
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

  // §3.5 字幕轨（音频块与视频块同语义）：有块字幕产物则装载，播放中在条下
  // 叠加当前句文本。数据源 SubtitleScope（详情页注入），无作用域 = 无字幕轨。
  // 刷新驱动：controller 是 ChangeNotifier（position 逐帧更新即 notify），
  // 用 ListenableBuilder 跟随，不自建订阅（避免与 MediaAudioBar 的 Ticker 双轨）。
  List<AsrCue> _cues = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cues.isEmpty) unawaited(_loadSubtitles());
  }

  Future<void> _loadSubtitles() async {
    final scope = SubtitleScope.maybeOf(context);
    if (scope == null) return; // 无作用域（独立预览/编辑态）无字幕轨
    try {
      final cues = await scope.loadBlockSubtitles('local://${widget.block.url}');
      if (!mounted || cues == null || cues.isEmpty) return;
      setState(() => _cues = cues);
    } catch (e) {
      // 字幕轨是增强非必需：装载失败仅降级为无字幕
      debugPrint('[DEGRADE] audio_subtitle_load_failed error=$e');
    }
  }

  /// 当前播放位置对应的字幕文本（二分定位，与视频播放器同口径）。
  String? _cueAt(Duration pos) {
    if (_cues.isEmpty) return null;
    final s = pos.inMilliseconds / 1000;
    var lo = 0, hi = _cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final c = _cues[mid];
      if (s < c.start) {
        hi = mid - 1;
      } else if (s > c.start + (c.duration > 0 ? c.duration : 4)) {
        lo = mid + 1;
      } else {
        return c.line(SubtitleMode.sourceOnly);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final degrade =
        classifyMediaUrl(widget.block.url) == MediaSuffix.audioDegrade;
    final ctl = AudioPlaybackService.maybeOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MediaAudioBar(
          blockId: _id,
          source: widget.block.url,
          label: widget.block.label,
          degrade: degrade,
        ),
        // 当前句叠层（仅播放到 cue 区间内显示；无字幕轨/无服务恒零高度）
        if (ctl != null && _cues.isNotEmpty)
          ListenableBuilder(
            listenable: ctl,
            builder: (context, _) {
              final cue = _cueAt(ctl.position);
              if (cue == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(
                  left: Insets.md,
                  right: Insets.md,
                  bottom: Insets.xs,
                ),
                child: Text(
                  cue,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              );
            },
          ),
      ],
    );
  }
}

// ---------- VideoBlock ----------

/// 字幕轨数据作用域（2026-10-05 块附件通道）：详情页注入 itemId 与产物读取口，
/// 行内视频/音频经 context 取用——buildRichBlock 链不为此加 itemId 参数
/// （四层透传改动面过大，InheritedWidget 与 BlockCapabilityExecutor 同模式）。
class SubtitleScope extends InheritedWidget {
  const SubtitleScope({
    super.key,
    required this.itemId,
    required this.loadBlockSubtitles,
    required super.child,
  });

  final String itemId;

  /// 装载某块的字幕 cue（详情页实现：查 block_artifacts + 读文件反解析）。
  /// null = 无字幕产物（播放器无字幕轨，增强非必需）。
  final Future<List<AsrCue>?> Function(String blockKey) loadBlockSubtitles;

  static SubtitleScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SubtitleScope>();

  @override
  bool updateShouldNotify(SubtitleScope oldWidget) => false;
}

/// 行内视频：图标占位卡（主色底 + 播放图标 + label），行内不常驻播放器，
/// 点按进全屏浮层播放（封面提取 V2，rich-text-media.md §3/§5）。
class InlineMediaVideo extends StatelessWidget {
  const InlineMediaVideo({super.key, required this.block, required this.itemId});

  final VideoBlock block;

  /// 所属条目 id（透传给全屏播放器装载块字幕轨）。
  final String itemId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 字幕轨装载回调：从页面树的 SubtitleScope 取（长按包裹层 context 可达）
    final loadSubs = SubtitleScope.maybeOf(context)?.loadBlockSubtitles;
    return InkWell(
      onTap: () => showInlineVideoPlayer(
        context,
        url: block.url,
        label: block.label,
        itemId: itemId,
        loadSubtitles: loadSubs,
      ),
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        // 原生提帧封面（失败回落中央图标占位），点按仍进全屏播放
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.lg),
                child: VideoCoverImage(url: block.url),
              ),
              Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 48,
                  color: theme.colorScheme.onSurface,
                  shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
              if (block.label.isNotEmpty)
                Positioned(
                  left: Insets.md,
                  bottom: Insets.md,
                  child: Text(
                    block.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      shadows: const [
                        Shadow(blurRadius: 6, color: Colors.black54),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
  required String itemId,
  Duration startAt = Duration.zero,
  Future<List<AsrCue>?> Function(String blockKey)? loadSubtitles,
}) {
  return showDialog<Duration>(
    context: context,
    fullscreenDialog: true,
    barrierColor: Colors.black,
    builder: (_) => _InlineVideoPlayerPage(
      url: url,
      label: label,
      itemId: itemId,
      startAt: startAt,
      loadSubtitles: loadSubtitles,
    ),
  );
}

class _InlineVideoPlayerPage extends StatefulWidget {
  const _InlineVideoPlayerPage({
    required this.url,
    required this.itemId,
    required this.startAt,
    this.label,
    this.loadSubtitles,
  });

  final String url;

  /// 所属条目 id（块字幕产物装载用，block_artifacts 按 item+blockKey 查）。
  final String itemId;
  final String? label;
  final Duration startAt;

  /// 块字幕装载回调（由调用方从 [SubtitleScope] 取好传入——dialog 的 builder
  /// context 在 root Navigator，取不到页面树内的 InheritedWidget）。
  final Future<List<AsrCue>?> Function(String blockKey)? loadSubtitles;

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

  // ── 字幕轨（block-artifact-workflow.md 拍板 2：字幕→播放跳帧联动）：
  // 有块字幕产物则装载，播放中实时显示当前段文本。数据源经 [SubtitleScope]
  // 取（详情页注入），无作用域 = 无字幕轨（独立预览等场景，静默降级合理）。
  List<AsrCue> _cues = const [];
  final SubtitleMode _subtitleMode = SubtitleMode.sourceOnly;

  /// 当前播放位置对应的字幕文本（二分定位；无字幕轨 / 区间外 = null）。
  String? _cueAt(Duration pos) {
    if (_cues.isEmpty) return null;
    final s = pos.inMilliseconds / 1000;
    var lo = 0, hi = _cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final c = _cues[mid];
      if (s < c.start) {
        hi = mid - 1;
      } else if (s > c.start + (c.duration > 0 ? c.duration : 4)) {
        lo = mid + 1;
      } else {
        return c.line(_subtitleMode);
      }
    }
    return null;
  }

  Future<void> _loadSubtitles() async {
    final load = widget.loadSubtitles;
    if (load == null) return; // 无装载回调（无 scope/独立预览）无字幕轨
    try {
      final blockKey = 'local://${widget.url}';
      final cues = await load(blockKey);
      if (!mounted || cues == null || cues.isEmpty) return;
      setState(() => _cues = cues);
    } catch (e) {
      // 字幕轨是增强非必需：装载失败仅降级为无字幕，不影响播放主功能
      debugPrint('[DEGRADE] subtitle_track_load_failed url=${widget.url} error=$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
    _controller
        .initialize()
        .then((_) async {
          if (!mounted) return;
          // 带调用方的进度续播（顶级视频常驻播放器场景：点了全屏不该从头开始）
          if (widget.startAt > Duration.zero) {
            await _controller.seekTo(widget.startAt);
          }
          if (!mounted) return;
          setState(() => _ready = true);
          // 进全屏本身就是「我要看」的意图表达，就绪即自动播放
          await _controller.play();
          // 字幕轨异步装载（不阻塞起播；失败仅降级为无字幕）
          unawaited(_loadSubtitles());
        })
        .catchError((Object e) {
          debugPrint(
            '[DEGRADE] inline_video_load_failed url=${widget.url} error=$e',
          );
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
              child: Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                ),
              ),
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
                        // 字幕叠层（拍板 2：字幕→播放跳帧联动）——底部浮层，
                        // 随播放位置实时切换 cue；黑底白字描边保证可读
                        if (!_controller.value.isPlaying || _cueAt(_controller.value.position) != null)
                          Positioned(
                            left: Insets.md,
                            right: Insets.md,
                            bottom: Insets.md,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: _cueAt(_controller.value.position) == null
                                  ? const SizedBox.shrink()
                                  : Container(
                                      key: ValueKey(_cueAt(_controller.value.position)),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: Insets.sm,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(Radii.sm),
                                      ),
                                      child: Text(
                                        _cueAt(_controller.value.position)!,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: Colors.white,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
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
                ),
                // 实时进度条（点击视频手势切换播放/暂停；进度逐帧跟随监听器）
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.md,
                    vertical: Insets.sm,
                  ),
                  child: Row(
                    children: [
                      Text(
                        _fmt(_controller.value.position),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white,
                        ),
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
                                    .toDouble(),
                              ),
                          max: _controller.value.duration.inMilliseconds > 0
                              ? _controller.value.duration.inMilliseconds
                                    .toDouble()
                              : 1,
                          onChanged: (v) => _controller.seekTo(
                            Duration(milliseconds: v.round()),
                          ),
                        ),
                      ),
                      Text(
                        _fmt(_controller.value.duration),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white,
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
