import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../models/item.dart';
import '../share/attachments.dart';
import '../share/text_collector.dart';
import 'tokens.dart';

/// 底部常驻速记条（2026-09-29 改版：取代悬浮球）。
///
/// 硬要求：速记路径**不得比原悬浮球更长**——点即聚焦、打字即存。
///
/// 2026-09-30 改版第三轮（用户拍板「便利贴 + 全展开」）：
/// - **收合态**：只露顶边的便签拉手（底边沉入底栏后），上滑/点按拽出；
/// - **展开态**：接近整屏的书写面板——顶栏「收起箭头 · 今日日期 · 保存」，
///   主体大书写区（左右仅小边距，靠投影分层），下方两行工具
///   「标题 / 粗体」+「拍照 / 录音 / 标签 / 待办」；
/// - **保存语义（用户拍板）**：点保存 = 生成新卡片并**清空内容区**（面板不关，
///   可连续记）；**不点保存内容就留在便签里**（收合/切 tab 均保留，静态草稿缓存）。
///
/// 导入类动作（扫描文档 / 导入文件）不在本条上，归顶部 `＋` 菜单（ui-spec §4.6）。
class QuickNoteBar extends StatefulWidget {
  const QuickNoteBar({
    super.key,
    required this.collector,
    required this.handler,
  });

  final TextCollector collector;
  final ItemActionHandler handler;

  @override
  State<QuickNoteBar> createState() => _QuickNoteBarState();
}

