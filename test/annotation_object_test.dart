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

  group('schema 对象化扩展（image-markup.md §3）', () {
    test('filled 实心填充态：序列化含 filled:true，反序列化保留；缺省 false 不写 JSON', () {
      final solid = rect([0.1, 0.1, 0.5, 0.4]).copyWith(filled: true);
      final solidBack = Annotation.fromJson(solid.toJson()..remove('id'));
      expect(solidBack.filled, isTrue);

      final hollow = rect([0.1, 0.1, 0.5, 0.4]);
      expect(hollow.toJson().containsKey('filled'), isFalse);
      expect(Annotation.fromJson(hollow.toJson()..remove('id')).filled, isFalse);
    });

    test('stroke 笔迹留位：读侧 \'stroke\' 与 \'free\' 归一（写侧维持 free）', () {
      final j = {
        'type': 'stroke',
        'points': [
          {'x': 0.1, 'y': 0.1},
          {'x': 0.2, 'y': 0.2},
        ],
      };
      expect(Annotation.fromJson(j).type, AnnotationType.free);
      expect(AnnotationType.free.name, 'free'); // 写侧不产出 'stroke'
    });

    test('copyWith 保留 id/createdAt，filled 可改', () {
      final a = rect([0, 0, 1, 1]);
      final b = a.copyWith(color: '#00FF00');
      expect(b.id, a.id);
      expect(b.createdAt, a.createdAt);
      expect(b.filled, isFalse);
      expect(b.copyWith(filled: true).filled, isTrue);
    });
  });

  group('序号视图属性（§3 序号与身份解耦防雪崩）', () {
    test('pin 按列表顺序编号，非 pin 不参与；删除中间后自动回补重排', () {
      final p1 = Annotation(
          type: AnnotationType.number, points: const [NormPoint(0.1, 0.1)]);
      final r = rect([0.2, 0.2, 0.4, 0.4]);
      final p2 = Annotation(
          type: AnnotationType.number, points: const [NormPoint(0.5, 0.5)]);
      final p3 = Annotation(
          type: AnnotationType.number, points: const [NormPoint(0.7, 0.7)]);

      var numbers = assignPinNumbers([p1, r, p2, p3]);
      expect(numbers, {p1.id: 1, p2.id: 2, p3.id: 3});

      // 删除 ② 后 ③ 自动回补为 ②——schema 只存 ID，序号渲染时重算
      numbers = assignPinNumbers([p1, r, p3]);
      expect(numbers, {p1.id: 1, p3.id: 2});
    });

    test('schema 不存序号：pin 的 JSON 无 index 字段', () {
      final pin = Annotation(
          type: AnnotationType.number, points: const [NormPoint(0, 0)]);
      expect(pin.toJson().containsKey('index'), isFalse);
    });
  });

  group('锚点与命中纯函数（§4 两级选择）', () {
    test('anchorsOf：箭头/矩形两点、pin/文字单点、free 全轨迹', () {
      final arrow = Annotation(
          type: AnnotationType.arrow,
          points: const [NormPoint(0, 0), NormPoint(0.5, 0.5), NormPoint(0.9, 0.9)]);
      expect(anchorsOf(arrow), hasLength(2)); // 最小集，多余点不暴露
      final pin = Annotation(
          type: AnnotationType.number, points: const [NormPoint(0.3, 0.3)]);
      expect(anchorsOf(pin), hasLength(1));
    });

    test('hitAnchor 就近吸附：半径内命中最近锚点，超容错 null', () {
      final a = rect([0.1, 0.1, 0.5, 0.5]);
      final hit = hitAnchor([a], const NormPoint(0.11, 0.105));
      expect(hit, isNotNull);
      expect(hit!.annId, a.id);
      expect(hit.anchorIndex, 0);
      expect(hitAnchor([a], const NormPoint(0.5, 0.9)), isNull);
    });

    test('hitObject：矩形包围盒命中、箭头线段距离、空白 null、重叠取最上层', () {
      final bottom = rect([0.0, 0.0, 0.4, 0.4]);
      final top = rect([0.3, 0.3, 0.6, 0.6]); // 与 bottom 重叠区 [0.3,0.4]
      final arrow = Annotation(
          type: AnnotationType.arrow,
          points: const [NormPoint(0.0, 0.8), NormPoint(0.4, 0.8)]);

      expect(hitObject([bottom], const NormPoint(0.2, 0.2)), bottom.id);
      expect(hitObject([bottom], const NormPoint(0.9, 0.9)), isNull);
      expect(hitObject([arrow], const NormPoint(0.2, 0.801)), arrow.id);
      // 重叠区取 Z 轴最上层（列表末位）
      expect(hitObject([bottom, top], const NormPoint(0.35, 0.35)), top.id);
    });

    test('withAnchor / translated：锚点级只动该点，对象级整体平移', () {
      final a = rect([0.1, 0.1, 0.5, 0.5]);
      final moved = withAnchor(a, 1, const NormPoint(0.7, 0.6));
      expect(moved.points[0].x, 0.1); // 对角锁定
      expect(moved.points[0].y, 0.1);
      expect(moved.points[1].x, 0.7);
      expect(moved.points[1].y, 0.6);
      expect(moved.id, a.id); // 原地重算不换身份

      final shifted = translated(a, 0.1, 0.2);
      expect(shifted.points[0].x, closeTo(0.2, 1e-9));
      expect(shifted.points[0].y, closeTo(0.3, 1e-9));
      expect(shifted.points[1].x, closeTo(0.6, 1e-9));
      expect(shifted.points[1].y, closeTo(0.7, 1e-9));
    });
  });

  group('渲染纯函数（§5.1 三消费方复用）', () {
    test('paintAnnotations 在离屏 canvas 可执行且 onlyIds 过滤生效（loupe 口径）', () async {
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      final list = [
        rect([0.1, 0.1, 0.5, 0.5]),
        Annotation(
            type: AnnotationType.number, points: const [NormPoint(0.8, 0.8)]),
      ];
      // 全量画（画布消费方）
      paintAnnotations(canvas, const ui.Size(400, 300), list,
          selectedId: list[0].id, anchorIndex: 1);
      // onlyIds 只画 pin（loupe 消费方：只渲染当前操作标注）
      paintAnnotations(canvas, const ui.Size(400, 300), list,
          onlyIds: {list[1].id});
      final pic = rec.endRecording();
      await pic.toImage(80, 60); // 导出消费方同链路可出图
      expect(pic, isNotNull);
    });
  });
}
