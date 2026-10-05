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
import 'tokens.dart' show Insets, Radii;

/// 标注编辑宿主（image-markup.md §2 终态 2026-10-04：画布全屏 + 悬浮件）。
///
/// 职能边界（goodshare-arch「UI 只持交互态」）：本组件只做**装配与持久化**——
/// 加载 AnnotationStore、把画布/列表回调落 store；几何判定/渲染/选择状态机全部
/// 下沉 annotation_geometry.dart / annotation_painter.dart / annotation_canvas.dart。
/// 列表↔画布受控选中（§6 双向联动）由本组件持 `_selectedId` 透传两侧；
/// 显隐视图态（`_hiddenIds`，不落盘）与悬浮件瞬隐（`_interacting`）同属本层交互态。
class ImageAnnotator extends StatefulWidget {
  const ImageAnnotator({super.key, required this.item});
  final InboxItem item;

  /// 画布回写合并：画布持有可见子集，按 id 并回全表——隐藏项数据原样保留。
  /// 纯函数（单测钉住：合并不丢隐藏项，§6 显隐②）。
  static List<Annotation> mergeById(
    List<Annotation> base,
    List<Annotation> updates,
  ) {
    final byId = {for (final u in updates) u.id: u};
    return [for (final a in base) byId[a.id] ?? a];
  }

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

  // ── 全屏悬浮形态（2026-10-04 二次拍板：画布全屏 + 悬浮件）──
  bool _interacting = false; // 手指在画布上 → 悬浮件瞬隐（§2 纪律）
  bool _listOpen = false; // 标注列表浮层展开态

  /// 显隐视图态（§6 豁免）：只改渲染不改数据，**不落盘**——重进页面全复显。
  Set<String> _hiddenIds = {};

  /// 画布可见子集：隐藏 = 不绘制不命中（渲染/命中/吸附零特判，宿主滤数）。
  List<Annotation> get _visibleList => [
    for (final a in _list)
      if (!_hiddenIds.contains(a.id)) a,
  ];

  static const _palette = [
    '#FF3B30',
    '#34C759',
    '#007AFF',
    '#FFCC00',
    '#000000',
  ];

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

