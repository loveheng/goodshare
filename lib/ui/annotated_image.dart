import 'dart:io';

import 'package:flutter/material.dart';

import '../models/annotation.dart';
import 'annotation_overlay_view.dart';
import 'goodshare_image.dart';

/// 常态标注叠加图（2026-10-06 拍板：标注不再「点进编辑页才可见」）。
///
/// 把 [AnnotationOverlayView] 叠加到图片之上，让标注在只读态（列表卡片 /
/// 二级详情页 / 三级全屏查看）也常驻可见——所见即编辑态标注，无需点进编辑器。
/// 复用 [AnnotationStore] 同一落盘纪律 + [paintAnnotations] 同一纯函数（
/// image-markup.md §5.1 三消费方复用纪律），与编辑/导出零漂移。
///
/// 对齐纪律（关键）：容器严格按图自身宽高比（[AspectRatio]），底图
/// `BoxFit.cover` 在等比容器里即满铺无 letterbox，叠加层 `Positioned.fill`
/// 与底图同尺寸，归一化坐标零漂移。图宽高比优先用调用方显式传入（顶级条目
/// `item.aspectRatio`），未传则首帧探测回填（网络图 / 无比例条目）。
///
/// 无标注（文件不存在）时 [AnnotationOverlayView] 零渲染，列表滚动零开销。
class AnnotatedImage extends StatefulWidget {
  const AnnotatedImage({
    super.key,
    required this.itemId,
    this.blockKey,
    this.file,
    this.networkUrl,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.placeholderColor,
    this.errorBuilder,
    this.aspectRatio,
  }) : assert(
          (file == null) != (networkUrl == null),
          'file 与 networkUrl 二选一',
        );

  /// 标注归属条目 id（与编辑页 [AnnotationStore] 同口径）。
  final String itemId;

  /// 行内块 key（null = 顶级 'item'，[AnnotationStore] 同口径）。
  final String? blockKey;

  final File? file;
  final String? networkUrl;

  /// 仅当容器宽高比 == 图宽高比时 cover/fill 才不裁不漏；本组件强制等比容器，
  /// 故 cover 即满铺，contain 亦等价满铺。
  final BoxFit fit;

  /// 解码降采样宽（显存红线，与 [GoodshareImage] 同口径）。
  final int? cacheWidth;

  /// 解码完成前占位底色（V3 主色调，消灭白闪）。
  final Color? placeholderColor;

  final ImageErrorWidgetBuilder? errorBuilder;

  /// 显式图宽高比；为空则首帧探测填入（session 级缓存）。
  final double? aspectRatio;

  @override
  State<AnnotatedImage> createState() => _AnnotatedImageState();
}

class _AnnotatedImageState extends State<AnnotatedImage> {
  static const double _defaultRatio = 4 / 3;

  /// session 级 url/path → 宽高比（double 内存可忽略，无需 LRU）。
  static final Map<String, double> _ratioCache = {};

  double get _ratio =>
      widget.aspectRatio ?? _ratioCache[_cacheKey] ?? _defaultRatio;

  String get _cacheKey =>
      widget.networkUrl ?? widget.file?.path ?? widget.itemId;

  bool get _isLocal => widget.networkUrl == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenFirstFrame();
  }

  /// 首帧探测真实宽高比：与 [InlineMediaImage] 同口径，复用同一 ImageStream
  /// （同 provider key）不产生二次加载；探测到即回填并定版 [AspectRatio]。
  void _listenFirstFrame() {
    if (widget.aspectRatio != null) return; // 显式比例优先，免探测
    final key = _cacheKey;
    if (_ratioCache.containsKey(key)) return;
    final provider = _isLocal
        ? FileImage(widget.file!)
        : NetworkImage(widget.networkUrl!);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width;
        final h = info.image.height;
        if (w > 0 && h > 0) {
          _ratioCache[key] = w / h;
          if (mounted) setState(() {});
        }
        stream.removeListener(listener);
      },
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = _isLocal
        ? GoodshareImage(
            file: widget.file!,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            placeholderColor: widget.placeholderColor,
            errorBuilder: widget.errorBuilder ??
                (_, _, _) => Center(
                      child: Icon(Icons.broken_image_outlined,
                          size: 40, color: scheme.outline),
                    ),
          )
        : GoodshareImage.network(
            url: widget.networkUrl!,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            errorBuilder: widget.errorBuilder,
          );
    // 等比容器（图宽高比）→ cover 满铺无 letterbox；叠加层与之同尺寸对齐。
    return AspectRatio(
      aspectRatio: _ratio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          // 常态标注叠加：无标注自动零渲染（SizedBox.shrink）。
          AnnotationOverlayView(itemId: widget.itemId, blockKey: widget.blockKey),
        ],
      ),
    );
  }
}
