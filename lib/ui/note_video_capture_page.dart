import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 便签视频直拍页（自建拍摄，2026-10-01 用户拍板「自建拍摄页＋进度环」）。
///
/// 背景：原路径拉系统相机（image_picker ACTION_VIDEO_CAPTURE +
/// EXTRA_DURATION_LIMIT），录制界面是相机 Activity，App 无法在其上叠任何
/// 进度 UI，60s 自动停「用户不可感知」。自建取景器后进度环 + 倒计时 +
/// 到点自动停全程可控，UI 与便利贴同语言。
///
/// 约束：本页只负责「拍到一段 ≤60s 的 mp4」，把文件路径 pop 回调用方；
/// 白名单/大小/时长门槛与入库一律照走作曲器既有链路（note-video.md §2），
/// 本页不做任何写库动作。
class NoteVideoCapturePage extends StatefulWidget {
  const NoteVideoCapturePage({super.key, required this.maxDuration});

  final Duration maxDuration;

  /// 返回拍得的文件路径；取消/失败返回 null。
  static Future<String?> push(
    BuildContext context, {
    required Duration maxDuration,
  }) {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => NoteVideoCapturePage(maxDuration: maxDuration),
      ),
    );
  }

  @override
  State<NoteVideoCapturePage> createState() => _NoteVideoCapturePageState();
}

class _NoteVideoCapturePageState extends State<NoteVideoCapturePage> {
  CameraController? _controller;
  String? _error;
  bool _recording = false;
  bool _finishing = false; // 到点/手动停止去重，防 double-stop CameraException
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    setState(() {
      _error = null;
      _controller = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = '设备没有可用摄像头');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(back, ResolutionPreset.high);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } on CameraException catch (e) {
      // 权限拒绝等在这里落地；给可行动文案而不是裸异常码（R1）
      final denied =
          e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt';
      if (mounted) {
        setState(() => _error =
            denied ? '缺少相机/麦克风权限，请在系统设置中允许后重试' : '相机启动失败：${e.code}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '相机启动失败：$e');
    }
  }

  Future<void> _toggleRecord() async {
    final controller = _controller;
    if (controller == null || _finishing) return;
    if (_recording) {
      await _stopAndReturn();
      return;
    }
    try {
      await controller.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (t) {
        if (!mounted) return;
        final elapsed = Duration(milliseconds: t.tick * 100);
        if (elapsed >= widget.maxDuration) {
          _stopAndReturn(); // 到点自动停（拍板：60s 自动停，进度环同步走满）
          return;
        }
        setState(() => _elapsed = elapsed);
      });
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _error = '录制启动失败：${e.code}');
      }
    }
  }

  Future<void> _stopAndReturn() async {
    if (_finishing) return;
    _finishing = true;
    _ticker?.cancel();
    try {
      final file = await _controller?.stopVideoRecording();
      if (mounted) Navigator.of(context).pop(file?.path);
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _error = '录制停止失败：${e.code}';
          _recording = false;
        });
      }
    } finally {
      _finishing = false;
      if (mounted) setState(() => _recording = false);
    }
  }

  /// 取消：录制中先停并丢弃临时文件（cache 目录下的未入库产物，防孤儿）。
  Future<void> _cancel() async {
    _ticker?.cancel();
    String? discard;
    if (_recording) {
      try {
        discard = (await _controller?.stopVideoRecording())?.path;
      } catch (_) {
        // 取消路径的停止失败不阻断返回，临时文件交系统 cache 清理
      }
    }
    if (discard != null) {
      unawaited(() async {
        try {
          final f = File(discard!);
          if (await f.exists()) await f.delete();
        } catch (e) {
          assert(() {
            // ignore: avoid_print
            print('[DEGRADE] note_video_capture_discard_failed error=$e');
            return true;
          }());
        }
      }());
    }
    if (mounted) Navigator.of(context).pop(null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_controller != null && _controller!.value.isInitialized)
            CameraPreview(_controller!)
          else if (_error == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: Colors.white)),
                    const SizedBox(height: Insets.md),
                    FilledButton(
                      onPressed: _initCamera,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: _cancel,
                    ),
                    // 倒计时文案按用户拍板（2026-10-01）移除：进度环即时间
                    // 的唯一表达，快门外圈走满 = 60s 到点自动停
                  ],
                ),
                if (_controller != null && _error == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Insets.xxl),
                    child: _shutter(scheme),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 快门：未录=启动录制；录制中=外圈进度环 + 内部方块（停）。
  Widget _shutter(ColorScheme scheme) {
    final progress =
        (_elapsed.inMilliseconds / widget.maxDuration.inMilliseconds)
            .clamp(0.0, 1.0);
    return GestureDetector(
      key: const ValueKey('note_video_shutter'),
      onTap: _toggleRecord,
      child: SizedBox(
        width: 84,
        height: 84,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 84,
              height: 84,
              child: CircularProgressIndicator(
                value: _recording ? progress : 0,
                strokeWidth: 5,
                color: scheme.primary,
                backgroundColor: Colors.white24,
              ),
            ),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _recording ? scheme.error : Colors.white,
              ),
              child: _recording
                  ? Icon(Icons.stop, color: Colors.white, size: 32)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
