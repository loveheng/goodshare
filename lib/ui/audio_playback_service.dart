import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../share/attachments.dart' show resolveLocalMediaSrc;

/// 页面级音频播放服务（单实例红线，SSOT：docs/design/rich-text-media.md §3）。
///
/// 严禁在 SliverList 块 widget 内实例化 `AudioPlayer`——长列表每个音频条各持
/// 一个播放器会击穿内存水位。本服务由调用层（详情页）State 持有唯一控制器，
/// 经 [AudioPlaybackService] InheritedWidget 下发；块 widget 只订阅状态、
/// 不持有播放器。块 widget 被滑出缓存区 dispose 时调 [AudioPlaybackController.release]，
/// 正在播的块自动暂停——sliver 回收即停，内存红线由机制保证而非纪律约定。
///
/// 对 `AudioPlayer` 的依赖收敛在 [AudioPlayerHandle] 接口之后，测试注入 fake
/// 统计实例数（§7 验收）。
abstract class AudioPlayerHandle {
  /// 加载音源（http(s) 网络源或本地文件路径），返回时长；失败抛异常。
  Future<Duration?> load(String source);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 播放状态/进度流（控制器订阅后向块 widget 广播）。
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;

  void disposeHandle();
}

/// [AudioPlayerHandle] 的 just_audio 实现（生产唯一出口）。
class JustAudioHandle implements AudioPlayerHandle {
  final AudioPlayer _player = AudioPlayer();

  JustAudioHandle() {
    // 播完自然停止：回零待重播（与旧 _AudioPlayer 行为一致）
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  @override
  Future<Duration?> load(String source) {
    // local://（便签行内媒体）在此统一解析为绝对路径——播放链路的唯一收口
    final src = resolveLocalMediaSrc(source);
    final scheme = Uri.tryParse(src)?.scheme;
    if (scheme == 'http' || scheme == 'https') return _player.setUrl(src);
    return _player.setFilePath(src);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream =>
      _player.playerStateStream.map((s) => s.playing);

  @override
  void disposeHandle() => _player.dispose();
}

/// 播放控制器：唯一句柄 + 当前播放块。ChangeNotifier 暴露状态给块 widget。
class AudioPlaybackController extends ChangeNotifier {
  AudioPlaybackController({AudioPlayerHandle? handle}) {
    _handle = handle ?? JustAudioHandle();
    _subs = [
      _handle.positionStream.listen((p) {
        _position = p;
        notifyListeners();
      }),
      _handle.durationStream.listen((d) {
        _duration = d ?? Duration.zero;
        notifyListeners();
      }),
      _handle.playingStream.listen((playing) {
        _playing = playing;
        notifyListeners();
      }),
    ];
  }

  late final AudioPlayerHandle _handle;
  List<StreamSubscription<dynamic>> _subs = const [];

  /// 当前播放（或最近激活）的块 id；null = 空闲。
  String? activeBlockId;

  bool _playing = false;
  bool get playing => _playing;

  Duration _position = Duration.zero;
  Duration get position => _position;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  /// 当前块的加载/播放错误（仅 active 块显示）。
  String? error;

  bool isActive(String blockId) => activeBlockId == blockId;

  /// 点按某播放条：播它 → 暂停它；播别的 → 自动切歌（单实例天然互斥）。
  Future<void> toggle(String blockId, String source) async {
    if (isActive(blockId)) {
      if (_playing) {
        await _handle.pause();
      } else {
        await _handle.play();
      }
      return;
    }
    await _activate(blockId, source);
  }

  Future<void> seek(Duration position) => _handle.seek(position);

  Future<void> _activate(String blockId, String source) async {
    try {
      error = null;
      activeBlockId = blockId;
      _position = Duration.zero;
      _duration = await _handle.load(source) ?? Duration.zero;
      notifyListeners();
      await _handle.play();
    } catch (e) {
      debugPrint('[DEGRADE] audio_playback_load_failed source=$source error=$e');
      error = '音频加载失败';
      _playing = false;
      notifyListeners();
    }
  }

  /// 块 widget dispose（滑出缓存区）时调用：正在播的块自动暂停。
  void release(String blockId) {
    if (!isActive(blockId)) return;
    unawaited(_handle.pause());
    _playing = false;
    activeBlockId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _handle.disposeHandle();
    super.dispose();
  }
}

/// InheritedWidget 下发（调用层 State 持有 controller，离开页面即释放）。
class AudioPlaybackService extends StatefulWidget {
  const AudioPlaybackService({
    super.key,
    required this.controller,
    required this.child,
  });

  final AudioPlaybackController controller;
  final Widget child;

  /// 取页面级播放控制器；不在服务作用域内（如编辑器 dialog 未透传、预览场景）
  /// 返回 null——调用方降级为不可播放的静态呈现，绝不自行实例化播放器。
  static AudioPlaybackController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AudioPlaybackScope>()?.controller;

  @override
  State<AudioPlaybackService> createState() => _AudioPlaybackServiceState();
}

class _AudioPlaybackServiceState extends State<AudioPlaybackService> {
  @override
  Widget build(BuildContext context) {
    return _AudioPlaybackScope(
      controller: widget.controller,
      child: widget.child,
    );
  }
}

class _AudioPlaybackScope extends InheritedWidget {
  const _AudioPlaybackScope({required this.controller, required super.child});

  final AudioPlaybackController controller;

  @override
  bool updateShouldNotify(_AudioPlaybackScope oldWidget) =>
      controller != oldWidget.controller;
}
