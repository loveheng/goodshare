import 'dart:io';
import 'dart:math' show min, max, cos, sin;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/annotation.dart';
import '../models/item.dart';

/// 最简标注画布：承载「参数采集」——手势 → 归一化 Annotation → AnnotationStore 持久化。
/// UI 暂占位（工具栏/布局后续设计），不影响参数获取与存储。
class ImageAnnotator extends StatefulWidget {
  const ImageAnnotator({super.key, required this.item});
  final InboxItem item;

  @override
  State<ImageAnnotator> createState() => _ImageAnnotatorState();
}

class _ImageAnnotatorState extends State<ImageAnnotator> {
  List<Annotation> _list = const [];
  AnnotationType _type = AnnotationType.rect;
  String _color = '#FF3B30';
  bool _loading = true;
  ui.Image? _image;
  final List<NormPoint> _draft = [];
  bool _drawing = false;
  Offset _tap = Offset.zero;

  static const _palette = ['#FF3B30', '#34C759', '#007AFF', '#FFCC00', '#000000'];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final list = await AnnotationStore.load(widget.item.id!);
    ui.Image? img;
    try {
      final bytes = await File(widget.item.rawFilePath!).readAsBytes();
      img = await decodeImageFromList(bytes);
    } catch (e) {
      debugPrint('[ImageAnnotator] decode failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _list = list;
      _image = img;
      _loading = false;
    });
  }

  double get _aspect => (_image != null && _image!.height > 0)
      ? _image!.width / _image!.height
      : 1.0;

  NormPoint _toNorm(Offset local, double w, double h) =>
      NormPoint((local.dx / w).clamp(0, 1), (local.dy / h).clamp(0, 1));

  Future<void> _commit(NormPoint start, NormPoint end) async {
    if (_type == AnnotationType.text || _type == AnnotationType.number) {
      final text = await _askText();
      if (text == null || text.isEmpty) return;
      await _add(Annotation(
        type: _type,
        points: [start],
        color: _color,
        text: text,
        z: _list.length,
      ));
    } else if (_type == AnnotationType.free) {
      if (_draft.length < 2) return;
      await _add(Annotation(
        type: _type,
        points: [..._draft],
        color: _color,
        z: _list.length,
      ));
    } else {
      await _add(Annotation(
        type: _type,
        points: [start, end],
        color: _color,
        z: _list.length,
      ));
    }
  }

  Future<void> _add(Annotation a) async {
    await AnnotationStore.add(widget.item.id!, a);
    if (!mounted) return;
    setState(() => _list = [..._list, a]);
  }

  Future<String?> _askText() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_type == AnnotationType.number ? '序号文字' : '标注文字'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _undo() async {
    if (_list.isEmpty) return;
    final last = _list.last;
    await AnnotationStore.remove(widget.item.id!, last.id);
    if (mounted) setState(() => _list = _list.sublist(0, _list.length - 1));
  }

  Future<void> _clear() async {
    await AnnotationStore.clear(widget.item.id!);
    if (mounted) setState(() => _list = const []);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_image == null) {
      return const Center(child: Text('图片加载失败'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ...AnnotationType.values.map(
              (t) => ChoiceChip(
                label: Text(_typeLabel(t)),
                selected: _type == t,
                onSelected: (_) => setState(() => _type = t),
              ),
            ),
            ..._palette.map(
              (c) => GestureDetector(
                onTap: () => setState(() => _color = c),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _hex(c),
                    border: Border.all(
                      color: _color == c ? theme.colorScheme.primary : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            IconButton(onPressed: _undo, icon: const Icon(Icons.undo)),
            IconButton(onPressed: _clear, icon: const Icon(Icons.delete_sweep)),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (ctx, constraints) {
          final w = constraints.maxWidth;
          final h = w / _aspect;
          return GestureDetector(
            onTapDown: (d) => _tap = d.localPosition,
            onTap: () async {
              // 纯点击（无拖拽）时 pan 不触发，文字/序号靠 onTap 放置。
              if (_type == AnnotationType.text || _type == AnnotationType.number) {
                final start = _toNorm(_tap, w, h);
                await _commit(start, start);
              }
            },
            onPanStart: (d) {
              setState(() {
                _drawing = true;
                _draft
                  ..clear()
                  ..add(_toNorm(d.localPosition, w, h));
              });
            },
            onPanUpdate: (d) {
              final p = _toNorm(d.localPosition, w, h);
              setState(() {
                if (_type == AnnotationType.free) {
                  _draft.add(p);
                } else {
                  if (_draft.length < 2) {
                    _draft.add(p);
                  } else {
                    _draft[1] = p;
                  }
                }
              });
            },
            onPanEnd: (_) async {
              if (!_drawing) return;
              _drawing = false;
              final start = _draft.first;
              final end = _draft.length > 1 ? _draft.last : _draft.first;
              setState(() => _draft.clear());
              await _commit(start, end);
            },
            child: Stack(
              children: [
                Image.file(File(widget.item.rawFilePath!), width: w, height: h, fit: BoxFit.fill),
                CustomPaint(
                  size: Size(w, h),
                  painter: _AnnoPainter(_list, _draft, _type, _color, w, h),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  String _typeLabel(AnnotationType t) => const {
        AnnotationType.rect: '矩形',
        AnnotationType.arrow: '箭头',
        AnnotationType.free: '笔迹',
        AnnotationType.text: '文字',
        AnnotationType.number: '序号',
      }[t]!;

  Color _hex(String hex) {
    final v = hex.replaceAll('#', '');
    return Color(int.parse(v.length == 6 ? 'FF$v' : v, radix: 16));
  }
}

/// 叠加层绘制：既有标注 + 草稿。坐标由归一化乘显示矩形得到。
class _AnnoPainter extends CustomPainter {
  _AnnoPainter(this.list, this.draft, this.draftType, this.draftColor, this.w, this.h);

  final List<Annotation> list;
  final List<NormPoint> draft;
  final AnnotationType draftType;
  final String draftColor;
  final double w;
  final double h;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in list) {
      _draw(canvas, a);
    }
    if (draft.isNotEmpty) {
      _draw(canvas, Annotation(type: draftType, points: draft, color: draftColor, id: '', createdAt: 0));
    }
  }

  void _draw(Canvas canvas, Annotation a) {
    final paint = Paint()
      ..color = _hex(a.color)
      ..strokeWidth = max(1.0, a.strokeW * min(w, h))
      ..style = PaintingStyle.stroke;
    final pts = [for (final p in a.points) Offset(p.x * w, p.y * h)];
    switch (a.type) {
      case AnnotationType.rect:
        if (pts.length >= 2) {
          canvas.drawRect(Rect.fromPoints(pts[0], pts[1]), paint);
        }
        break;
      case AnnotationType.arrow:
        if (pts.length >= 2) {
          _drawArrow(canvas, paint, pts[0], pts[1]);
        }
        break;
      case AnnotationType.free:
        if (pts.length >= 2) {
          final path = Path()..moveTo(pts[0].dx, pts[0].dy);
          for (final p in pts.skip(1)) {
            path.lineTo(p.dx, p.dy);
          }
          canvas.drawPath(path, paint);
        }
        break;
      case AnnotationType.text:
      case AnnotationType.number:
        if (pts.isNotEmpty) {
          final span = TextSpan(
            text: a.text ?? '',
            style: TextStyle(color: _hex(a.color), fontSize: max(12.0, a.fontSize * min(w, h))),
          );
          final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
          tp.paint(canvas, pts[0]);
        }
        break;
    }
  }

  void _drawArrow(Canvas canvas, Paint paint, Offset a, Offset b) {
    canvas.drawLine(a, b, paint);
    const head = 10.0;
    final ang = (b - a).direction;
    final p1 = b - Offset(cos(ang - 0.5) * head, sin(ang - 0.5) * head);
    final p2 = b - Offset(cos(ang + 0.5) * head, sin(ang + 0.5) * head);
    canvas.drawLine(b, p1, paint);
    canvas.drawLine(b, p2, paint);
  }

  Color _hex(String hex) {
    final v = hex.replaceAll('#', '');
    return Color(int.parse(v.length == 6 ? 'FF$v' : v, radix: 16));
  }

  @override
  bool shouldRepaint(covariant _AnnoPainter old) => true;
}