class _QuickNoteBarState extends State<QuickNoteBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _recorder = AudioRecorder();

  /// 未保存草稿跨「收合 / 切 tab / 面板销毁」留存（用户拍板：没点保存就留在便签里）。
  /// 静态字段：QuickNoteBar 随 tab 切换销毁重建，草稿必须活过生命周期。
  static String _draftText = '';

  // 面板态静态留存：系统相机/权限弹窗可能重建 Activity，普通字段归零而这些幸存
  // （与 _draftText 同口径，2026-09-30 修「点拍照回来便签消失」）。
  static bool _expandedPersisted = false;
  static List<String> _pendingTagsPersisted = [];
  static bool _todoModePersisted = false;

  /// 本条未保存内容上挂的标签（标签按钮设置，随保存落库，保存后清空）。
  List<String> _pendingTags = [];

  /// 待办模式：开 = 保存时逐行转 `- [ ]` 待办。
  bool _todoMode = false;

  bool _recording = false;
  bool _sending = false;
  bool _expanded = false;

  /// 收合↔展开的连续形变进度（0 = 收合拉手，1 = 满幅面板）。
  /// 方案 A（用户拍板「跟手渐展」）：上滑直接控面板高度，头部+身体一起长出；
  /// 拖动中 progress 实时跟手，松手过阈值补间到 1、未过补间回 0。
  /// _expanded 仅作为「进度到 1 后的稳定态」（焦点/草稿等副作用仍挂在它上面）。
  double _progress = 0;
  bool _dragSettling = false;

  /// 拖动期间禁用内容裁剪/淡入的阈值以下仍显示整块内容。
  static const double _contentFadeStart = 0.35;

  /// 收合态露出高度（便签顶边拉手）。
  static const double _peekHeight = 52;

  /// 工具层固定高度（格式行 + 动作行，两行图标）。文本层的滚动视口底边按它
  /// 上移让位——改这里必须同步考虑光标让位（quick_note_bar 文本层视口 Padding）。
  static const double _toolLayerHeight = 96;

  @override
  void initState() {
    super.initState();
    _ctrl.text = _draftText; // 恢复未保存草稿
    // 系统相机/权限弹窗可能重建 Activity（内存回收）：导航栈原样恢复，但普通字段
    // 全部归零——静态字段与 _draftText 同口径幸存，面板与草稿一起恢复。
    // （用户看到的现象：点拍照回来落在收合列表 = 面板态丢失。）
    _expanded = _expandedPersisted;
    _progress = _expanded ? 1 : 0; // 形变进度与展开态同源恢复，防「态开形未开」
    _pendingTags = List.of(_pendingTagsPersisted);
    _todoMode = _todoModePersisted;
  }

  @override
  void dispose() {
    _expandedPersisted = _expanded;
    _pendingTagsPersisted = List.of(_pendingTags);
    _todoModePersisted = _todoMode;
    _draftText = _ctrl.text; // 留存，不落库
    _ctrl.dispose();
    _focus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  String get _todayLabel {
    final now = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${now.year}年${now.month}月${now.day}日 ${weekdays[now.weekday - 1]}';
  }

  /// 拖动/点按需要展开的总行程：从露出高度拉到接近整屏。
  /// 由可用高度动态算（拖动中随 MediaQuery 键盘变化保持一致手感）。
  double _travel(double available) =>
      (available - _peekHeight).clamp(120.0, double.infinity);

  void _expand() {
    if (mounted) {
      setState(() {
        _expanded = true;
        _dragSettling = true;
        _progress = 1; // 松手/点按：补间到满幅（TweenAnimationBuilder 接力动画）
      });
    }
    _expandedPersisted = true; // 变更点同步（Activity 重建不一定走 dispose）
    _focus.requestFocus();
  }

  /// 收合：内容**不保存**（用户拍板「没点保存就留在便签里」），仅收起面板。
  void _collapse() {
    _focus.unfocus();
    _draftText = _ctrl.text;
    _expandedPersisted = false;
    if (mounted) {
      setState(() {
        _expanded = false;
        _dragSettling = true;
        _progress = 0; // 补间回拉手态
      });
    }
  }

  /// 保存：文本生成新卡片 → 清空内容区（面板保持张开，可连续记）。
  Future<void> _save() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final body = _todoMode
          ? [
              for (final line in text.split('\n'))
                if (line.trim().isNotEmpty) '- [ ] ${line.trim()}',
            ].join('\n')
          : text;
      final item = await widget.collector.collectText(
        body,
        sourceApp: '速记',
        tags: _pendingTags.isEmpty ? null : _pendingTags,
      );
      if (!mounted) return;
      if (item == null) {
        messenger.showSnackBar(const SnackBar(content: Text('未保存（内容为空）')));
        return;
      }
      setState(() {
        _ctrl.clear();
        _draftText = '';
        _pendingTags = [];
        _todoMode = false;
      });
      messenger.showSnackBar(const SnackBar(content: Text('已记下')));
    } catch (e) {
      // 失败原因原样告知（R1：错误要被用户感知，不自行编造兜底文案）
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 拍照：直接生成图片卡片（不依赖文字区）。
  Future<void> _photo() async {
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 2400,
      );
      if (photo == null) return;
      final saved = await copyToAppDir(photo.path);
      if (saved == null) {
        messenger.showSnackBar(const SnackBar(content: Text('图片保存失败')));
        return;
      }
      await widget.handler.execute(
        CollectCommand(
          itemType: InboxItem.typeImage,
          sourceApp: '速记',
          rawFilePath: saved,
          humanTitle: '拍照',
          tags: _pendingTags.isEmpty ? null : _pendingTags,
        ),
      );
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('照片已记下')));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('拍照失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 录音：录 → 再点停止生成音频卡片（仅存音频，转写走详情页手动触发）。
  Future<void> _record() async {
    if (_sending) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_recording) {
      setState(() => _sending = true);
      try {
        final path = await _recorder.stop();
        setState(() => _recording = false);
        if (path == null) {
          messenger.showSnackBar(const SnackBar(content: Text('录音未保存')));
          return;
        }
        await widget.handler.execute(
          CollectCommand(
            itemType: InboxItem.typeAudio,
            sourceApp: '速记',
            rawFilePath: path,
            humanTitle: '录音',
            tags: _pendingTags.isEmpty ? null : _pendingTags,
          ),
        );
        if (!mounted) return;
        messenger.showSnackBar(const SnackBar(content: Text('录音已记下')));
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    if (!await _recorder.hasPermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('缺少麦克风权限')));
      return;
    }
    setState(() => _sending = true);
    try {
      final dir = await appShareDir();
      final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      setState(() => _recording = true);
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('录音启动失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 标签：给本条未保存内容挂标签，随下次保存落库。
  Future<void> _pickTags() async {
    final ctl = TextEditingController(text: _pendingTags.join(' '));
    final tags = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('标签（空格分隔）'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：工作 灵感'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              ctx,
              ctl.text
                  .trim()
                  .split(RegExp(r'\s+'))
                  .where((t) => t.isNotEmpty)
                  .toList(),
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (tags != null && mounted) setState(() => _pendingTags = tags);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 连续形变（方案 A「跟手渐展」）：整个 build 只渲染**一张便签**——
    // 高度 = peek + progress × 行程，头部拉手与身体（顶栏/文本层/工具层）
    // 同属这一个容器，拖动时一起长出，不存在「头部先走、身体后到」。
    //
    // 展开态顶部锚定（2026-09-30 最终拍板「完全展开后顶到状态栏」）：面板顶缘
    // = 状态栏下沿，topInset 就是状态栏高度本身（曾按 B1 加过 Insets.sm 小间距，
    // 用户看了真机后改为贴满）。
    // 状态栏高度必须取 FlutterView 的原始 padding——本组件在 Scaffold body 内，
    // body 的 MediaQuery.padding 已被 Scaffold 消费（=0），用它避让等于不避让，
    // 正是「顶栏顶进状态栏」的根因（2026-09-30 修）。
    final statusBar = MediaQueryData.fromView(View.of(context)).padding.top;
    final topInset = statusBar;
    // 注意： MediaQuery.of().size.height 是整屏高，body 底部还有 NavigationBar——
    // 用它算面板高会高出「底栏高 − topInset」，Align(bottomCenter) 把超出部分顶到
    // body 上沿之上，头部被推到状态栏外（2026-09-30 修「头部跟着搜索条隐藏」）。
    // 面板最大高必须用 body 实际约束（LayoutBuilder），不放回 build 顶层算。

    // _expanded 只作稳定态判定：进度到位（≥0.999）才算展开，焦点/持久化挂它。
    final expandedNow = _expanded && _progress > 0.999;

    return Material(
      // 必须用 transparency 类型而非 transparent color：带颜色的 Material 即使
      // 全透明也会在整个边界内不透明地吸收命中测试，把下方列表的点击/滑动
      // 全部挡掉（2026-09-30 修「首页内容区不能点击和滑动」）。
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Padding(
          // 收合/展开与内容区同宽语言（用户拍板「便利贴和内容区同宽」）
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 面板最大高 = body 实际约束高 − topInset（顶缘锚在搜索框水平带）
              final available = (constraints.maxHeight - topInset).clamp(
                0.0,
                double.infinity,
              );
              return Align(
                alignment: Alignment.bottomCenter,
                child: GestureDetector(
                  // 展开完成后才允许拖动收合之外的交互？——收合拖动只在
                  // 未展开时接手；展开态由内部顶栏按钮收起（原「无下滑收起」决策保留）。
                  onVerticalDragUpdate: expandedNow
                      ? null
                      : (d) {
                          // 拖动中零时长跟手：Δdy ÷ 总行程 → 进度增量，clamp 防拽出
                          setState(() {
                            _dragSettling = false;
                            _progress =
                                (_progress - d.delta.dy / _travel(available))
                                    .clamp(0.0, 1.0);
                          });
                        },
                  onVerticalDragEnd: expandedNow
                      ? null
                      : (d) {
                          final velocity = d.primaryVelocity ?? 0;
                          final fling = velocity < -120;
                          final lifted =
                              _progress > _peekHeight / _travel(available);
                          if (fling || lifted) {
                            _expand();
                          } else {
                            setState(() {
                              _dragSettling = true;
                              _progress = 0; // 未过阈值：补间回拉手
                            });
                          }
                        },
                  onVerticalDragCancel: () {
                    // 展开态必须忽略：点按面板内按钮（保存/标题/粗体等）时外层拖拽
                    // 识别器在竞技场落败会触发 cancel——若无此门控会把已展开面板
                    // 拽回收合（2026-09-30 修「点工具按钮面板坍缩」）。
                    if (expandedNow) return;
                    setState(() {
                      _dragSettling = true;
                      _progress = 0;
                    });
                  },
                  onTap: _expanded ? null : _expand,
                  // TweenAnimationBuilder 双态复用：拖动中 end 实时变、时长零 → 跟手；
                  // 松手/点按 end 定格、时长 260ms → 接力补间（回弹或展开完成）。
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _progress),
                    duration: _dragSettling
                        ? const Duration(milliseconds: 260)
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) =>
                        _morphSheet(scheme, t: t, available: available),
                  ),
                ),
              ); // Align
            }, // LayoutBuilder builder
          ),
        ),
      ),
    );
  }

  /// 形变中的便签：t∈[0,1]，0=拉手、1=满幅。
  /// 两个静止态（0 / 1）各走一棵**干净的树**（纯拉手 / 纯面板），保证命中
  /// 区域与布局和单态版本完全一致；只有形变中间态（拖动中 / 补间中）才做
  /// 高度增长 + 内容淡入上移，且中间态禁命中（IgnorePointer）防幽灵点按。
  Widget _morphSheet(
    ColorScheme scheme, {
    required double t,
    required double available,
  }) {
    final clamped = t.clamp(0.0, 1.0);

    // 静止收合：纯拉手（52px，无隐形内容——旧版幽灵控件/屏外溢出的根源）
    if (clamped <= 0) {
      return Container(
        height: _peekHeight,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.md),
          ),
          border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: 1.5),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.22),
              blurRadius: 6,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: _buildPeek(scheme),
      );
    }

    // 静止展开：高度 = available（顶缘锚在状态栏+小间距 = 搜索条水平带，
    // B1 用户拍板），不可省略 height——省略会吃满 Positioned 整屏约束，
    // 顶缘回到屏幕最上端、顶栏顶进状态栏。
    if (clamped >= 1) {
      return Container(
        height: available,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.md),
          ),
          border: Border(
            top: BorderSide(
              color: scheme.primary.withValues(alpha: 0.55),
              width: 1.5,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: _buildExpanded(scheme),
      );
    }

    // 形变中间态：高度连续增长，头部拉手与身体一起长出
    final height = _peekHeight + (available - _peekHeight) * clamped;
    // 内容透明度：t < 淡入起点前保持 0（纯拉手），之后线性升到 1
    final contentOpacity =
        ((clamped - _contentFadeStart) / (1 - _contentFadeStart)).clamp(
          0.0,
          1.0,
        );
    final contentShift = (1 - clamped) * 24; // 内容轻微上移，增强「长出」感

    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.md),
        ),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 1.5),
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.22),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: IgnorePointer(
        // 中间态禁命中：内容尚在淡入/位移，此刻的按钮位置不可信
        ignoring: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 拉手（内容淡入后自然被盖住）
            Opacity(
              opacity: (1 - contentOpacity).clamp(0.0, 1.0),
              child: _buildPeek(scheme),
            ),
            // 主体内容：淡入 + 上移（身体跟着头部一起长出）
            Opacity(
              opacity: contentOpacity,
              child: Transform.translate(
                offset: Offset(0, contentShift),
                child: _buildExpanded(scheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 收合态：只露便签顶边拉手。
  Widget _buildPeek(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '记点什么…  ·  点按或上滑展开',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 展开态：三层平行结构（用户拍板「工具层与文本区分离」）——
  /// 顶栏（钉在可见区顶部）/ 文本层（满幅、内部无限滚动、无底边）/
  /// 工具层（独立覆盖底部，不随文本滚动消失）。
  /// Stack 让文本层的框延伸到工具层背后（输入区没有「底边」概念），
  /// 滚动视口底边上移一个工具层高度：光标与末行永不滑进工具层底下，
  /// 且让位高度不进滚动内容（无幻影滚动）。
  Widget _buildExpanded(ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(Insets.sm),
      child: Column(
        children: [
          // 顶栏
          Row(
            children: [
              IconButton(
                onPressed: _collapse,
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: '收起（内容保留在便签）',
              ),
              Expanded(
                child: Text(
                  _todayLabel,
                  textAlign: TextAlign.center,
                  style: textTheme.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton.tonal(
                onPressed: _sending ? null : _save,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('保存'),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // 文本层 + 工具层
          Expanded(
            child: Stack(
              children: [
                // 文本层：满幅铺到面板底（工具层背后），内容超出内部滚动。
                // 工具层让位走**视口级** Padding 而非 contentPadding——
                // contentPadding 会把让位高度算进滚动内容，产生「没写到底
                // 也能滚」的幻影滚动（2026-09-30 修）；视口底边止于工具层
                // 上沿后，滚动量只在文字真正溢出时出现，光标也永不滑进工具层底下。
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: _toolLayerHeight),
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      expands: true,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      scrollPadding: EdgeInsets.zero,
                      decoration: InputDecoration(
                        hintText: '记点什么…',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.only(top: Insets.xs),
                      ),
                      style: textTheme.bodyLarge,
                    ),
                  ),
                ),
                // 工具层：独立覆盖底部，文本怎么滚都不消失（键盘弹起贴键盘上沿）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _toolLayer(scheme),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工具层（固定两行高：格式行 + 动作行）。提示收进动作行保证层高恒定——
  /// 文本层的让位边距按本层高度计算，层高若随提示行变化，滚动到底时光标
  /// 会被提示行盖住。
  Widget _toolLayer(ColorScheme scheme) {
    return SizedBox(
      height: _toolLayerHeight,
      child: Column(children: [_formatRow(), _actionRow(scheme)]),
    );
  }

  /// 格式行：标题 / 粗体（2026-09-30 用户拍板：不做高亮，加粗体即可）。
  /// 写作区是纯文本，格式 = 插入 Markdown 子集语法（详情页渲染器原生支持），
  /// 不引富文本编辑器、不新增存储格式。
  Widget _formatRow() {
    return SizedBox(
      height: _toolLayerHeight / 2,
      child: Row(
        children: [
          IconButton(
            onPressed: _toggleHeading,
            icon: const Icon(Icons.title),
            tooltip: '标题',
          ),
          IconButton(
            onPressed: _wrapBold,
            icon: const Icon(Icons.format_bold),
            tooltip: '粗体',
          ),
        ],
      ),
    );
  }

  /// 动作行：拍照 / 录音 / 标签 / 待办 + 待挂标签内联提示。
  Widget _actionRow(ColorScheme scheme) {
    return SizedBox(
      height: _toolLayerHeight / 2,
      child: Row(
        children: [
          IconButton(
            onPressed: _sending ? null : _photo,
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: '拍照',
          ),
          IconButton(
            onPressed: _sending ? null : _record,
            icon: Icon(_recording ? Icons.stop : Icons.mic_none),
            tooltip: _recording ? '停止并保存录音' : '录音',
          ),
          if (_recording)
            const Text(
              '录音中…',
              style: TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          const Spacer(),
          if (_pendingTags.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                _pendingTags.map((t) => '#$t').join(' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          IconButton(
            onPressed: _pickTags,
            icon: Badge(
              isLabelVisible: _pendingTags.isNotEmpty,
              label: Text('${_pendingTags.length}'),
              child: const Icon(Icons.tag),
            ),
            tooltip: '标签',
          ),
          IconButton(
            onPressed: () => setState(() => _todoMode = !_todoMode),
            icon: Icon(
              Icons.check_circle_outline,
              color: _todoMode ? scheme.primary : null,
            ),
            tooltip: _todoMode ? '待办模式（开）' : '待办模式',
          ),
        ],
      ),
    );
  }

  /// 标题：切换光标所在行的 `## ` 前缀（有则去、无则加），光标落行尾。
  void _toggleHeading() {
    final value = _ctrl.value;
    if (!value.selection.isValid) return;
    final text = value.text;
    final start = value.selection.start;
    final lineStart = start <= 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    final nl = text.indexOf('\n', lineStart);
    final lineEnd = nl == -1 ? text.length : nl;
    final line = text.substring(lineStart, lineEnd);
    final stripped = line.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    final newLine = stripped.length == line.length ? '## $stripped' : stripped;
    _ctrl.value = TextEditingValue(
      text: text.replaceRange(lineStart, lineEnd, newLine),
      selection: TextSelection.collapsed(offset: lineStart + newLine.length),
    );
    _focus.requestFocus(); // 按钮点按会抢走焦点收键盘，拉回写作区
  }

  /// 粗体：选中文字包 `**`（保持选中）；无选中则插入 `****`、光标落中间。
  void _wrapBold() {
    final value = _ctrl.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    final text = value.text;
    if (sel.start == sel.end) {
      _ctrl.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.start, '****'),
        selection: TextSelection.collapsed(offset: sel.start + 2),
      );
    } else {
      final inner = text.substring(sel.start, sel.end);
      _ctrl.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.end, '**$inner**'),
        selection: TextSelection(
          baseOffset: sel.start + 2,
          extentOffset: sel.end + 2,
        ),
      );
    }
    _focus.requestFocus(); // 按钮点按会抢走焦点收键盘，拉回写作区
  }
}
