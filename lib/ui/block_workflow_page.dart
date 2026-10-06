import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/video_clips.dart' show ClipSegment, kClipStatusDone, kClipStatusFailed, kClipStatusMarked, kClipStatusProcessing;
import '../ai/capability.dart';
import '../ai/workflow.dart';
import '../data/block_artifacts.dart' show BlockArtifactKind;
import '../doc/rich_text.dart' show MediaSuffix, classifyMediaUrl;
import 'audio_playback_service.dart';
import 'block_capability_host.dart';
import 'block_capability_page.dart' show kPreviewMaxHeight;
import 'media_blocks.dart' show MediaAudioBar;
import 'toast.dart';
import 'workflow_track.dart';
import 'tokens.dart';

/// 块工作流页（2026-10-05 v21，SSOT：docs/design/block-artifact-workflow.md §4）：
/// 行内媒体块长按的三级页**工作流形态**——结构保留只换芯（拍板 9）：骨架
/// （预览限高 + 主体 + 独立能力）不动，主体区从链式卡换为 [WorkflowTrack]。
///
/// 与条目级链式卡（BlockCapabilityPage）的分叉由 [openBlockCapability] 按
/// blockKey 判定：块通道页面，产物读写全走 block_artifacts（§3.3 续跑语义：
/// 打开页时装载已有产物 → 步骤可执行性由 [availabilityOf] 推导）。
class BlockWorkflowPage extends StatefulWidget {
  const BlockWorkflowPage({
    super.key,
    required this.kind,
    required this.blockKey,
    required this.spec,
    this.anchorLabel,
    this.preview,
    this.onPreviewActivate,
    required this.loadArtifacts,
    required this.onRunStep,
    required this.onReset,
    required this.onRunStandalone,
    this.loadClips,
    this.onCueSeek,
    this.onEditArtifact,
    this.loadAnnotationCount,
  });

  final BlockKind kind;
  final String blockKey;
  final WorkflowSpec spec;

  /// 来源锚点（「来自：视频块」）。
  final String? anchorLabel;
  final Widget? preview;
  final VoidCallback? onPreviewActivate;

  final Future<BlockArtifactsView> Function(String blockKey) loadArtifacts;
  final Future<bool> Function(WorkflowStep step, String blockKey, String? sourceKind) onRunStep;
  final Future<void> Function(String blockKey) onReset;
  final Future<void> Function(String capabilityId, String blockKey) onRunStandalone;

  /// 块切片区间回调（2026-10-06 补展示面）：返回该视频块已登记的关键区间。
  /// 此前块级切片只存在 clips_json，详情页正文无展示面——保存后用户停留的
  /// 三级页就地可见（反馈：点击切片保存之后界面不显示刚保存的卡片）。
  final Future<List<ClipSegment>> Function(String blockKey)? loadClips;

  /// 块标注计数回调（按 blockKey 查 AnnotationStore），用于「已识别结果」展示；null 不展示。
  final Future<int> Function(String blockKey)? loadAnnotationCount;

  /// §3.5 跳帧联动：字幕 cue 点句 → 宿主打开播放器定位播放（详情页实现）。
  final void Function(String blockKey, int cueIndex)? onCueSeek;

  /// 文本产物修订（§4 可编辑）：宿主打开编辑页并 upsert 回 block_artifacts。
  final Future<String?> Function(String blockKey, String kind, String currentText)?
      onEditArtifact;

  @override
  State<BlockWorkflowPage> createState() => _BlockWorkflowPageState();
}

class _BlockWorkflowPageState extends State<BlockWorkflowPage> {
  BlockArtifactsView _artifacts = BlockArtifactsView.empty;
  List<ClipSegment> _clips = const [];
  String? _sourceKind;
  bool _loading = true;

  // §3.6 锚点切换（拍板 2026-10-05）：audio_file 卡「以此继续处理」→ 锚点
  // 切到该产物（spec 换 audioSpec、页头文案更新「来自：提取的音频」）；
  // 非空时页头提供「切回视频块」。切换不删前步产物（同一 blockKey 的产物集
  // 共享——锚点只是视图编排，数据源不变）。
  bool _anchorAudio = false;

  // §4 三段式「音频=波形播放条」：本页经 rootNavigator 推入，**不在**详情页
  // 的 AudioPlaybackService 作用域内——自建 controller + 服务作用域（页面
  // 级单例口径：进页创建、dispose 回收，不泄漏播放句柄）。
  final AudioPlaybackController _audioCtl = AudioPlaybackController();

  WorkflowSpec get _spec =>
      _anchorAudio ? workflowFor(BlockKind.audio) : workflowFor(widget.kind);

  String get _anchorLabel {
    if (_anchorAudio) return '来自：提取的音频';
    return widget.anchorLabel ?? '媒体块';
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _audioCtl.dispose(); // 退出页即回收播放句柄（不外泄单例）
    super.dispose();
  }

