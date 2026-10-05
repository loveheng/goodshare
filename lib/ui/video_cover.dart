import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media/media_toolkit.dart';
import '../share/attachments.dart' show resolveLocalMediaSrc;

/// 视频封面帧提取缓存（url → JPEG 字节）：失败（null）同样缓存——坏文件不
/// 反复重试；进程级缓存即可（封面内容恒定，无失效语义）。
final Map<String, Uint8List?> _coverCache = {};
final Map<String, Future<Uint8List?>> _inflight = {};

final MediaToolkit _toolkit = MethodChannelMediaToolkit();

/// 视频封面（2026-10-03 拍板「视频加封面」）：原生提帧（MediaBridge
/// videoCover，MediaMetadataRetriever 首帧 JPEG），按 url 进程级缓存。
/// [bytesOrNull] 交给调用方渲染——null（提取失败/文件丢失/测试环境无
/// 平台实现）由调用方回落图标占位，契约与探测 null 非阻断一致。
class VideoCoverImage extends StatefulWidget {
  const VideoCoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
  });

  /// 视频行内 url（`local://` 相对标记）。
  final String url;

  final BoxFit fit;

  @override
  State<VideoCoverImage> createState() => _VideoCoverImageState();
}

class _VideoCoverImageState extends State<VideoCoverImage> {
  Uint8List? _bytes;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _coverCache[widget.url];
    if (cached != null || _coverCache.containsKey(widget.url)) {
      if (!mounted) return;
      setState(() {
        _bytes = cached;
        _done = true;
      });
      return;
    }
    final future =
        _inflight.putIfAbsent(widget.url, () => _extract(widget.url));
    final bytes = await future;
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _done = true;
    });
  }

  Future<Uint8List?> _extract(String url) async {
    try {
      final file = File(resolveLocalMediaSrc(url));
      if (!await file.exists()) {
        _coverCache[url] = null;
        return null;
      }
      final bytes = await _toolkit.videoCover(file.path);
      _coverCache[url] = bytes;
      return bytes;
    } catch (_) {
      _coverCache[url] = null;
      return null;
    } finally {
      _inflight.remove(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_done) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return Icon(
        Icons.play_circle_fill,
        size: 48,
        color: Theme.of(context).colorScheme.primary,
      );
    }
    return Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
  }
}
