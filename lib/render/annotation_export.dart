/// 标注导出合成（image-markup.md §7「导出成图时才瞬时合成」）：
/// PictureRecorder 离屏 Canvas——先画 Image，再遍历 annotations 走
/// [paintAnnotations] 同一纯函数（三消费方纪律的第三消费方兑现），
/// `toImage()` 出 PNG。产物为**新文件**，原条目数据（原图+annotations）不动。
///
/// 复用 `AnnotationStore` 的目录纪律落 `documents/annotations/export/`；
/// UI 不做像素合成（goodshare-arch：重 IO 下沉非 UI 层）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/annotation.dart';
import 'annotation_painter.dart';

/// 合成导出图：读原图 → 离屏画（原图 + 全部标注，无选中态/吸附线）→
/// PNG 写盘。返回产物文件路径；解码失败等异常原样抛出（调用方弹错，
/// 不静默降级——产物缺失必须被用户感知）。
Future<String> exportCompositedImage({
  required String imagePath,
  required List<Annotation> annotations,
  int maxSide = 2048,
}) async {
  final bytes = await File(imagePath).readAsBytes();
  final src = await decodeImageFromList(bytes);

  // 限边长：长边超 [maxSide] 等比缩（导出图是分享产物，不需要原分辨率）。
  final w = src.width, h = src.height;
  final scale = w > maxSide || h > maxSide ? maxSide / (w > h ? w : h) : 1.0;
  final outW = (w * scale).round(), outH = (h * scale).round();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // fit: fill 与画布显示口径一致（横竖屏画布同宽高比拉伸）
  canvas.scale(outW / w, outH / h);
  canvas.drawImage(src, ui.Offset.zero, ui.Paint());
  paintAnnotations(canvas, ui.Size(w.toDouble(), h.toDouble()), annotations);
  final pic = recorder.endRecording();
  final out = await pic.toImage(outW, outH);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  src.dispose();
  out.dispose();
  pic.dispose();
  if (data == null) throw StateError('导出合成图编码失败');

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'annotations', 'export'));
  await dir.create(recursive: true);
  final name =
      'anno_${DateTime.now().millisecondsSinceEpoch}_${InboxItemId.newExportId()}.png';
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(data.buffer.asUint8List());
  return file.path;
}

/// 导出文件名安全 id（避免依赖 InboxItem 内部 id 生成器）。
class InboxItemId {
  static String newExportId() =>
      DateTime.now().microsecondsSinceEpoch.remainder(1 << 32).toRadixString(36);
}