  Future<void> _reload() async {
    final view = await widget.loadArtifacts(widget.blockKey);
    // 块切片区间（2026-10-06 补展示面）：回调缺席（非视频块）→ 空列表
    final clips = widget.loadClips == null
        ? const <ClipSegment>[]
        : await widget.loadClips!(widget.blockKey);
    if (!mounted) return;
    setState(() {
      _artifacts = view;
      _clips = clips;
      _loading = false;
    });
  }

  Future<bool> _runStep(WorkflowStep step, String? sourceKind) async {
    final ok = await widget.onRunStep(step, widget.blockKey, sourceKind);
    await _reload(); // 成败都重载（失败无新产物；note 由队列页/状态线承载）
    if (!ok && mounted) {
      ToastManager.show('任务未产出结果，可重试或到任务队列查看原因',
          kind: ToastKind.error);
    }
    return ok;
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本块全部产物？'),
        content: const Text('已生成的识别/转写结果将被删除，重新解析需再次消耗算力。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // §3.3 Reset 口径：危险二次确认 + 触觉（清产物是不可逆的算力损失，
    // 落手瞬间给一次中等强度反馈，与「开始」的 lightImpact 区分强度档）
    HapticFeedback.mediumImpact();
    await widget.onReset(widget.blockKey);
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 独立能力（标注/分类/识别条码）统一块级化（2026-10-05）：顶级 'item' 与行内
    // local:// 同走 onRunStandalone(id, blockKey)，作用到具体图片块，不再区分；
    // 结果（分类/条码/标注）统一在下方「已识别结果」展示。
    final standalone = standaloneFor(widget.kind);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // 出口=系统手势/返回键（ui-spec §3）
        // 标题栏=块类型名（2026-10-05 拍板：不写「区块能力」通称；锚点切到
        // 提取的音频时工作台实为音频链，标题随锚点走）
        title: Text(blockKindLabel(_anchorAudio ? BlockKind.audio : widget.kind)),
      ),
      body: SafeArea(
        // 页面级播放服务作用域（§4 音频内联播放条）：本页不在详情页作用域内，
        // 自建 controller 包一层——MediaAudioBar 经 context 取用，退出即回收
        child: AudioPlaybackService(
          controller: _audioCtl,
          // 2026-10-06 拍板：产物「应用」通道退役——workflow_track 不再出
          // 应用 chip，WorkflowApplyScope 已撤；回注由用户在正文编辑器自主粘贴。
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.preview != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
                        child: GestureDetector(
                          onTap: widget.onPreviewActivate,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxHeight: kPreviewMaxHeight,
                            ),
                            // 限高 + 居中裁切（2026-10-05 修）：限高只约束**裁切框**
                            //（此处 ConstrainedBox 决定窗口高 280），子级经
                            // OverflowBox 得「有界宽 + 无界高」排版——避免超高
                            // 预览（竖屏视频播放器 ≈660，Column 内含进度条/标记
                            // chips）被压进 280 后内部 RenderFlex 溢出、控制条与
                            // 居中播放箭头被挤出可视区；居中裁切保证主体可见。
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.center,
                                maxHeight: double.infinity,
                                child: widget.preview,
                              ),
                            ),
                          ),
                        ),
                      ),
                    // 来源锚点（§3.6：锚点切换时文案更新「来自：提取的音频」，
                    // 已切换时提供切回入口——返回栈深度不变，纯页内状态）
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _anchorLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (_anchorAudio)
                            GestureDetector(
                              onTap: () => setState(() => _anchorAudio = false),
                              child: Text(
                                '切回${widget.anchorLabel ?? '视频块'}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    WorkflowTrack(
                      spec: _spec,
                      existingKinds: _artifacts.kinds,
                      artifactText: _artifacts.text,
                      artifactMeta: _artifacts.meta,
                      artifactFilePath: _artifacts.filePath,
                      artifactElapsedMs: _artifacts.elapsedMs,
                      sourceKind: _sourceKind,
                      onSourceKindChanged: (k) => setState(() => _sourceKind = k),
                      onRunStep: _runStep,
                      // §3.6「以此继续处理」：只在**确实存在 audio_file 产物**
                      // 时给入口（audio_file 由「提取音频」步骤产出；切锚点后
                      // 转写改用音轨文件省一次解码）。
                      onAnchorSwitch: widget.kind == BlockKind.video &&
                              _artifacts.kinds.contains(BlockArtifactKind.audioFile)
                          ? (_) => setState(() => _anchorAudio = true)
                          : null,
                      // §3.5 跳帧联动：cue 点句 → 宿主开播放器定位
                      onCueSeek: widget.onCueSeek == null
                          ? null
                          : (i) => widget.onCueSeek!(widget.blockKey, i),
                      // §4 文本产物可编辑：宿主编辑页 + upsert 回表
                      onEditArtifact: widget.onEditArtifact == null
                          ? null
                          : (kind, current) =>
                              widget.onEditArtifact!(widget.blockKey, kind, current),
                      // §4 三段式「音频=波形播放条」：audio_file 卡内联播放条
                      //（绝对路径直进 setFilePath，JustAudioHandle 统一收口；
                      // 降级档静态卡由 MediaAudioBar.degrade 自判）
                      audioPreviewBuilder: (path) => MediaAudioBar(
                        blockId: 'workflow-audio-$path',
                        source: path,
                        label: '提取的音频',
                        degrade:
                            classifyMediaUrl(path) == MediaSuffix.audioDegrade,
                      ),
                      onReset: _reset,
                    ),
                    if (standalone.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            sectionHeader(theme, scheme, '独立能力'),
                            const SizedBox(height: Insets.sm),
                            Wrap(
                              spacing: Insets.sm,
                              runSpacing: Insets.sm,
                              children: [
                                for (final c in standalone)
                                  ActionChip(
                                    avatar: Icon(c.icon, size: 16),
                                    label: Text(c.label),
                                    // 落定后回刷本页（2026-10-05 修）：独立能力
                                    // 由宿主等任务落定才返回，_reload 重读
                                    // block_artifacts + 标注计数，「已识别结果」
                                    // 不再是空的要退出重进。
                                    onPressed: () async {
                                      await widget.onRunStandalone(
                                        c.id,
                                        widget.blockKey,
                                      );
                                      if (mounted) await _reload();
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // 切片区间展示面（2026-10-06 补）：块级切片此前只落
                      // clips_json 无展示位——保存标记后三级页就地可见
                      //（区间/状态/note 与切片编辑器同口径，R1 同一份状态）。
                      if (_clips.isNotEmpty) ...[
                        sectionHeader(theme, scheme, '切片区间'),
                        const SizedBox(height: Insets.sm),
                        for (final seg in _clips)
                          Container(
                            margin: const EdgeInsets.only(bottom: Insets.sm),
                            padding: const EdgeInsets.all(Insets.sm),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.bookmark_outlined, size: 16),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '${_fmtMs(seg.startMs)} → ${_fmtMs(seg.endMs)}'
                                      ' · ${switch (seg.status) {
                                        kClipStatusMarked => '已标记',
                                        kClipStatusProcessing => '处理中…',
                                        kClipStatusDone => '已完成',
                                        kClipStatusFailed => '失败',
                                        _ => seg.status,
                                      }}',
                                      style: theme.textTheme.labelMedium,
                                    ),
                                  ),
                                ]),
                                if (seg.note != null)
                                  Text(seg.note!,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: seg.status == kClipStatusFailed
                                            ? scheme.error
                                            : scheme.onSurfaceVariant,
                                      )),
                                if (seg.summary != null && seg.summary!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(seg.summary!,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall),
                                ],
                              ],
                            ),
                          ),
                        Text(
                          '处理进度与产出在 AI 任务队列查看；区间编辑在正文中长按视频块 → 视频切片。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: Insets.md),
                      ],
                      ..._standaloneResults(),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  /// 毫秒 → m:ss（切片区间展示；与 clip_editor_sheet 的 _fmt 同口径）。
  String _fmtMs(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// 独立能力「已识别结果」展示面（块级化 2026-10-05）：分类/条码来自 block_artifacts，
  /// 标注数来自 AnnotationStore（按 blockKey）；顶级 'item' 与行内 local:// 一致。
  List<Widget> _standaloneResults() {
    final scheme = Theme.of(context).colorScheme;
    final out = <Widget>[];
    final cls = _artifacts.text[BlockArtifactKind.classification];
    if (cls != null && cls.trim().isNotEmpty) {
      out.add(_resultCard(
        scheme,
        Icons.sell_outlined,
        '分类',
        cls.split('\n').where((l) => l.trim().isNotEmpty).toList(),
      ));
    }
    final bc = _artifacts.text[BlockArtifactKind.barcode];
    if (bc != null && bc.trim().isNotEmpty) {
      out.add(_resultCard(
        scheme,
        Icons.qr_code_2_outlined,
        '条码 / 二维码',
        bc.split('\n').where((l) => l.trim().isNotEmpty).toList(),
      ));
    }
    if (widget.loadAnnotationCount != null) {
      out.add(FutureBuilder<int>(
        future: widget.loadAnnotationCount!(widget.blockKey),
        builder: (ctx, snap) => _resultCard(
          scheme,
          Icons.edit_note_outlined,
          '标注',
          ['${snap.data ?? 0} 处'],
        ),
      ));
    }
    return out;
  }

  Widget _resultCard(
    ColorScheme scheme,
    IconData icon,
    String title,
    List<String> lines,
  ) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
        child: Card(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.sm),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(l, style: Theme.of(context).textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
        ),
      );
}
