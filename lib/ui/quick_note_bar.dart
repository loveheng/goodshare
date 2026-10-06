import 'dart:async';

import 'package:flutter/material.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../app/lifecycle_manager.dart';
import 'toast.dart';
import '../models/draft_store.dart';
import '../models/item.dart';
import '../share/note_composer.dart';
import '../share/text_collector.dart';
import 'audio_playback_service.dart';
import 'note_composer_editor.dart';
import 'tokens.dart';

/// 底部常驻速记条（2026-09-29 改版：取代悬浮球）。
///
/// 硬要求：速记路径**不得比原悬浮球更长**——点即聚焦、打字即存。
///
/// 2026-10-03 编辑器统一（docs/design/note-editor-unification.md）：本壳
/// 只保留**面板外壳**（收合拉手/拖拽形变/顶栏/草稿持久化/保存路由），
/// 编辑器内核（分段作曲层+媒体卡+动作行+格式转盘）全部下沉到
/// [NoteComposerEditor]——与详情页编辑态**同一组件**（用户拍板「一模一样」）。
class QuickNoteBar extends StatefulWidget {
  const QuickNoteBar({
    super.key,
    required this.collector,
    required this.handler,
    this.draftPersistencer,
  });

  final TextCollector collector;
  final ItemActionHandler handler;

  /// 持久草稿仓（quick-note-draft.md）：默认 drafts 表实现；widget 测试注入
  /// [InMemoryDraftStore] 与 sqflite 解耦（内存库跨用例泄漏 + fake async 死锁）。
  final DraftPersistencer? draftPersistencer;

  @override
  State<QuickNoteBar> createState() => _QuickNoteBarState();
}

class _QuickNoteBarState extends State<QuickNoteBar> {
  /// 编辑器句柄：保存取段序列、内容感知 CTA 读 hasContent。
  final _editorKey = GlobalKey<NoteComposerEditorState>();

  /// 便利贴作用域的音频播放服务：跨收合/展开周期持有（单实例红线），
  /// 注入编辑器复用。
  final AudioPlaybackController _audioCtl = AudioPlaybackController();

  /// 内容感知 CTA 的局部刷新信号：编辑器 onChanged 只 bump 此 notifier，
  /// 由按钮处的 ValueListenableBuilder 消费——打字不再整壳 setState
  ///（P2 性能防线，2026-10-04）。
  final ValueNotifier<int> _ctaRevision = ValueNotifier<int>(0);

  // 草稿持久化（quick-note-draft.md）：drafts 表为**持久事实源**，静态字段
  // 降级为 Activity 重建的**同步热缓存**。行快照来自编辑器 onDirty 回调
  //（[_lastRows]），壳不再直接触段——dispose 时编辑器已先销毁，靠缓存兜底。
  static List<List<String>> _draftSegsPersisted = const [];

  static const _draftId = 'quick_note_bar';
  late final DraftPersistencer _draftStore =
      widget.draftPersistencer ?? DraftStore();
  Timer? _draftDebounce;
  StreamSubscription<void>? _bgSub;

  /// 最近一次编辑器行快照（dispose 落盘依据；编辑器先于壳销毁不可回读）。
  List<List<String>> _lastRows = const [];

  // 面板态静态留存：系统相机/权限弹窗可能重建 Activity，普通字段归零而这些幸存
  // （与草稿同口径，2026-09-30 修「点拍照回来便签消失」）。
  static bool _expandedPersisted = false;
  static List<String> _pendingTagsPersisted = [];
  static bool _todoModePersisted = false;

  /// 本条未保存内容上挂的标签（编辑器标签按钮设置，随保存落库，保存后清空）。
  List<String> _pendingTags = [];

  /// 待办模式：开 = 保存时文本段逐行转 `- [ ]` 待办。入口已移除
  ///（2026-10-03 拍板「去掉待办列表」），仅存量待办草稿恢复后保留口径。
  bool _todoMode = false;

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

  @override
  void initState() {
    super.initState();
    // 静态热缓存 → 编辑器 initialRows（首挂载播种）；进程重启（静态空）→
    // 磁盘草稿恢复（quick-note-draft.md §2.3），两条路径不竞速。
    _lastRows = _draftSegsPersisted;
    _pendingTags = List.of(_pendingTagsPersisted);
    _todoMode = _todoModePersisted;
    _expanded = _expandedPersisted;
    _progress = _expanded ? 1 : 0; // 形变进度与展开态同源恢复，防「态开形未开」
    if (_draftSegsPersisted.isEmpty) {
      unawaited(_restoreDraftFromDisk());
    }
    // 退后台强制落盘（quick_note_sheet 同款订阅口径）
    _bgSub = AppLifecycleManager.instance.onBackgrounded.listen((_) {
      _persistDraft(flush: true);
    });
  }

  @override
  void dispose() {
    _bgSub?.cancel();
    _draftDebounce?.cancel();
    _expandedPersisted = _expanded;
    _pendingTagsPersisted = List.of(_pendingTags);
    _todoModePersisted = _todoMode;
    _persistDraft(flush: true);
    _ctaRevision.dispose();
    _audioCtl.dispose();
    super.dispose();
  }

