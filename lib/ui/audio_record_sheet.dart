import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../share/attachments.dart';
import 'tokens.dart';

/// 录音弹框（2026-10-03 拍板：速记条与详情页编辑**统一**录音入口，形态对齐
/// 用户参考稿）：语言选择不在本框——转写语言走 ASR 模型档位（asr.dart SSOT），
/// 「随条目带语言」的管线未建，不做假 UI。
///
/// 交互：打开即录（已申请麦克风权限）；暂停/继续；橙色停止=完成并回传落盘
/// 路径；右上 ×=丢弃（停录并删半成品文件）；最长 5 分钟自动停止。
/// 返回值：录音文件路径（null = 取消/丢弃）。
///
/// 产物路径由本组件写入应用分享目录（与速记条旧直录路径同源），调用方拿到
/// 路径后自行 toLocalMediaUrl + 插入/替换。
Future<String?> showAudioRecordSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const AudioRecordSheet(),
  );
}

/// 录音单次时长上限（参考稿 05:00 定标）。
const Duration kAudioRecordMaxDuration = Duration(minutes: 5);

class AudioRecordSheet extends StatefulWidget {
  const AudioRecordSheet({super.key});

  @override
  State<AudioRecordSheet> createState() => _AudioRecordSheetState();
}

class _AudioRecordSheetState extends State<AudioRecordSheet> {
  final _recorder = AudioRecorder();
  final _stopwatch = Stopwatch();
  Timer? _tick;
  StreamSubscription<RecordState>? _stateSub;
  StreamSubscription<Amplitude>? _ampSub;

  RecordState? _state;
  String? _path;
  bool _settling = false; // 停止/丢弃流程中，防重复触发与 dispose 二次停录

  /// 振幅历史（0~1 归一，新样本在尾部），驱动波形点阵；长度随绘制点数裁剪。
  final List<double> _amps = [];

  @override
  void initState() {
    super.initState();
    // 首帧后再起录：_start 内用 ScaffoldMessenger.of（inherited 依赖在
    // initState 完成前不可用，直接调会抛异常且弹框永不出现——真机实证）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _stateSub?.cancel();
    _ampSub?.cancel();
    // 异常路径兜底（弹层被系统回收）：仍在录则停录并清半成品，不留僵尸文件
    if (!_settling && _path != null && _state != RecordState.stop) {
      _recorder.stop().then((p) {
        if (p != null) unawaited(_deleteQuietly(p));
      }).catchError((Object _) {
        debugPrint('[DEGRADE] audio_record_dispose_stop: 忽略（弹层回收竞态）');
      });
    }
    _recorder.dispose();
    super.dispose();
  }

