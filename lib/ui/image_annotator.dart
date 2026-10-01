import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'dart:ui' show ImageFilter;
import 'package:share_plus/share_plus.dart';

import '../models/annotation.dart';
import '../models/item.dart';
import '../render/annotation_export.dart';
import 'annotation_canvas.dart';
import 'annotation_list.dart';

/// 标注编辑宿主（image-markup.md 第 2 批改版）：图片画布 + 工具栏 + 标注列表抽屉。
///
/// 职能边界（goodshare-arch「UI 只持交互态」）：本组件只做**装配与持久化**——
/// 加载 AnnotationStore、把画布/列表回调落 store；几何判定/渲染/选择状态机全部
/// 下沉 annotation_geometry.dart / annotation_painter.dart / annotation_canvas.dart。
/// 列表↔画布受控选中（§6 双向联动）由本组件持 `_selectedId` 透传两侧。
class ImageAnnotator extends StatefulWidget {
  const ImageAnnotator({super.key, required this.item});
  final InboxItem item;

  @override
  State<ImageAnnotator> createState() => _ImageAnnotatorState();
}

class _ImageAnnotatorState extends State<ImageAnnotator> {
  List<Annotation> _list = [];
  AnnotationType? _creatingType; // 生成模式（工具栏发起，§6）
  String _color = '#FF3B30';
  bool _loading = true;
  ui.Image? _image;
  String? _selectedId; // 受控选中（列表↔画布双向联动，§6）
  bool _createFilled = false; // 生成态实心（§3 隐私遮挡=rect 实心态）
  bool _exporting = false; // 导出合成进行中（重 IO，按钮防重入）

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

  /// 拖拽生成完成 → 自动入列（分配 ID/序号按列表顺序动态算，§3）。
  /// 文字标注（§7）：tap 落点 → 弹输入 → 确认才入列（空文本丢弃不产出）。
  Future<void> _onAdded(Annotation a) async {
    var toAdd = a;
    if (a.type == AnnotationType.text) {
      final text = await _askText();
      if (text == null || text.isEmpty) return; // 取消/空文本不产出
      toAdd = a.copyWith(text: text);
    }
    final withColor = toAdd.copyWith(color: _color, z: _list.length);
    await AnnotationStore.add(widget.item.id!, withColor);
    if (!mounted) return;
    setState(() {
      _list = [..._list, withColor];
      _selectedId = withColor.id;
      _creatingType = null; // 一次生成一个，回到操作态
    });
  }

