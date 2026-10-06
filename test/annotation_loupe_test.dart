import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/annotation_loupe.dart';

void main() {
  group('loupeTransform（放大镜取景矩阵，2026-10-06 修指向偏差）', () {
    const m = 2.0;
    const r = 56.0;

    test('笔点恒映射到镜心（十字准星所指=手指下方真实画布点）', () {
      final t = loupeTransform(const Offset(200, 150), r, m);
      final p = MatrixUtils.transformPoint(t, const Offset(200, 150));
      expect(p, const Offset(r, r));
    });

    test('放大恒定 m 倍且不镜像（X 向右、Y 向下与画布同向）', () {
      final t = loupeTransform(Offset.zero, r, m);
      final origin = MatrixUtils.transformPoint(t, Offset.zero);
      expect(origin, const Offset(r, r)); // 笔点=画布原点 → 镜心
      final right = MatrixUtils.transformPoint(t, const Offset(10, 0));
      final down = MatrixUtils.transformPoint(t, const Offset(0, 10));
      expect(right.dx, greaterThan(origin.dx));
      expect(down.dy, greaterThan(origin.dy));
    });

    test('镜内位移 = m × 画布位移（线性，无中心裁切偏置）', () {
      final t = loupeTransform(const Offset(100, 100), r, m);
      final a = MatrixUtils.transformPoint(t, const Offset(110, 100));
      final b = MatrixUtils.transformPoint(t, const Offset(100, 100));
      expect((a - b).distance, m * 10);
    });
  });
}
