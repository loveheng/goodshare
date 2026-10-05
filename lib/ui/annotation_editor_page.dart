import 'package:flutter/material.dart';

import '../models/item.dart';
import 'image_annotator.dart';

/// 全屏图片标注编辑页（detail-two-zone.md §5.2 拍板 2026-10-01：标注从
/// 二级页内联迁移至三级能力页「独立能力」入口）。
///
/// 人机工程依据：标注是全聚焦编辑任务，全屏 = 精确触控操作面最大化，且不
/// 打断二级页阅读上下文——「看在二级、动在三级」统一心智。页面骨架
/// （AppBar+导出）由 `ImageAnnotator` 自持——画布全屏悬浮形态下悬浮件的
/// 瞬隐/浮层与 AppBar 动作同属一个交互态，拆两层反而要跨组件传状态。
Future<void> showAnnotationEditorPage(
  BuildContext context, {
  required InboxItem item,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ImageAnnotator(item: item),
    ),
  );
}
