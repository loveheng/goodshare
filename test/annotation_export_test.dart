import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/models/annotation.dart';
import 'package:goodshare/models/annotation_geometry.dart';
import 'package:goodshare/render/annotation_export.dart';
import 'package:goodshare/render/annotation_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 测试环境无平台通道：path_provider 落系统临时目录（导出目录纪律
    // documents/annotations/export 在测试里映射为 tmp/…/documents 同构验证）。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final tmp = await Directory.systemTemp.createTemp('anno_export_docs');
      return '${tmp.path}/documents';
    });
  });

  Annotation rect(List<double> xy, {bool filled = false}) => Annotation(
        type: AnnotationType.rect,
        points: [NormPoint(xy[0], xy[1]), NormPoint(xy[2], xy[3])],
        filled: filled,
      );

  group('隐私遮挡（image-markup.md §3 filled 实心态）', () {
    test('filled=true 渲染走 fill 分支可出图（遮挡=纯色色块）', () async {
      final solid = rect([0.1, 0.1, 0.5, 0.5], filled: true);
      final rec = ui.PictureRecorder();
      paintAnnotations(ui.Canvas(rec), const ui.Size(300, 200), [solid],
          selectedId: solid.id);
      final pic = rec.endRecording();
      final img = await pic.toImage(60, 40);
      expect(img.width, 60);
    });

    test('filled Toggle 数据面：copyWith 空心↔实心往返', () {
      final a = rect([0, 0, 1, 1]);
      expect(a.filled, isFalse);
      expect(a.copyWith(filled: true).filled, isTrue);
      expect(a.copyWith(filled: true).copyWith(filled: false).filled, isFalse);
    });

    test('安全边界语义：filled 只是展示属性——原图与 annotations 数据不变', () {
      // 打码是「展示级遮挡非数据级销毁」：导出合成走 paintAnnotations 新画布，
      // 原条目（原图文件 + annotations JSON）不经任何修改——此处锁 schema 面：
      // filled 不改变 points/type，反序列化后原图数据仍完整。
      final solid = rect([0.1, 0.1, 0.5, 0.5], filled: true);
      final back = Annotation.fromJson(solid.toJson()..remove('id'));
      expect(back.type, AnnotationType.rect);
      expect(back.points, hasLength(2));
      expect(back.points[0].x, 0.1);
    });
  });

  group('文字标注（§7）', () {
    test('带文字标注渲染：TextPainter 动态宽高 + 底框可出图', () async {
      final t = Annotation(
        type: AnnotationType.text,
        points: const [NormPoint(0.1, 0.1)],
        text: '这是一条比较长的说明文字会被 maxWidth 约束换行',
      );
      final rec = ui.PictureRecorder();
      paintAnnotations(ui.Canvas(rec), const ui.Size(300, 200), [t]);
      final pic = rec.endRecording();
      await pic.toImage(60, 40);
      expect(pic, isNotNull);
    });

    test('空文字/无点不渲染不抛错（防御面）', () async {
      final empty = Annotation(
          type: AnnotationType.text, points: const [NormPoint(0.2, 0.2)]);
      final noPoint = Annotation(
          type: AnnotationType.text, points: const [], text: 'x');
      final rec = ui.PictureRecorder();
      paintAnnotations(ui.Canvas(rec), const ui.Size(100, 100), [empty, noPoint]);
      final pic = rec.endRecording();
      await pic.toImage(50, 50);
      expect(pic, isNotNull);
    });

    test('文字/序号同为单锚点（tap 即生成，§3/§7）', () {
      final t = Annotation(
          type: AnnotationType.text,
          points: const [NormPoint(0.3, 0.3), NormPoint(0.6, 0.6)],
          text: 'x');
      expect(anchorsOf(t), hasLength(1)); // 最小集只暴露定位锚
    });
  });

  group('导出合成（§7 瞬时合成产物为新文件）', () {
    test('源图解码失败原样抛出（不静默降级，产物缺失必须被感知）', () async {
      await expectLater(
        exportCompositedImage(imagePath: '/nonexistent/nope.png', annotations: const []),
        throwsA(isA<PathNotFoundException>()),
      );
    });

    test('合成产物落 annotations/export/ 新文件，不触碰源图（用临时源图）', () async {
      final src = await createTestPng();
      final before = await File(src.path).stat();
      final list = [
        rect([0.1, 0.1, 0.5, 0.5], filled: true),
        Annotation(
            type: AnnotationType.text,
            points: const [NormPoint(0.2, 0.6)],
            text: '合成文字'),
      ];
      final out = await exportCompositedImage(
          imagePath: src.path, annotations: list, maxSide: 128);
      // 产物：新文件、PNG、在 export 目录
      final f = File(out);
      expect(await f.exists(), isTrue);
      expect(f.parent.path.contains('export'), isTrue);
      expect(f.lengthSync(), greaterThan(0));
      // 源图原封不动（数据不动纪律）
      final after = await File(src.path).stat();
      expect(after.size, before.size);
      expect(out, isNot(src.path));
      await f.delete();
      await src.delete();
    });
  });
}

/// 造一张 8x8 纯色 PNG 临时源图。
Future<File> createTestPng() async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 8), ui.Paint()..color = const ui.Color(0xFF336699));
  final pic = rec.endRecording();
  final img = await pic.toImage(8, 8);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final dir = await Directory.systemTemp.createTemp('anno_export_test');
  final f = File('${dir.path}/src.png');
  await f.writeAsBytes(data!.buffer.asUint8List());
  return f;
}