  /// 半成品清理（尽力而为）：删除失败只留痕不阻断（临时文件，泄漏无害）。
  Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (e) {
      debugPrint('[DEGRADE] audio_record_cleanup: 半成品删除失败 $e');
    }
  }

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await _recorder.hasPermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('缺少麦克风权限')));
      if (mounted) Navigator.of(context).pop();
      return;
    }
    try {
      final dir = await appShareDir();
      final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      // **订阅必须先于 start**：插件振幅监测由状态流驱动（record 事件才启动
      // monitoring），start 后订阅会错过初始 record 事件 → 波形全平、计时哑火
      //（真机实证：面板停在 00:00、点按无响应观感「没有开始录音」）。
      _stateSub = _recorder.onStateChanged().listen(_onRecordState);
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((a) {
        if (!mounted) return;
        setState(() {
          // dBFS（-160~0，常驻 -45 以下≈静音）→ 0~1
          _amps.add((1 + a.current / 45).clamp(0.0, 1.0));
          if (_amps.length > _maxAmpSamples) _amps.removeAt(0);
        });
      });
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      _path = path;
      _onRecordState(RecordState.record); // 乐观置态起表（平台事件作同步备份）
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        if (_stopwatch.elapsed >= kAudioRecordMaxDuration) {
          _finish();
          return;
        }
        setState(() {}); // 计时刷新
      });
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('录音启动失败：$e')));
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// 状态迁移：暂停/继续与计时同源（仅录制中走表）；Stopwatch.start 幂等。
  void _onRecordState(RecordState s) {
    if (!mounted) return;
    setState(() => _state = s);
    if (s == RecordState.record) {
      _stopwatch.start();
    } else {
      _stopwatch.stop();
    }
  }

  /// 停止并回传路径（完成语义）。
  Future<void> _finish() async {
    if (_settling) return;
    _settling = true;
    _tick?.cancel();
    final path = await _recorder.stop();
    if (!mounted) return;
    if (path == null) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(path);
  }

  /// 停止并丢弃半成品（× 语义），不留孤儿音频文件。
  Future<void> _discard() async {
    if (_settling) return;
    _settling = true;
    _tick?.cancel();
    HapticFeedback.lightImpact();
    final path = await _recorder.stop();
    if (path != null) {
      unawaited(_deleteQuietly(path));
    }
    if (mounted) Navigator.of(context).pop();
  }

  String get _elapsedLabel {
    final s = _stopwatch.elapsed.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String get _maxLabel {
    final s = kAudioRecordMaxDuration.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paused = _state == RecordState.pause;
    final recording = _state == RecordState.record;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.sm, Insets.sm),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.xl),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Spacer(),
                    // ×= 丢弃录音（半成品即删，不留孤儿文件）
                    IconButton(
                      tooltip: '丢弃录音',
                      onPressed: _discard,
                      icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _elapsedLabel,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(color: scheme.onSurface),
                      ),
                      TextSpan(
                        text: ' / $_maxLabel',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.lg),
                SizedBox(
                  height: 96,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _WavePainter(
                      amps: _amps,
                      lineColor: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                      playheadColor: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 暂停/继续（灰圆）；未起录前置灰禁用
                    _RoundAction(
                      size: 72,
                      onPressed: recording || paused
                          ? () async {
                              HapticFeedback.lightImpact();
                              if (paused) {
                                await _recorder.resume();
                              } else {
                                await _recorder.pause();
                              }
                            }
                          : null,
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: scheme.onSurface,
                      child: Icon(
                        paused ? Icons.play_arrow : Icons.pause,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: Insets.xl),
                    // 停止=完成并插入（橙圆，主 CTA）
                    _RoundAction(
                      size: 72,
                      onPressed: recording || paused ? _finish : null,
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      child: Icon(Icons.stop, size: 34),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 波形历史点数上限：屏宽/6dp 间距的经验值，超出即左移丢弃（滚动波形）。
  static const int _maxAmpSamples = 56;
}

/// 圆形动作钮（录音弹框控件）。
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.size,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.child,
  });

  final double size;
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: backgroundColor,
          disabledBackgroundColor: backgroundColor.withValues(alpha: 0.4),
          foregroundColor: foregroundColor,
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        child: child,
      ),
    );
  }
}

/// 波形点阵：中线基线点铺满全宽，左段（已录区间）按振幅历史长高，
/// 中央播放头标当前位置（形态对齐参考稿）。颜色由宿主传主题槽位值。
class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.amps,
    required this.lineColor,
    required this.playheadColor,
  });

  final List<double> amps;
  final Color lineColor;
  final Color playheadColor;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    const spacing = 6.0;
    final count = (size.width / spacing).floor();
    final center = count ~/ 2;
    final dot = Paint()
      ..color = lineColor
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final x = i * spacing + spacing / 2;
      double h = 2.5;
      if (i < center && amps.isNotEmpty) {
        // 已录区间：距播放头越近样本越新（尾部）
        final back = center - i;
        final idx = amps.length - back;
        if (idx >= 0) h = 3 + amps[idx] * 60;
      }
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), dot);
    }
    // 播放头
    canvas.drawLine(
      Offset(center * spacing + spacing / 2, mid - 34),
      Offset(center * spacing + spacing / 2, mid + 34),
      Paint()
        ..color = playheadColor
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.amps.length != amps.length ||
      old.lineColor != lineColor ||
      old.playheadColor != playheadColor;
}
