import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'item.dart';

/// 归一化坐标点（相对原图宽高，[0,1]）。与屏幕/显示尺寸解耦，
/// 保证原图替换或不同分辨率屏幕下标记位置恒定对齐。
class NormPoint {
  const NormPoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, double> toJson() => {'x': x, 'y': y};

  static NormPoint fromJson(Map<String, Object?> j) =>
      NormPoint(_toDouble(j['x']), _toDouble(j['y']));

  static double _toDouble(Object? v) => (v is num ? v : 0).toDouble();
}

enum AnnotationType { rect, arrow, free, text, number }

extension AnnotationTypeX on AnnotationType {
  String get name => const {
        AnnotationType.rect: 'rect',
        AnnotationType.arrow: 'arrow',
        AnnotationType.free: 'free',
        AnnotationType.text: 'text',
        AnnotationType.number: 'number',
      }[this]!;

  static AnnotationType fromName(String? s) => const {
        'rect': AnnotationType.rect,
        'arrow': AnnotationType.arrow,
        'free': AnnotationType.free,
        'text': AnnotationType.text,
        'number': AnnotationType.number,
      }[s] ?? AnnotationType.rect;
}

/// 单条标注。坐标全部归一化（见 [NormPoint]）。
class Annotation {
  Annotation({
    String? id,
    required this.type,
    required this.points,
    this.color = '#FF3B30',
    this.strokeW = 0.004,
    this.text,
    this.fontSize = 0.03,
    int? z,
    int? createdAt,
  })  : id = id ?? InboxItem.newId(),
        z = z ?? 0,
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final AnnotationType type;
  final List<NormPoint> points; // 归一化坐标点
  final String color; // hex
  final double strokeW; // 相对原图短边比例
  final String? text; // type==text / number 的内容
  final double fontSize; // 相对原图短边比例
  final int z; // 叠放次序
  final int createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.name,
        'points': [for (final pt in points) pt.toJson()],
        'color': color,
        'strokeW': strokeW,
        if (text != null) 'text': text,
        'fontSize': fontSize,
        'z': z,
        'createdAt': createdAt,
      };

  static Annotation fromJson(Map<String, Object?> j) => Annotation(
        id: (j['id'] as String?) ?? InboxItem.newId(),
        type: AnnotationTypeX.fromName(j['type'] as String?),
        points: [
          for (final e in (j['points'] as List? ?? const []))
            NormPoint.fromJson((e as Map).cast<String, Object?>())
        ],
        color: (j['color'] as String?) ?? '#FF3B30',
        strokeW: _toDouble(j['strokeW']) ?? 0.004,
        text: j['text'] as String?,
        fontSize: _toDouble(j['fontSize']) ?? 0.03,
        z: (j['z'] as int?) ?? 0,
        createdAt: (j['createdAt'] as int?) ?? 0,
      );

  Annotation copyWith({
    AnnotationType? type,
    List<NormPoint>? points,
    String? color,
    double? strokeW,
    String? text,
    double? fontSize,
    int? z,
  }) =>
      Annotation(
        id: id,
        type: type ?? this.type,
        points: points ?? this.points,
        color: color ?? this.color,
        strokeW: strokeW ?? this.strokeW,
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        z: z ?? this.z,
        createdAt: createdAt,
      );

  static double? _toDouble(Object? v) => v is num ? v.toDouble() : null;
}

/// 标注存储（documents/annotations/{itemId}.json）。纯文件 IO，与 OCR 文本落
/// human_md 解耦，不进 AI 队列、不新增 inbox_items 字段。
class AnnotationStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'annotations'));
    await d.create(recursive: true);
    return d;
  }

  static Future<File> _file(String itemId) async =>
      File(p.join((await _dir()).path, '$itemId.json'));

  /// 加载某 item 全部标注（无文件返回空列表）。失败兜底空，不阻断。
  static Future<List<Annotation>> load(String itemId) async {
    try {
      final f = await _file(itemId);
      if (!await f.exists()) return const [];
      final raw = await f.readAsString();
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final e in list) Annotation.fromJson((e as Map).cast<String, Object?>())
      ];
    } catch (e) {
      debugPrint('[AnnotationStore] load failed: $e');
      return const [];
    }
  }

  /// 列表角标判定：文件存在即视为「有标注」（零重绘）。
  static Future<bool> hasAnnotations(String itemId) async {
    try {
      final f = await _file(itemId);
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  /// 整体写回（本期平铺列表，整体读写足够；按 z 排序）。
  static Future<void> saveAll(String itemId, List<Annotation> list) async {
    final f = await _file(itemId);
    final sorted = [...list]..sort((a, b) => a.z.compareTo(b.z));
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert([for (final a in sorted) a.toJson()]),
    );
  }

  static Future<void> add(String itemId, Annotation a) async {
    final list = await load(itemId);
    list.add(a);
    await saveAll(itemId, list);
  }

  static Future<void> remove(String itemId, String id) async {
    final list = await load(itemId);
    list.removeWhere((a) => a.id == id);
    await saveAll(itemId, list);
  }

  static Future<void> clear(String itemId) async {
    final f = await _file(itemId);
    if (await f.exists()) await f.delete();
  }
}
