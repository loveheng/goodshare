import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../ai/workflow.dart';
import '../data/block_artifacts.dart' show BlockArtifactKind;
import 'tokens.dart';

/// 工作流轨（2026-10-05 v21，SSOT：docs/design/block-artifact-workflow.md §4）：
/// 三级页主体区从「线性链式卡」换芯为「左细进度线 + 节点 + 每步产物卡」。
///
/// 拍板口径：
/// - **全显+折叠**（三轮拍板）：全部步骤常显，未解锁步骤折叠为紧凑单行
///   （灰显+缺源标记），完成步骤的产物卡默认折叠摘要行；
/// - **产物卡三段式**（三轮拍板）：卡头（步骤名+耗时）+ 中部预览（kind 分化）
///   + 底部操作区（应用/导出/复制 chips）；
/// - **翻译选源嵌入式 segmented control**（四轮拍板）：选源与触发同一操作流，
///   不弹窗；
/// - **状态唯一事实源是 block_artifacts**（§3.1 边界 5）：本组件纯视图，
///   done/ready/locked 由调用方用 [availabilityOf] 推导传入；
/// - 复用 mymind 视觉令牌（Insets/Radii），执行中呼吸/骨架 = CircularProgressIndicator
///   小尺寸节点 + 卡内占位（现行三态口径），不新造组件语言。
class WorkflowTrack extends StatelessWidget {
  const WorkflowTrack({
    super.key,
    required this.spec,
    required this.existingKinds,
    this.artifactText = const {},
    this.artifactMeta = const {},
    this.artifactFilePath = const {},
    this.artifactElapsedMs = const {},
    required this.sourceKind,
    required this.onSourceKindChanged,
    required this.onRunStep,
    this.onAnchorSwitch,
    this.onCueSeek,
    this.onEditArtifact,
    this.audioPreviewBuilder,
    this.onReset,
  });

  final WorkflowSpec spec;

  /// 该块已有产物的 kind 集合（可用性判定输入，§3.3 续跑语义）。
  final Set<String> existingKinds;

  /// 产物内容映射（kind → 文本；编辑产出后的 effective 由调用方合并）。
  final Map<String, String> artifactText;

  /// 产物元信息映射（kind → 摘要行文案，如「12 段 · 03:24」）。
  final Map<String, String> artifactMeta;

  /// 产物文件路径映射（kind → file_path；字幕/音轨导出分享用）。
  final Map<String, String> artifactFilePath;

  /// 产物实测耗时映射（kind → 毫秒；§4 卡头「耗时」，执行侧注入
  /// meta_json.elapsed_ms）。缺席 = 旧产物 / 非块通道写入，卡头整段不占位。
  final Map<String, int> artifactElapsedMs;

  /// 翻译步骤当前选中的源 kind（多备选源时 segmented control 绑定值）。
  final String? sourceKind;
  final ValueChanged<String> onSourceKindChanged;

  /// 执行某步（翻译类步骤带当前选源）；返回是否成功（失败即停步展示）。
  final Future<bool> Function(WorkflowStep step, String? sourceKind) onRunStep;

  /// 锚点切换（§3.6「以此继续处理」）：audio_file 卡点按后切换 spec 到 audioSpec，
  /// null = 不支持（如该页非视频 spec）。回调带产物 file_path（新锚点的源）。
  final void Function(String audioFilePath)? onAnchorSwitch;

  /// §3.5 跳帧联动：字幕卡点某句 cue → 打开播放器定位到 cue 起点播放。
  /// [cueIndex] = 可用 cue 序号（usableCues 过滤后）；null = 不给 cue 列表。
  final void Function(int cueIndex)? onCueSeek;

  /// 文本产物修订（§4 三段式「文本=全文预览可编辑」）：打开编辑页返回修订
  /// 文本（null=取消），落库由实现方 upsert 回 block_artifacts（保 filePath/meta）。
  /// null = 不给「编辑」入口。
  final Future<String?> Function(String kind, String currentText)? onEditArtifact;

  /// audio_file 卡内联播放条构建器（§4 三段式「音频=波形播放条」）：宿主用
  /// 页面级播放服务构造 MediaAudioBar；null = 音频卡退化为文件名摘要行。
  final Widget Function(String filePath)? audioPreviewBuilder;

