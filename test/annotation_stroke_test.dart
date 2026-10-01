import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/models/annotation.dart';
import 'package:goodshare/models/annotation_geometry.dart';
import 'package:goodshare/render/annotation_painter.dart';

void main() {
  group('笔迹工具（image-markup.md §3 候选工具落地）', () {
    test('free 轨迹多点采点：命中判定走逐段线距离（§4 对象级选中）', () {
      final stroke = Annotation(
        type: AnnotationType.free,
        points: const [
          NormPoint(0.1, 0.1),
          NormPoint(0.3, 0.3),
          NormPoint(0.5, 0.2),
        ],
      );
      // 点在轨迹中段附近命中
      expect(hitObject([stroke], const NormPoint(0.3, 0.31)), stroke.id);
      // 离轨迹远不命中
      expect(hitObject([stroke], const NormPoint(0.8, 0.8)), isNull);
    });

    test('anchorsOf free = 全轨迹点（§4 锚点级可逐点调整）', () {
      final stroke = Annotation(
        type: AnnotationType.free,
        points: const [
          NormPoint(0.1, 0.1),
          NormPoint(0.3, 0.3),
          NormPoint(0.5, 0.2),
        ],
      );
      expect(anchorsOf(stroke), hasLength(3));
    });

    test('withAnchor 单点重算保持身份（拖轨迹中一点只动该点）', () {
      final stroke = Annotation(
        type: AnnotationType.free,
        points: const [NormPoint(0.1, 0.1), NormPoint(0.3, 0.3)],
      );
      final moved = withAnchor(stroke, 1, const NormPoint(0.4, 0.4));
      expect(moved.id, stroke.id);
      expect(moved.points[0].x, 0.1);
      expect(moved.points[1].x, 0.4);
    });

    test('free 渲染 drawPath 可出图（画布/loupe/导出三消费方同链路）', () async {
      final stroke = Annotation(
        type: AnnotationType.free,
        points: const [
          NormPoint(0.1, 0.1),
          NormPoint(0.3, 0.3),
          NormPoint(0.5, 0.2),
          NormPoint(0.7, 0.4),
        ],
      );
      final rec = ui.PictureRecorder();
      paintAnnotations(ui.Canvas(rec), const ui.Size(300, 200), [stroke],
          selectedId: stroke.id, anchorIndex: 1);
      final pic = rec.endRecording();
      await pic.toImage(60, 40);
      expect(pic, isNotNull);
    });
  });
}