  /// 文字输入（§7 方向感知两形态）：竖屏键盘不遮画布 → 通用对话框实时排版；
  /// 横屏软键盘遮 70%+ 画布 → **沉浸式全屏输入**（毛玻璃背景，成熟心智），
  /// 确认后回图上回显排版。按方向自动选择，不做「回竖屏」的规则碎片化。
  Future<String?> _askText() async {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final ctrl = TextEditingController();
    if (!landscape) {
      return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('标注文字'),
          content: TextField(controller: ctrl, autofocus: true, maxLines: 3),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('确定')),
          ],
        ),
      );
    }
    // 横屏沉浸式：全屏毛玻璃 + 大输入区（§7 横屏降级形态）
    final result = await Navigator.of(context).push<String>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, _, _) => _ImmersiveTextInput(controller: ctrl),
      ),
    );
    return result;
  }

  /// 拖拽调整（整体移动/锚点重算）结束 → 整表回写。
  Future<void> _onChanged(List<Annotation> list) async {
    await AnnotationStore.saveAll(widget.item.id!, list);
    if (!mounted) return;
    setState(() => _list = [...list]);
  }

  /// 删除（§6 列表四件事）：移除对象；删的是当前选中则一并清选中。
  Future<void> _remove(String id) async {
    await AnnotationStore.remove(widget.item.id!, id);
    if (!mounted) return;
    setState(() {
      _list = _list.where((a) => a.id != id).toList();
      if (_selectedId == id) _selectedId = null;
    });
  }

  /// 改色 = 固定色板循环（§3，无取色器）。
  Future<void> _cycleColor(String id) async {
    final idx = _list.indexWhere((a) => a.id == id);
    if (idx < 0) return;
    final next =
        _palette[(_palette.indexOf(_list[idx].color) + 1) % _palette.length];
    final updated = _list[idx].copyWith(color: next);
    await AnnotationStore.saveAll(widget.item.id!, [..._list]..[idx] = updated);
    if (!mounted) return;
    setState(() => _list = [..._list]..[idx] = updated);
  }

  /// 「调整」→ 锚点级编辑（§6）：选中该对象并收抽屉，露出画布拖锚点
  /// （loupe/吸附反馈栈兜底）。锚点级落位由画布在锚点拖动开始时接管。
  void _enterAdjust(String id) {
    setState(() => _selectedId = id);
    Navigator.of(context).pop();
  }

  /// 实心 Toggle（§3 隐私遮挡）：仅 rect 可切换；无选中时切生成态。
  Future<void> _toggleFill() async {
    final sel = _selectedId;
    if (sel != null) {
      final idx = _list.indexWhere((a) => a.id == sel);
      if (idx < 0 || _list[idx].type != AnnotationType.rect) return;
      final updated = _list[idx].copyWith(filled: !_list[idx].filled);
      await AnnotationStore.saveAll(widget.item.id!, [..._list]..[idx] = updated);
      if (!mounted) return;
      setState(() => _list = [..._list]..[idx] = updated);
    } else {
      setState(() => _createFilled = !_createFilled);
    }
  }

  /// 导出合成（§7）：瞬时合成标注进图 → **新文件**（原条目数据不动）→
  /// 系统分享。失败 SnackBar 原样告知不静默。
  Future<void> _exportAndShare() async {
    if (_list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('还没有标注，先在图上添加')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final path = await exportCompositedImage(
        imagePath: widget.item.rawFilePath!,
        annotations: _list,
      );
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 竖屏底部抽屉（§6 标注列表：竖屏底部抽屉形态）。
  void _openListSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 280,
          child: AnnotationList(
            annotations: _list,
            selectedId: _selectedId,
            onSelected: (id) {
              setState(() => _selectedId = id);
              // 不关抽屉——列表是「找与管」主场，选中后可继续改色/删除
            },
            onDelete: _remove,
            onCycleColor: _cycleColor,
            onEnterAdjust: _enterAdjust,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_image == null) {
      return const Center(child: Text('图片加载失败'));
    }
    final background = Image.file(
      File(widget.item.rawFilePath!),
      fit: BoxFit.fill,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AnnotationToolbar(
              onCreate: (t) => setState(() {
                _creatingType = t;
                // 「遮挡」快捷入口默认实心；普通矩形默认空心
                _createFilled = t == AnnotationType.rect ? _createFilled : false;
              }),
              activeType: _creatingType,
              onCancelCreate: () => setState(() => _creatingType = null),
              onToggleFill: _toggleFill,
              fillAvailable: _selectedId == null ||
                  (_list
                          .where((a) => a.id == _selectedId)
                          .firstOrNull
                          ?.type ==
                      AnnotationType.rect),
              currentFilled: _selectedId == null
                  ? _createFilled
                  : (_list
                          .where((a) => a.id == _selectedId)
                          .firstOrNull
                          ?.filled ??
                      false),
            ),
            const Spacer(),
            ..._palette.map((c) => GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: _hex(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == c
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                )),
          ],
        ),
        const SizedBox(height: 8),
        // 方向感知（image-markup.md §9）：横屏=画布+右栏列表（Row）；竖屏=
        // 画布+底部抽屉入口（§6 竖屏抽屉形态）。标注推荐横屏但不强制。
        Expanded(
          child: OrientationBuilder(builder: (context, orientation) {
            final canvas = AnnotationCanvas(
              annotations: _list,
              onChanged: _onChanged,
              onAdded: _onAdded,
              createType: _creatingType,
              createFilled: _createFilled,
              onCreateSettled: () {}, // 复位在 _onAdded / 工具栏取消
              selectedId: _selectedId,
              onSelectedChanged: (id) => setState(() => _selectedId = id),
              background: background, // loupe 镜中原图（§5.1 复渲染法）
            );
            if (orientation == Orientation.landscape) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: canvas),
                  SizedBox(
                    width: 240,
                    child: AnnotationList(
                      annotations: _list,
                      selectedId: _selectedId,
                      onSelected: (id) => setState(() => _selectedId = id),
                      onDelete: _remove,
                      onCycleColor: _cycleColor,
                      onEnterAdjust: (id) => setState(() => _selectedId = id),
                    ),
                  ),
                ],
              );
            }
            return canvas;
          }),
        ),
        // 列表入口 + 导出分享（§7 瞬时合成产物为新文件）——横屏右栏已常驻列表
        Row(
          children: [
            if (MediaQuery.orientationOf(context) == Orientation.portrait)
              TextButton.icon(
                onPressed: _openListSheet,
                icon: const Icon(Icons.list, size: 18),
                label: Text('标注列表（${_list.length}）'),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: _exporting ? null : _exportAndShare,
              icon: _exporting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share, size: 18),
              label: const Text('导出分享'),
            ),
          ],
        ),
      ],
    );
  }

  Color _hex(String hex) {
    final v = hex.replaceFirst('#', '');
    return Color(int.parse(v.length == 6 ? 'FF$v' : v, radix: 16));
  }
}

/// 横屏沉浸式全屏文字输入（§7 横屏降级形态）：全屏毛玻璃背景 + 大输入区，
/// 确认回图上回显排版。成熟心智：右下「完成」pop 带文本，左上「取消」pop null。
class _ImmersiveTextInput extends StatelessWidget {
  const _ImmersiveTextInput({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          color: scheme.surface.withValues(alpha: 0.6),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                        tooltip: '取消',
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () =>
                            Navigator.pop(context, controller.text.trim()),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: Theme.of(context).textTheme.bodyLarge,
                      decoration: InputDecoration(
                        hintText: '输入标注文字…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
