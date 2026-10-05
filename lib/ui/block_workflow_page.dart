import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/capability.dart';
import '../ai/workflow.dart';
import '../doc/rich_text.dart' show MediaSuffix, classifyMediaUrl;
import 'audio_playback_service.dart';
import 'block_capability_host.dart';
import 'block_capability_page.dart' show kPreviewMaxHeight;
import 'media_blocks.dart' show MediaAudioBar;
import 'tokens.dart';
import 'workflow_track.dart';

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
    required this.onApplyArtifact,
    required this.onReset,
    required this.onRunStandalone,
    this.onCueSeek,
    this.onEditArtifact,
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
  final Future<void> Function(String blockKey, String kind, String text) onApplyArtifact;
  final Future<void> Function(String blockKey) onReset;
  final Future<void> Function(String capabilityId) onRunStandalone;

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
    if (!mounted) return;
    setState(() {
      _artifacts = view;
      _loading = false;
    });
  }

  Future<bool> _runStep(WorkflowStep step, String? sourceKind) async {
    final ok = await widget.onRunStep(step, widget.blockKey, sourceKind);
    await _reload(); // 成败都重载（失败无新产物；note 由队列页/状态线承载）
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('任务未产出结果，可重试或到任务队列查看原因')),
      );
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
    final standalone = standaloneFor(widget.kind);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // 出口=系统手势/返回键（ui-spec §3）
        title: const Text('区块能力'),
      ),
      body: SafeArea(
        // 页面级播放服务作用域（§4 音频内联播放条）：本页不在详情页作用域内，
        // 自建 controller 包一层——MediaAudioBar 经 context 取用，退出即回收
        child: AudioPlaybackService(
          controller: _audioCtl,
          // 产物「应用」作用域（workflow_track 的 Apply chip 经此路由到页面回调，
          // §3.4 动词体系：应用 = 回注，由详情页落库）
          child: WorkflowApplyScope(
          apply: (kind, text) => widget.onApplyArtifact(widget.blockKey, kind, text),
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
                            child: ClipRect(child: widget.preview),
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
                      // §3.6「以此继续处理」：仅视频 spec 提供切到音频锚点
                      onAnchorSwitch: widget.kind == BlockKind.video
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
                            Text(
                              '独立能力',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: Insets.sm),
                            Wrap(
                              spacing: Insets.sm,
                              runSpacing: Insets.sm,
                              children: [
                                for (final c in standalone)
                                  ActionChip(
                                    avatar: Icon(c.icon, size: 16),
                                    label: Text(c.label),
                                    onPressed: () => widget.onRunStandalone(c.id),
                                  ),
                              ],
                            ),
                          ],
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
