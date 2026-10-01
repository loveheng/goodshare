import 'package:flutter/material.dart';

import '../models/item.dart';
import 'image_annotator.dart';

/// 全屏图片标注编辑页（detail-two-zone.md §5.2 拍板 2026-10-01：标注从
/// 二级页内联迁移至三级能力页「独立能力」入口）。
///
/// 人机工程依据：标注是全聚焦编辑任务（画布+工具栏+对象列表），全屏 =
/// 精确触控操作面最大化，且不打断二级页阅读上下文——「看在二级、动在
/// 三级」统一心智。`ImageAnnotator` 为自包含编辑宿主，整体迁入零业务改动。
Future<void> showAnnotationEditorPage(
  BuildContext context, {
  required InboxItem item,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _AnnotationEditorPage(item: item),
    ),
  );
}

class _AnnotationEditorPage extends StatelessWidget {
  const _AnnotationEditorPage({required this.item});

  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        title: const Text('图片标注'),
      ),
      body: SafeArea(child: ImageAnnotator(item: item)),
    );
  }
}