  /// 文字输入（§7 方向感知两形态）：竖屏键盘不遮画布 → 统一 BottomSheet
  /// 输入（动词→容器词汇表：「输入短文本」唯一容器）；横屏软键盘遮 70%+
  /// 画布 → **沉浸式全屏输入**（毛玻璃背景，成熟心智），确认后回图上回显
  /// 排版。按方向自动选择，不做「回竖屏」的规则碎片化。
  Future<String?> _askText() async {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final ctrl = TextEditingController();
    if (!landscape) {
      return showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(
            left: Insets.lg,
            right: Insets.lg,
            top: Insets.md,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Insets.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('标注文字', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: Insets.md),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(hintText: '输入文字'),
              ),
              const SizedBox(height: Insets.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: Insets.sm),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
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

  /// 拖拽调整（整体移动/锚点重算）结束 → 整表回写（画布持可见子集，按 id
  /// 并回全表再落盘，隐藏项数据不丢）。
  Future<void> _onChanged(List<Annotation> list) async {
    final merged = ImageAnnotator.mergeById(_list, list);
    await AnnotationStore.saveAll(widget.item.id!, merged);
    if (!mounted) return;
    setState(() => _list = merged);
  }

  /// 删除（§6 列表）：移除对象；删的是当前选中则一并清选中，隐藏态同步清理。
  Future<void> _remove(String id) async {
    await AnnotationStore.remove(widget.item.id!, id);
    if (!mounted) return;
    setState(() {
      _list = _list.where((a) => a.id != id).toList();
      if (_selectedId == id) _selectedId = null;
      _hiddenIds = {..._hiddenIds}..remove(id);
    });
  }

  /// 列表点行选中（§6 双向联动 + 显隐防死锁出口）：隐藏行被点 = 自动复显。
  void _onSelect(String? id) {
    setState(() {
      _selectedId = id;
      if (id != null && _hiddenIds.contains(id)) {
        _hiddenIds = {..._hiddenIds}..remove(id);
      }
    });
  }

  /// 显隐切换（视图态豁免）：只改渲染不改数据；藏的是当前选中则清选中
  /// （画布上已不可见不可命中，选中态悬空无意义）。
  void _toggleHidden(String id) {
    setState(() {
      final hidden = _hiddenIds.toSet();
      if (!hidden.remove(id)) hidden.add(id);
      _hiddenIds = hidden;
      if (_hiddenIds.contains(id) && _selectedId == id) _selectedId = null;
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

  /// 「调整」→ 锚点级编辑（§6 确定性通道）：预选该对象（若隐藏先复显——
  /// 防死锁），画布直接拖锚点。与直接操纵同构，只是替用户完成选中两步。
  void _enterAdjust(String id) {
    _onSelect(id);
  }

  /// 实心 Toggle（§3 隐私遮挡）：仅 rect 可切换；无选中时切生成态。
  Future<void> _toggleFill() async {
    final sel = _selectedId;
    if (sel != null) {
      final idx = _list.indexWhere((a) => a.id == sel);
      if (idx < 0 || _list[idx].type != AnnotationType.rect) return;
      final updated = _list[idx].copyWith(filled: !_list[idx].filled);
      await AnnotationStore.saveAll(
        widget.item.id!,
        [..._list]..[idx] = updated,
      );
      if (!mounted) return;
      setState(() => _list = [..._list]..[idx] = updated);
    } else {
      setState(() => _createFilled = !_createFilled);
    }
  }

  /// 导出合成（§7）：瞬时合成标注进图 → **新文件**（原条目数据不动）→
  /// 系统分享。**所见即所得**（§6 显隐纪律④）：按画布当前可见集合成，
  /// 隐藏的不进合成图。失败 SnackBar 原样告知不静默。
  Future<void> _exportAndShare() async {
    if (_visibleList.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('还没有标注，先在图上添加')));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final path = await exportCompositedImage(
        imagePath: widget.item.rawFilePath!,
        annotations: _visibleList,
      );
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_image == null) {
      return const Center(child: Text('图片加载失败'));
    }
    final scheme = Theme.of(context).colorScheme;
    // 全屏悬浮形态（2026-10-04 二次拍板，回归 §2 职能分离+使用证据）：
    // 画布全屏；工具条底部悬浮（瞬隐）；列表 = 右上小签点按悬浮展开
    // （渐进披露，五件事含显隐）；导出收 AppBar（低频完成态动作不占画布）。
    return Scaffold(
      appBar: AppBar(
        // 无返回箭头（ui-spec §3）：出口=系统手势/返回键
        automaticallyImplyLeading: false,
        title: const Text('图片标注'),
        actions: [
          IconButton(
            tooltip: '导出分享',
            onPressed: _exporting ? null : _exportAndShare,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: AnnotationCanvas(
                annotations: _visibleList,
                onChanged: _onChanged,
                onAdded: _onAdded,
                createType: _creatingType,
                createFilled: _createFilled,
                onCreateSettled: () {}, // 复位在 _onAdded / 工具栏取消
                selectedId: _selectedId,
                onSelectedChanged: _onSelect,
                background: Image.file(
                  File(widget.item.rawFilePath!),
                  fit: BoxFit.fill,
                ), // 画布底图 + loupe 镜中原图（§5.1 复渲染法）
                onInteractionChanged: (v) => setState(() => _interacting = v),
              ),
            ),
            // 列表浮层展开时的「点外部收起」屏障：translucent——画布手势照常，
            // 只多一个 tap 收起出口（面板自身 opaque 不透传）
            if (_listOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _listOpen = false),
                  child: const SizedBox.shrink(),
                ),
              ),
            // 右上列表小签（渐进披露入口）
            Positioned(
              top: Insets.sm,
              right: Insets.md,
              child: _transient(
                Material(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    onTap: () => setState(() => _listOpen = !_listOpen),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.format_list_bulleted,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '标注列表（${_list.length}）',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 列表浮层（五件事面板，宽 280 上限 45% 高）
            if (_listOpen)
              Positioned(
                top: 52,
                right: Insets.md,
                child: _transient(
                  Material(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(Radii.lg),
                    clipBehavior: Clip.antiAlias,
                    elevation: 3,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 280,
                        maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                      ),
                      child: AnnotationList(
                        annotations: _list,
                        selectedId: _selectedId,
                        onSelected: _onSelect,
                        onDelete: _remove,
                        onCycleColor: _cycleColor,
                        onEnterAdjust: _enterAdjust,
                        hiddenIds: _hiddenIds,
                        onToggleHidden: _toggleHidden,
                      ),
                    ),
                  ),
                ),
              ),
            // 底部悬浮工具条（工具 + 色板同卡）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Insets.md),
                    child: _transient(
                      AnnotationToolbar(
                        onCreate: (t) => setState(() {
                          _creatingType = t;
                          // 「遮挡」快捷入口默认实心；普通矩形默认空心
                          _createFilled = t == AnnotationType.rect
                              ? _createFilled
                              : false;
                        }),
                        activeType: _creatingType,
                        onCancelCreate: () =>
                            setState(() => _creatingType = null),
                        onToggleFill: _toggleFill,
                        fillAvailable:
                            _selectedId == null ||
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
                        trailing: [
                          // 色板（§3 固定五色循环）：生成色 = 当前选中色
                          VerticalDivider(
                            width: 16,
                            indent: 10,
                            endIndent: 10,
                            color: scheme.outlineVariant,
                          ),
                          for (final c in _palette)
                            GestureDetector(
                              onTap: () => setState(() => _color = c),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 10,
                                ),
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: _hex(c),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _color == c
                                        ? scheme.primary
                                        : Colors.transparent,
                                    width: 2,
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
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮件瞬隐包装（§2 纪律）：手指落在画布期间隐藏且不吃事件，抬手渐显。
  Widget _transient(Widget child) => IgnorePointer(
    ignoring: _interacting,
    child: AnimatedOpacity(
      opacity: _interacting ? 0 : 1,
      duration: const Duration(milliseconds: 120),
      child: child,
    ),
  );

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
