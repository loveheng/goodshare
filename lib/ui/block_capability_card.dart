import 'package:flutter/material.dart' hide StepState;
import 'package:flutter/services.dart';

import '../ai/capability.dart';
import '../ai/capability_chain.dart';
import 'confirm_dialog.dart';
import 'tokens.dart';

/// 媒体块能力卡（detail-two-zone.md §5.4）：单卡链式工作台——
/// 一张卡 = 一个区块的一条完整能力链，步骤卡内纵向流转、产出原地替换
/// （阶段切换非层级叠加）；关闭一次即回正文。
///
/// 预警补丁落点：
/// - 卡头来源锚点（「来自：图片第 N 块」）+ Reset 图标（危险确认后清链）；
/// - 单步失败 → 「重试当前步」+「Reset」双入口，前步产出完好；
/// - 完成态「应用」带回注目标（追加从属块默认/替换原块/发送灵感区）+
///   「复制」轻出口；
/// - 产出预览 +「编辑」弹覆盖态文本页（卡不销毁，返回自动刷新——
///   本卡只持回调，编辑页由调用方提供，#9 落地）；
/// - 中断续跑：调用方经 [initialOutputs] 传已落库产出，链从下一步续起。
class BlockCapabilityCard extends StatefulWidget {
  const BlockCapabilityCard({
    super.key,
    required this.kind,
    required this.chain,
    this.anchorLabel,
    this.onRunStep,
    this.onReset,
    this.onEditOutput,
    this.onApply,
    this.initialOutputs = const {},
  });

  final BlockKind kind;
  final CapabilityChain chain;
  final String? anchorLabel;

  /// 执行当前步（调用方组装 command 入队；完成后调 chain.completeStep）。
  final Future<String?> Function(ContentCapability step)? onRunStep;

  /// Reset 确认通过后回调（清持久层产出）。
  final Future<void> Function()? onReset;

  /// 打开覆盖态编辑页（raw 文本入参，返回修订文本；null=取消）。
  final Future<String?> Function(String raw)? onEditOutput;

  /// 回注：目标 + 文本（调用方落库）。
  final Future<void> Function(ReinjectTarget target, String text)? onApply;

  /// 已落库产出（步 index → 文本），restore 续跑用。
  final Map<int, String> initialOutputs;

  @override
  State<BlockCapabilityCard> createState() => _BlockCapabilityCardState();
}

class _BlockCapabilityCardState extends State<BlockCapabilityCard> {  @override
  void initState() {
    super.initState();
    final persisted = <String?>[
      for (var i = 0; i < widget.chain.steps.length; i++)
        widget.initialOutputs[i],
    ];
    widget.chain.restore(persisted);
  }

  Future<void> _runCurrent() async {
    final step = widget.chain.currentStep;
    if (step == null || widget.onRunStep == null) return;
    setState(() => widget.chain.beginStep());
    try {
      final raw = await widget.onRunStep!(step);
      if (!mounted) return;
      if (raw != null && raw.trim().isNotEmpty) {
        setState(() => widget.chain.completeStep(raw));
      } else {
        // 完成但无产出不是静默成功（R3）：按失败停步，状态线给 note
        setState(() => widget.chain.failStep());
      }
    } catch (e) {
      if (mounted) setState(() => widget.chain.failStep());
    }
  }

  Future<void> _reset() async {
    final confirmed = await confirmDialog(
      context,
      title: '清除本块全部产出？',
      content: '已生成的识别/转写结果将被删除，重新解析需再次消耗算力。',
      confirmText: '清除',
      danger: true,
    );
    if (confirmed != true) return;
    HapticFeedback.lightImpact();
    await widget.onReset?.call();
    if (!mounted) return;
    setState(() => widget.chain.reset());
  }

  Future<void> _edit(int stepIndex) async {
    final out = widget.chain.outputsView[stepIndex];
    if (out == null || widget.onEditOutput == null) return;
    final edited = await widget.onEditOutput!(out.raw);
    if (edited == null || !mounted) return;
    setState(() => widget.chain.editOutput(stepIndex, edited));
  }

  Future<void> _apply(ReinjectTarget target) async {
    final text = _lastEffective;
    if (text == null || widget.onApply == null) return;
    await widget.onApply!(target, text);
    if (mounted) Navigator.pop(context);
  }

  String? get _lastEffective {
    final outputs = widget.chain.outputsView;
    for (var i = outputs.length - 1; i >= 0; i--) {
      final o = outputs[i];
      if (o != null) return o.effective;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chain = widget.chain;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 卡头：来源锚点 + Reset
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.anchorLabel ?? '区块能力',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '清除结果重新解析',
                    icon: const Icon(Icons.restart_alt, size: 18),
                    onPressed: _reset,
                  ),
                ],
              ),
              // 步骤链（纵向流转，产出原地替换）
              for (var i = 0; i < chain.steps.length; i++)
                _stepTile(context, i),
              const SizedBox(height: Insets.sm),
              // 完成态：回注目标选择 + 轻出口
              if (chain.isFinished && _lastEffective != null)
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  children: [
                    _actionChip(context, '追加到正文下方', () =>
                        _apply(ReinjectTarget.append)),
                    if (widget.kind == BlockKind.text)
                      _actionChip(context, '替换原文', () =>
                          _apply(ReinjectTarget.replace)),
                    _actionChip(context, '发送至灵感区', () =>
                        _apply(ReinjectTarget.inspiration)),
                    _actionChip(context, '复制', () async {
                      await Clipboard.setData(
                        ClipboardData(text: _lastEffective!),
                      );
                      if (context.mounted) Navigator.pop(context);
                    }),
                  ],
                ),
            ],
          ),
        ),
    );
  }

  Widget _stepTile(BuildContext context, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chain = widget.chain;
    final step = chain.steps[index];
    final state = chain.statesView[index];
    final isCurrent = index == chain.current && !chain.isFinished;
    final output = chain.outputsView[index];

    final icon = switch (state) {
      StepState.done => Icon(Icons.check_circle, size: 20, color: scheme.primary),
      StepState.running => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      StepState.failed => Icon(Icons.error_outline, size: 20, color: scheme.error),
      StepState.pending => Icon(
          Icons.radio_button_unchecked,
          size: 20,
          color: isCurrent ? scheme.primary : scheme.outline,
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        children: [
          icon,
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: state == StepState.done || output != null
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (output != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    output.effective,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onEditOutput != null)
                        TextButton(
                          onPressed: () => _edit(index),
                          child: const Text('编辑'),
                        ),
                      if (output.isEdited)
                        TextButton(
                          onPressed: () =>
                              setState(() => output.edited = null),
                          child: const Text('显示原始识别结果'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // 运行键：当前 pending/failed 步
          if (isCurrent || state == StepState.failed)
            TextButton(
              onPressed: state == StepState.running
                  ? null
                  : () {
                      if (state == StepState.failed) chain.retry();
                      _runCurrent();
                    },
              child: Text(state == StepState.failed ? '重试' : '开始'),
            ),
        ],
      ),
    );
  }

  Widget _actionChip(
    BuildContext context,
    String label,
    VoidCallback onPressed,
  ) {
    return ActionChip(label: Text(label), onPressed: onPressed);
  }
}

