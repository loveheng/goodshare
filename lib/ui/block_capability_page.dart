import 'package:flutter/material.dart';

import '../ai/capability.dart';
import '../ai/capability_chain.dart';
import 'block_capability_card.dart';
import 'tokens.dart';

/// 区块三级能力页（detail-two-zone.md §5.1 四版拍板 2026-10-01）：
/// 文本块划词菜单「AI 处理本段」/ 媒体块长按 = **单入口直进本页**——不再弹
/// 能力清单菜单；资源预览 + 全部适用能力（链式步骤）+ 产出回注/Reset 一页
/// 承载（原「能力卡」BottomSheet 合并入页）。
///
/// 链 = [capabilitiesFor(kind)] 全量按序编排（识别/转写 → 翻译 → 摘要），
/// 所有能力都在页内呈现，长按菜单层不复存在。
class BlockCapabilityPage extends StatelessWidget {
  const BlockCapabilityPage({
    super.key,
    required this.kind,
    required this.chain,
    this.anchorLabel,
    this.preview,
    this.initialOutputs = const {},
    required this.onRunStep,
    required this.onReset,
    required this.onEditOutput,
    required this.onApply,
    required this.onRunStandalone,
  });

  final CapabilityChain chain;

  /// 块类型（能力卡的回注目标选项按类型分化：替换原文仅文本块）。
  final BlockKind kind;

  /// 来源锚点（「来自：图片块」，卡头展示）。
  final String? anchorLabel;

  /// 资源预览（Host 传入被长按块的已渲染形态；音频条出页后播放能力
  /// 随播放服务作用域降级，仅作占位预览——可接受）。
  final Widget? preview;

  final Map<int, String> initialOutputs;
  final Future<String?> Function(ContentCapability step) onRunStep;
  final Future<void> Function() onReset;
  final Future<String?> Function(String raw) onEditOutput;
  final Future<void> Function(ReinjectTarget target, String text) onApply;
  final Future<void> Function(String capabilityId) onRunStandalone;

  @override
  Widget build(BuildContext context) {
    final standalone = standaloneFor(kind);
    return Scaffold(
      appBar: AppBar(
        // 出口=返回手势/箭头（与详情页二级页同口径）
        automaticallyImplyLeading: false,
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        title: const Text('区块能力'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    Insets.md,
                    Insets.lg,
                    0,
                  ),
                  child: preview,
                ),
              // 卡内链式工作台（含卡头锚点 + Reset 二次确认）
              BlockCapabilityCard(
                kind: kind,
                chain: chain,
                anchorLabel: anchorLabel,
                initialOutputs: initialOutputs,
                onRunStep: onRunStep,
                onReset: onReset,
                onEditOutput: onEditOutput,
                onApply: onApply,
              ),
              // 独立能力（链外单发：分类/条码/分析/切片/整片，产出不回注）
              if (standalone.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.lg,
                    0,
                    Insets.lg,
                    Insets.xl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '独立能力',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                              onPressed: () => onRunStandalone(c.id),
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
    );
  }
}

/// 三级能力页入口：长按唤出后直进（rootNavigator 全屏，返回手势三态
/// 口径——页内再开的编辑页只关编辑页）。
Future<void> showBlockCapabilityPage(
  BuildContext context, {
  required BlockKind kind,
  required CapabilityChain chain,
  String? anchorLabel,
  Widget? preview,
  Map<int, String> initialOutputs = const {},
  required Future<String?> Function(ContentCapability step) onRunStep,
  required Future<void> Function() onReset,
  required Future<String?> Function(String raw) onEditOutput,
  required Future<void> Function(ReinjectTarget target, String text) onApply,
  required Future<void> Function(String capabilityId) onRunStandalone,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => BlockCapabilityPage(
        kind: kind,
        chain: chain,
        anchorLabel: anchorLabel,
        preview: preview,
        initialOutputs: initialOutputs,
        onRunStep: onRunStep,
        onReset: onReset,
        onEditOutput: onEditOutput,
        onApply: onApply,
        onRunStandalone: onRunStandalone,
      ),
    ),
  );
}