  // ---------- 草稿持久化 ----------

  /// 编辑器变更点（结构 flush 语义由编辑器统一回调）：行快照缓存 + drafts 表
  /// 800ms 防抖。payload 同步捕获——dispose 后编辑器控制器不可再读，靠
  /// [_lastRows] 缓存兜底。
  void _onEditorDirty(List<List<String>> rows) {
    _lastRows = rows;
    _draftSegsPersisted = rows;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(
        _draftStore.save(
          _draftId,
          _draftId,
          QuickNoteDraft(
            segs: rows,
            tags: _pendingTags,
            todo: _todoMode,
            expanded: _expanded,
          ).encode(),
        ),
      ),
    );
  }

  /// 落盘（dispose/收合/退后台 flush 口径）：直接用 [_lastRows] 缓存，
  /// 不回读编辑器（dispose 时已销毁）。
  void _persistDraft({bool flush = false}) {
    final payload = QuickNoteDraft(
      segs: _lastRows,
      tags: _pendingTags,
      todo: _todoMode,
      expanded: _expanded,
    ).encode();
    _draftDebounce?.cancel();
    if (flush) {
      unawaited(_draftStore.save(_draftId, _draftId, payload));
    } else {
      _draftDebounce = Timer(
        const Duration(milliseconds: 800),
        () => unawaited(_draftStore.save(_draftId, _draftId, payload)),
      );
    }
  }

  /// 行快照是否「有东西」（文字非空或含媒体）——磁盘恢复的前置防覆盖判断。
  bool get _rowsHaveContent => _lastRows.any(
    (r) => r.first != 't' || (r.length > 1 && (r[1]).trim().isNotEmpty),
  );

  /// 磁盘草稿恢复：仅在便签仍为空态时应用（异步窗口内用户已起笔则跳过，
  /// 新内容会在下个变更点覆盖旧草稿）。
  Future<void> _restoreDraftFromDisk() async {
    final raw = await _draftStore.load(_draftId);
    if (raw == null || !mounted) return;
    if (_rowsHaveContent || _pendingTags.isNotEmpty || _todoMode) return;
    final draft = QuickNoteDraft.tryDecode(raw);
    if (draft == null) {
      // 草稿损坏不阻断书写（空便签可用），下次变更点即覆盖旧草稿
      debugPrint('[DEGRADE] quick_note_draft_restore: parse failed');
      return;
    }
    if (draft.segs.isEmpty && draft.tags.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _lastRows = draft.segs;
      _draftSegsPersisted = draft.segs;
      _pendingTags = draft.tags;
      _todoMode = draft.todo;
      _expanded = draft.expanded;
      _progress = _expanded ? 1 : 0;
    });
    // 编辑器已挂载（展开态恢复）→ 就地重播种；未挂载则 initialRows 在
    // 首次展开时自然消费静态行。
    _editorKey.currentState?.loadRows(draft.segs);
  }

  // ---------- 保存路由 ----------

  /// 便签是否“有东西可存”（文字/媒体/待挂标签/待办模式任一）——
  /// 保存按钮的内容感知点亮依据。
  bool get _hasContent =>
      _pendingTags.isNotEmpty ||
      _todoMode ||
      (_editorKey.currentState?.hasContent ?? false);

  String get _todayLabel {
    final now = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${now.year}年${now.month}月${now.day}日 ${weekdays[now.weekday - 1]}';
  }

  /// 保存：段序列（编辑器此刻序列化）→ **一个** note 条目 → 清空内容区
  /// （面板保持张开，可连续记）。
  ///
  /// 路由（用户拍板「媒体不分散保存 + 含媒体豁免合并」）：
  /// - 纯文本：走 `TextCollector.collectText`（合并窗口 / 纯 URL 拆分等既有逻辑不变）；
  /// - 含媒体：直发 `CollectCommand`（itemType=note、mode=scatter），永不并链。
  Future<void> _save() async {
    if (_sending) return;
    // 序列化出口后移（速记同源化拍板）：所见即所得态此刻才落 human_md——
    // 编辑区全程无 md 标记，落库仍是标准 markdown，下游零感知。
    final models = _editorKey.currentState?.toNoteSegments();
    if (models == null) return;
    final body = serializeNoteMd(models, todoMode: _todoMode);
    if (body.isEmpty) {
      ToastManager.show('先写点什么吧', kind: ToastKind.error);
      return;
    }
    setState(() => _sending = true);
    try {
      final tags = _pendingTags.isEmpty ? null : _pendingTags;
      if (noteHasMedia(models)) {
        await widget.handler.execute(
          CollectCommand(
            itemType: InboxItem.typeNote,
            sourceApp: '速记',
            rawContent: body,
            humanTitle: noteTitleOf(models), // 无一级标题不写 title → 详情落时间标题
            tags: tags,
          ),
        );
      } else {
        await widget.collector.collectText(body, sourceApp: '速记', tags: tags);
      }
      if (!mounted) return;
      setState(() {
        _pendingTags = [];
        _todoMode = false;
      });
      _editorKey.currentState?.loadRows(const []); // 清空编辑器（起手一段文本）
      _lastRows = const [];
      _draftSegsPersisted = const [];
      _draftDebounce?.cancel();
      unawaited(_draftStore.delete(_draftId)); // 保存成功即清持久草稿
      ToastManager.show('已记下', kind: ToastKind.success);
    } catch (e) {
      // 失败原因原样告知（R1：错误要被用户感知，不自行编造兜底文案）
      if (mounted) ToastManager.show('保存失败：$e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------- 面板外壳（形变/收合/展开） ----------

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
    _editorKey.currentState?.requestFocusFirst(); // 点按抢焦点，拉回写作区
  }

  /// 收合：内容**不保存**（用户拍板「没点保存就留在便签里」），仅收起面板。
  void _collapse() {
    _persistDraft(flush: true);
    _expandedPersisted = false;
    if (mounted) {
      setState(() {
        _expanded = false;
        _dragSettling = true;
        _progress = 0; // 补间回拉手态
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 连续形变（方案 A「跟手渐展」）：整个 build 只渲染**一张便签**——
    // 高度 = peek + progress × 行程，头部拉手与身体（顶栏/编辑器）
    // 同属这一个容器，拖动时一起长出，不存在「头部先走、身体后到」。
    //
    // 展开态顶部锚定（2026-09-30 最终拍板「完全展开后顶到状态栏」）：面板顶缘
    // = 状态栏下沿。状态栏高度必须取 FlutterView 的原始 padding——本组件在
    // Scaffold body 内，body 的 MediaQuery.padding 已被 Scaffold 消费（=0）。
    final statusBar = MediaQueryData.fromView(View.of(context)).padding.top;
    final topInset = statusBar;
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
                child: Semantics(
                  // 无障碍（ui-spec §6.0）：拉手无文字，TalkBack 需中文 label
                  button: true,
                  label: _expanded ? '速记便签' : '速记便签，点按或上滑展开',
                  child: GestureDetector(
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
                  ), // GestureDetector
                ), // Semantics
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

    // 静止展开：高度 = available（顶缘锚在状态栏下沿），不可省略 height。
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
    final contentOpacity =
        ((clamped - _contentFadeStart) / (1 - _contentFadeStart)).clamp(
          0.0,
          1.0,
        );
    // 拉手文字比面板淡出更早（0→0.2 消隐）：收合拉手与展开正文各有一份
    // 「记点什么…」，交叉淡化窗口若同步走，半途两个提示并存——文字先死
    // 后生（正文提示 0.35 才浮现），任何时刻全屏最多一份提示。
    final peekTextOpacity = (1 - clamped / 0.2).clamp(0.0, 1.0);
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
            Opacity(
              opacity: (1 - contentOpacity).clamp(0.0, 1.0),
              child: _buildPeek(scheme, textOpacity: peekTextOpacity),
            ),
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
  Widget _buildPeek(ColorScheme scheme, {double textOpacity = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Opacity(
          opacity: textOpacity,
          child: Text(
            '记点什么…',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  /// 展开态：顶栏（钉在可见区顶部）+ 统一作曲编辑器（作曲层/工具层/转盘
  /// 的 Stack 挂载封装在 [NoteComposerEditor] 内部，宿主给有界高度即可）。
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
              // 内容感知 CTA（用户拍板）：空=实色禁用（无 M3 半透明罩），
              // 有内容=点亮橘红（橘红仅动作与选中）。刷新经编辑器 onChanged
              // → _ctaRevision bump → 本 Builder 局部重评（打字不再整壳
              // setState）。
              ValueListenableBuilder<int>(
                valueListenable: _ctaRevision,
                builder: (context, _, _) {
                  final ready = _hasContent && !_sending;
                  return FilledButton(
                    onPressed: ready ? _save : null,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      disabledBackgroundColor: scheme.surfaceContainer,
                      disabledForegroundColor: scheme.onSurfaceVariant
                          .withValues(alpha: 0.6),
                    ),
                    child: const Text('保存'),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // 统一作曲编辑器（与详情页编辑态同一组件）
          Expanded(
            child: NoteComposerEditor(
              key: _editorKey,
              initialRows: _draftSegsPersisted,
              onDirty: _onEditorDirty,
              onChanged: _onEditorChanged,
              pendingTags: _pendingTags,
              onPendingTagsChanged: (tags) {
                setState(() => _pendingTags = tags);
                _persistDraft();
              },
              audioController: _audioCtl,
            ),
          ),
        ],
      ),
    );
  }

  /// 编辑器任意变更 → 刷新内容感知 CTA（编辑器内部自行 setState 管段渲染，
  /// 壳只管顶栏 CTA）。
  void _onEditorChanged() {
    _ctaRevision.value++; // 内容感知 CTA 局部刷新（整壳 setState 已退役）
  }
}
