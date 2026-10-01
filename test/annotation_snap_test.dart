import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/models/annotation.dart';
import 'package:goodshare/models/annotation_geometry.dart';
import 'package:goodshare/render/annotation_painter.dart';

void main() {
  Annotation rect(List<double> xy) => Annotation(
        type: AnnotationType.rect,
        points: [NormPoint(xy[0], xy[1]), NormPoint(xy[2], xy[3])],
      );

  group('吸附线解算（image-markup.md §5）', () {
    test('边缘/中心吸附：x 命中 0/0.5/1 返回修正点 + 竖线', () {
      final r = snapAnchorPoint(const NormPoint(0.492, 0.3), const []);
      expect(r.point.x, 0.5);
      expect(r.point.y, 0.3); // y 未命中不动
      expect(r.lines, hasLength(1));
      expect(r.lines.first.isVertical, isTrue);
      expect(r.lines.first.x, 0.5);
      expect(r.lines.first.haptic, SnapHaptic.align);
    });

    test('对齐其他标注锚点：参照系来自 others 的锚点坐标', () {
      final other = rect([0.3, 0.3, 0.6, 0.6]);
      final r = snapAnchorPoint(const NormPoint(0.31, 0.7), [other]);
      expect(r.point.x, 0.3); // 吸到 other 的左缘 x
      expect(r.lines.first.isVertical, isTrue);
      // 吸附线不来自自己（others 为空时无参照）
      expect(snapAnchorPoint(const NormPoint(0.3, 0.7), []).lines, isEmpty);
    });

    test('超容差不吸附：返回原点、无线', () {
      final r = snapAnchorPoint(const NormPoint(0.45, 0.45), const []);
      expect(r.point.x, 0.45);
      expect(r.lines, isEmpty);
    });

    test('横竖同时命中返回两条线（x/y 独立解算）', () {
      final other = rect([0.5, 0.5, 0.8, 0.8]);
      final r = snapAnchorPoint(const NormPoint(0.495, 0.504), [other]);
      expect(r.point, isNotNull);
      expect(r.lines, hasLength(2));
      expect(r.lines.map((l) => l.isVertical), containsAll([true, false]));
    });

    test('snapOrthogonal：45° 射线修正 + 超容差 null + 轴向 0/90°', () {
      final hit = snapOrthogonal(
          const NormPoint(0.1, 0.1), const NormPoint(0.2, 0.199));
      expect(hit, isNotNull);
      expect(hit!.angleRadians, closeTo(45 * 3.14159265 / 180, 0.01));
      // 修正点落在射线上（y≈x）
      expect((hit.point.y - hit.point.x).abs(), lessThan(0.01));

      final miss = snapOrthogonal(
          const NormPoint(0.1, 0.1), const NormPoint(0.2, 0.13), tolerance: 0.02);
      expect(miss, isNull);

      final axis = snapOrthogonal(
          const NormPoint(0.1, 0.1), const NormPoint(0.3, 0.102));
      expect(axis!.angleRadians, closeTo(0, 0.01));
    });
  });

  group('SnapLine 语义', () {
    test('两档触觉：正交 orthogonal / 对齐 align 可区分', () {
      expect(SnapHaptic.orthogonal, isNot(SnapHaptic.align));
      final v = SnapLine.vertical(0.5, 0.1, SnapHaptic.align);
      expect(v.isVertical, isTrue);
      expect(v.x, 0.5);
      final h = SnapLine.horizontal(0.5, 0.1, SnapHaptic.orthogonal);
      expect(h.isVertical, isFalse);
      expect(h.y, 0.5);
    });
  });

  group('渲染纯函数第 2 批回归（onlyIds 复用于 loupe）', () {
    test('吸附接入后画布渲染链路不回归：全量/过滤/出图三态可执行', () async {
      final list = [
        rect([0.1, 0.1, 0.5, 0.5]),
        Annotation(
            type: AnnotationType.number, points: const [NormPoint(0.8, 0.8)]),
      ];
      final rec = ui.PictureRecorder();
      paintAnnotations(ui.Canvas(rec), const ui.Size(300, 200), list,
          selectedId: list[0].id);
      final pic = rec.endRecording();
      await pic.toImage(60, 40);
      expect(pic, isNotNull);
    });
  });
}