  /// 轨尾 Reset（清该块全部产物；危险确认由调用方负责，null = 不显示）。
  final Future<void> Function()? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '工作流',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (onReset != null)
                IconButton(
                  tooltip: '清除本块全部产物',
                  icon: const Icon(Icons.restart_alt, size: 18),
                  onPressed: () => onReset!(),
                ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          for (var i = 0; i < spec.steps.length; i++)
            _StepRow(
              step: spec.steps[i],
              existingKinds: existingKinds,
              artifactText: artifactText,
              artifactMeta: artifactMeta,
              artifactFilePath: artifactFilePath,
              artifactElapsedMs: artifactElapsedMs,
              sourceKind: sourceKind,
              onSourceKindChanged: onSourceKindChanged,
              onRunStep: onRunStep,
              onAnchorSwitch: onAnchorSwitch,
              onCueSeek: onCueSeek,
              onEditArtifact: onEditArtifact,
              audioPreviewBuilder: audioPreviewBuilder,
              isLast: i == spec.steps.length - 1,
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatefulWidget {
  const _StepRow({
    required this.step,
    required this.existingKinds,
    required this.artifactText,
    required this.artifactMeta,
    required this.artifactFilePath,
    required this.artifactElapsedMs,
    required this.sourceKind,
    required this.onSourceKindChanged,
    required this.onRunStep,
    this.onAnchorSwitch,
    this.onCueSeek,
    this.onEditArtifact,
    this.audioPreviewBuilder,
    required this.isLast,
  });

  final WorkflowStep step;
  final Set<String> existingKinds;
  final Map<String, String> artifactText;
  final Map<String, String> artifactMeta;
  final Map<String, String> artifactFilePath;
  final Map<String, int> artifactElapsedMs;
  final String? sourceKind;
  final ValueChanged<String> onSourceKindChanged;
  final Future<bool> Function(WorkflowStep step, String? sourceKind) onRunStep;

  /// §3.6 锚点切换回调（透传 WorkflowTrack；null = 不支持）。
  final void Function(String audioFilePath)? onAnchorSwitch;

  /// §3.5 跳帧联动（透传 WorkflowTrack，仅字幕卡消费；null = 不给 cue 列表）。
  final void Function(int cueIndex)? onCueSeek;

  /// 文本产物修订（透传，仅文本类产物卡消费；null = 不给「编辑」入口）。
  final Future<String?> Function(String kind, String currentText)? onEditArtifact;

  /// audio_file 卡内联播放条构建器（透传 WorkflowTrack；null = 摘要行退化）。
  final Widget Function(String filePath)? audioPreviewBuilder;

  final bool isLast;

  @override
  State<_StepRow> createState() => _StepRowState();
}

class _StepRowState extends State<_StepRow> {
  bool _running = false;
  bool _expanded = false;
  String? _error;

  WorkflowStepAvailability get _availability =>
      availabilityOf(widget.step, widget.existingKinds);

  /// 多备选源的步骤（翻译）当前生效选源：绑定值 ∈ 备选集，否则取首个已有源。
  String? get _effectiveSource {
    final options = availableSources(widget.step, widget.existingKinds);
    if (options.isEmpty) return null;
    final bound = widget.sourceKind;
    return bound != null && options.contains(bound) ? bound : options.first;
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
      _expanded = true;
    });
    HapticFeedback.lightImpact();
    try {
      final ok = await widget.onRunStep(widget.step, _effectiveSource);
      if (!mounted) return;
      if (!ok) setState(() => _error = '未产出结果，可重试');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final step = widget.step;
    final availability = _availability;
    final locked = availability == WorkflowStepAvailability.locked;
    final hasArtifact = step.produces.isNotEmpty &&
        step.produces.every(widget.existingKinds.contains);

    // 节点状态：执行中呼吸（进度圈）/ 完成（实心）/ 失败（红）/ 待执行 / 锁定（空心）
    final node = _running
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            hasArtifact ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: hasArtifact
                ? scheme.primary
                : locked
                    ? scheme.outlineVariant
                    : scheme.outline,
          );

    final children = <Widget>[
      // 节点 + 步骤名（锁定态紧凑单行：灰显 + 缺源标记）
      Row(
        children: [
          node,
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              step.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: locked ? scheme.outlineVariant : scheme.onSurface,
              ),
            ),
          ),
          if (_running)
            Text(
              '执行中…',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else if (locked && step.consumes.isNotEmpty)
            Text(
              '需先完成${step.consumes.map(_kindLabel).join(' 或 ')}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outlineVariant,
              ),
            )
          else if (hasArtifact)
            Text(
              '已存',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
              ),
            )
          else
            TextButton(
              onPressed: () => _run(),
              child: const Text('开始'),
            ),
        ],
      ),
    ];

    // 多备选源（翻译）：嵌入式 segmented control（四轮拍板，不弹窗）
    if (!locked && !hasArtifact && !_running) {
      final options = availableSources(step, widget.existingKinds);
      if (options.length > 1) {
        final bound = _effectiveSource;
        children
          ..add(const SizedBox(height: Insets.xs))
          ..add(
            SizedBox(
              height: 32,
              child: SegmentedButton<String>(
                segments: [
                  for (final k in options)
                    ButtonSegment(value: k, label: Text(_kindLabel(k))),
                ],
                selected: {?bound},
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) widget.onSourceKindChanged(s.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                ),
              ),
            ),
          );
      }
    }

    // 产物卡（完成态，折叠摘要行；点开全文/操作区）
    if (hasArtifact) {
      final kindsWithArtifact =
          step.produces.where(widget.existingKinds.contains).toList();
      for (final k in kindsWithArtifact) {
        final text = widget.artifactText[k] ?? '';
        final meta = widget.artifactMeta[k];
        final filePath = widget.artifactFilePath[k];
        // §4 三段式「音频=波形播放条」：宿主注入播放条构建器时内联渲染
        final audioPreview = k == BlockArtifactKind.audioFile &&
                filePath != null &&
                widget.audioPreviewBuilder != null
            ? widget.audioPreviewBuilder!(filePath)
            : null;
        children
          ..add(const SizedBox(height: Insets.xs))
          ..add(
            _ArtifactCard(
              kind: k,
              text: text,
              meta: meta,
              filePath: filePath,
              elapsedMs: widget.artifactElapsedMs[k],
              audioPreview: audioPreview,
              expanded: _expanded,
              onToggle: () => setState(() => _expanded = !_expanded),
              // 空产物不给「应用」（§3.4）：audio_file 等文件类产物无文本，
              // 应用=插入空引用块是脏写入；文件类走「导出」，文本空则仅剩复制/导出
              onApply: _running || text.trim().isEmpty
                  ? null
                  : () => _apply(context, k, text),
              onCopy: text.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制')),
                        );
                      }
                    },
              // 文件类产物（字幕/音轨）：导出 = 系统分享（§3.4 动词体系）
              onExport: filePath == null ? null : () => shareArtifactFile(filePath),
              // §3.6 锚点切换：audio_file 卡「以此继续处理」（仅视频 spec 传入）
              onAnchorSwitch: k == BlockArtifactKind.audioFile && filePath != null
                  ? () => widget.onAnchorSwitch?.call(filePath)
                  : null,
              // §3.5 跳帧联动：字幕卡展开时给 cue 列表（点句定位播放）
              onCueSeek: k == BlockArtifactKind.subtitle ? widget.onCueSeek : null,
              // §4「文本=全文预览可编辑」：仅文本类产物给「编辑」——subtitle/audio_file
              // 是文件产物，改预览文本会与文件失同步（修订走重跑）
              onEditArtifact: k == BlockArtifactKind.subtitle ||
                      k == BlockArtifactKind.audioFile
                  ? null
                  : widget.onEditArtifact,
            ),
          );
      }
    }

    if (_error != null) {
      children
        ..add(const SizedBox(height: Insets.xs))
        ..add(
          Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
                ),
              ),
              TextButton(onPressed: () => _run(), child: const Text('重试')),
            ],
          ),
        );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左细进度线（§4）：节点居中，线下延至下一步
          SizedBox(
            width: 20,
            child: Column(
              children: [
                node,
                if (!widget.isLast)
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: 2,
                        child: ColoredBox(
                          color: hasArtifact ? scheme.primary : scheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Insets.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _apply(BuildContext context, String kind, String text) async {
    HapticFeedback.lightImpact();
    await _runStepApply(context, widget.step, kind, text, _effectiveSource);
  }
}

/// 产物卡（三段式，§4 拍板）：折叠 = 类型胶囊 + 摘要行；展开 = 全文预览 + 操作 chips。
class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({
    required this.kind,
    required this.text,
    this.meta,
    this.filePath,
    this.elapsedMs,
    required this.expanded,
    required this.onToggle,
    this.onApply,
    this.onCopy,
    this.onExport,
    this.onAnchorSwitch,
    this.onCueSeek,
    this.onEditArtifact,
    this.audioPreview,
  });

  final String kind;
  final String text;
  final String? meta;

  /// 文件产物路径（subtitle/audio_file 有值；非空时给「导出」chip）。
  final String? filePath;

  /// §4 卡头「耗时」：执行侧实测毫秒（null = 未记录，卡头该段缺席）。
  final int? elapsedMs;

  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onApply;
  final VoidCallback? onCopy;
  final VoidCallback? onExport;

  /// §3.6 锚点切换（仅 audio_file 卡；null = 不显示「以此继续处理」）。
  final VoidCallback? onAnchorSwitch;

  /// §3.5 跳帧联动（仅字幕卡）：点某句 cue → 打开播放器定位到 cue 起点播放。
  /// [cueIndex] = 可用 cue 列表里的序号；null = 不显示 cue 列表（视频/音频
  /// 卡无播放器打开口时）。
  final void Function(int cueIndex)? onCueSeek;

  /// §4 文本产物修订（§4「文本=全文预览可编辑」）：文本类产物卡的「编辑」入口，
  /// 返回修订文本（null=取消）；null = 不显示。
  final Future<String?> Function(String kind, String currentText)? onEditArtifact;

  /// §4 三段式「音频=波形播放条」：audio_file 卡内联播放条（宿主构建），
  /// null = 中部退化为摘要行。
  final Widget? audioPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 空 meta 不占位：宿主可能给空串（无 cues / 无文件名的文本产物），
    // 折叠态中部会渲染成一片空白——回落到首行预览才是对的。
    final summary = (meta != null && meta!.isNotEmpty)
        ? meta!
        : (text.isEmpty ? '（无文本）' : text.split('\n').first);
    final elapsedLabel = formatElapsed(elapsedMs);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.all(Insets.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 卡头（§4 三段式：类型 + 耗时 + 状态角标「已存」）：步骤名由上方
            // 轨节点行承载（同一步的多产物共用它，卡内不重复）；耗时取执行侧
            // 实测，未记录则整段缺席——不编造「0s」。
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                  child: Text(
                    _kindLabel(kind),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                if (elapsedLabel != null) ...[
                  const SizedBox(width: Insets.xs),
                  Text(
                    elapsedLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                // 状态角标「已存」（§3.4：产物完成即落库，是默认态——
                // 卡内不出现「保留」动词，避免误读「不点就丢」）
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check, size: 12, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 2),
                      Text(
                        '已存',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.xs),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            // 中部预览（§4 按 kind 分化）：音频卡 = 内联播放条（宿主构建）；
            // 其余 = 折叠摘要行 / 展开全文
            if (audioPreview != null)
              audioPreview!
            else
              Text(
                expanded ? (text.isEmpty ? '（无文本）' : text) : summary,
                maxLines: expanded ? 12 : 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
              ),
            // §3.5 跳帧联动：字幕卡展开时给 cue 列表（点某句 → 播放器定位
            // 该句起点）。cue 序号按 usableCues 过滤后的顺序（与播放器侧
            // parseSrtVtt 的过滤口径一致——两侧都以非空文本 cue 计数）。
            if (expanded && onCueSeek != null && text.isNotEmpty) ...[
              const SizedBox(height: Insets.xs),
              ...text
                  .split('\n')
                  .where((l) => l.trim().isNotEmpty)
                  .toList()
                  .asMap()
                  .entries
                  .map((e) => InkWell(
                        onTap: () => onCueSeek!(e.key),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 28,
                                child: Text(
                                  '${e.key + 1}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.outline,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  e.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Icon(Icons.play_arrow,
                                  size: 14, color: scheme.outline),
                            ],
                          ),
                        ),
                      )),
            ],
            // 底部操作区：应用/导出/复制（导出与播放由 Host 经专门回调承载，
            // 文本类产物先给应用+复制；字幕/音频的导出在 Step 7 接线）
            if (expanded) ...[
              const SizedBox(height: Insets.xs),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.xs,
                children: [
                  // §4 三段式「文本=全文预览可编辑」：修订经 onEditArtifact
                  // 打开编辑页，落库由实现方 upsert（保 filePath/meta）
                  if (onEditArtifact != null)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text('编辑'),
                      onPressed: () => onEditArtifact!(kind, text),
                    ),
                  if (onApply != null)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text('应用'),
                      onPressed: onApply,
                    ),
                  if (onExport != null)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text('导出'),
                      onPressed: onExport,
                    ),
                  // §3.6「以此继续处理」：锚点切到该产物（spec 切 audioSpec，
                  // 页头文案更新；前步产物不删，页头可切回）
                  if (onAnchorSwitch != null)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text('以此继续处理'),
                      onPressed: onAnchorSwitch,
                    ),
                  if (onCopy != null)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text('复制'),
                      onPressed: onCopy,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 实测耗时 → 卡头文案（§4 三段式）：毫秒给 ms、十秒内一位小数、超一分钟
/// 给 m:ss。null = 未记录（旧产物 / 非块通道写入）→ 卡头该段缺席。
String? formatElapsed(int? ms) {
  if (ms == null || ms < 0) return null;
  if (ms < 1000) return '${ms}ms';
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final sec = (ms / 1000).round();
  if (sec < 60) return '${sec}s';
  return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
}

/// 产物 kind → 中文标签（胶囊文案）。
String _kindLabel(String kind) => switch (kind) {
      'transcript' => '转写文本',
      'subtitle' => '字幕',
      'ocr_text' => '识别文字',
      'translation' => '译文',
      'summary' => '摘要',
      'audio_file' => '音轨',
      _ => kind,
    };

/// 块产物视图模型（三级页工作流轨数据源；页面经 Executor 从 block_artifacts 装载）。
class BlockArtifactsView {
  const BlockArtifactsView({
    this.kinds = const {},
    this.text = const {},
    this.meta = const {},
    this.filePath = const {},
    this.elapsedMs = const {},
  });

  /// 已有产物 kind 集合（§3.3 续跑判定的唯一事实源）。
  final Set<String> kinds;

  /// kind → 文本内容。
  final Map<String, String> text;

  /// kind → 摘要行（折叠态展示，如「12 段」）。
  final Map<String, String> meta;

  /// kind → 文件路径（subtitle/audio_file；导出分享用）。
  final Map<String, String> filePath;

  /// kind → 实测耗时毫秒（§4 卡头；执行侧注入 meta_json.elapsed_ms）。
  final Map<String, int> elapsedMs;

  static const empty = BlockArtifactsView();
}

/// 文件产物导出（§3.4 动词体系「导出」= 系统分享；文件不存在时明说）。
Future<void> shareArtifactFile(String path) async {
  final f = File(path);
  if (!await f.exists()) {
    debugPrint('[WorkflowTrack] artifact file missing: $path');
    return;
  }
  await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
}

/// 产物「应用」：由页面级回调承载（就近插入源媒体行正下方 / 灵感区目标选择）。
/// 此处只做跳板：页面在 BlockCapabilityExecutor 注入 onApplyArtifact。
Future<void> _runStepApply(
  BuildContext context,
  WorkflowStep step,
  String kind,
  String text,
  String? sourceKind,
) async {
  final executor = WorkflowApplyScope.maybeOf(context);
  if (executor == null) return;
  await executor.apply(kind, text);
}

/// 产物应用作用域（页面级注入；与 BlockCapabilityExecutor 同模式，
/// 工作流轨不依赖链式卡的回调形状）。
typedef WorkflowApplyFn = Future<void> Function(String kind, String text);

class WorkflowApplyScope extends InheritedWidget {
  const WorkflowApplyScope({super.key, required this.apply, required super.child});

  final WorkflowApplyFn apply;

  static WorkflowApplyScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkflowApplyScope>();

  @override
  bool updateShouldNotify(WorkflowApplyScope oldWidget) => false;
}
