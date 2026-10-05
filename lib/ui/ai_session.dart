import 'dart:async';

import 'package:flutter/material.dart';

import '../action/commands.dart' show AiSessionCommand, AiSessionPhase;
import '../models/item.dart';
import 'tokens.dart';

/// 接管 settle 窗口（ai-writeback-revert §5 / §8.2 / §8.3）。
///
/// 为什么要延迟：用户手滑多打的字，在窗口内删掉则会话毫发无损；`Ctrl+Z`
/// 也只需恢复文本，不必重建会话态。落库翻转延迟到「编辑停顿 1.5s」。
const Duration kAiSettleWindow = Duration(milliseconds: 1500);

/// 库态 → 会话相位。
///
/// **§3.1 不变量的归一出口**：基线为空 ⟺ 无未关闭会话。即使外部把
/// `ai_session_state` 写成了 pending 而基线为空（写坏 / 旧数据），这里也
/// 一律归一为 idle——宁可不挂悬浮条，也不挂一个「点了还原毫无变化」的
/// 空会话。
AiSessionPhase aiSessionPhaseOf(InboxItem item) {
  final baseline = item.humanMdBaseline;
  if (baseline == null || baseline.isEmpty) return AiSessionPhase.idle;
  return switch (item.aiSessionState) {
    'restored' => AiSessionPhase.restored,
    'pending' => AiSessionPhase.pending,
    _ => AiSessionPhase.idle,
  };
}

/// 接管判定（§8.2）：以**进入状态时的快照**为基准，`trim` 后比较。
///
/// - 纯首尾空格 / 换行误触不算接管（`trim` 已涵盖）；
/// - 光标 / 选区移动不产生 `onChanged`，根本不会走到这里；
/// - 手滑打字又删回原样 → 判定未接管，悬浮条保留、会话继续。
bool isAiTakeover(String currentText, String sessionStartText) =>
    currentText.trim() != sessionStartText.trim();

/// AI 写回会话状态机（ai-writeback-revert §4/§5/§8）。
///
/// 职责边界：**只管会话态与接管判定**，不管文本怎么渲染、不管编辑器怎么
/// 存盘——正文的读与写全由宿主经闭包注入（`readText` / `apply`），本类
/// 因此可脱离 Flutter widget 树与真实数据库单测。
///
/// 三态迁移：
/// ```text
/// CLOSED(idle) --AI写回--> PENDING --点[还原]--> RESTORED
///     ^                       |                     |
///     |                    接管(手改)             接管(手改)
///     +----------------------+---------------------+
/// ```
/// PENDING/RESTORED 下用户手动改字 → [noteUserEdit] 起 settle 计时器 →
/// 到期（或 [flush] 强制）以**实时库态 + 实时文本**判定是否真接管。
class AiSessionController extends ChangeNotifier {
  AiSessionController({
    required this.itemId,
    required this.readItem,
    required this.readLatestAi,
    required this.apply,
    required this.readText,
    this.settle = kAiSettleWindow,
  });

  final String itemId;

  /// 实时读条目（防竞态：判定一律以库里的最新态为准，§8.7）。
  final Future<InboxItem?> Function() readItem;

  /// 读 `ai_revisions` 最新条快照（PENDING 的「AI 版」与 RESTORED 的恢复源）。
  final Future<String?> Function() readLatestAi;

  /// 会话态落库（唯一写入口 = ItemActionHandler）。
  final Future<Object?> Function(AiSessionCommand cmd) apply;

  /// 读编辑器活文本（保存前的手改也必须计入接管判定）。
  final String Function() readText;

  final Duration settle;

  AiSessionPhase _phase = AiSessionPhase.idle;
  String? _baseline;
  Timer? _settleTimer;
  bool _disposed = false;

  /// 接管闭环后回调（宿主弹 Toast：非阻断，恢复能力交给历史面板）。
  VoidCallback? onTakeover;

  AiSessionPhase get phase => _phase;

  String? get baseline => _baseline;

  /// 是否有「未关闭且可操作」的会话（悬浮条显隐依据）。
  bool get isOpen =>
      _phase != AiSessionPhase.idle && (_baseline?.isNotEmpty ?? false);

  /// 用最新条目快照对齐内存态（页面刷新 / 外部写回后调用）。
  ///
  /// 相位或基线发生变化时也取消 pending 的 settle 计时器：外部已改写了
  /// 会话态，旧的接管判定基准随即失效（§8.7 同源口径）。
  void sync(InboxItem item) {
    final phase = aiSessionPhaseOf(item);
    final baseline = item.humanMdBaseline;
    if (phase == _phase && baseline == _baseline) return;
    _phase = phase;
    _baseline = baseline;
    _cancelSettle();
    notifyListeners();
  }

  /// 用户在编辑器里改了字（宿主 `onChanged` 接入）：会话未开则完全无感，
  /// 已开则**重置** settle 计时器（连续输入只在最后一次停顿后判定一次）。
  void noteUserEdit() {
    if (_phase == AiSessionPhase.idle) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, _onSettle);
  }

  /// 显式操作优先（§8.7）：悬浮条任意按钮点击时第一时间取消 pending 计时器
  /// 并阻断其落库回调，杜绝「点还原后计时器到期误判接管」的竞态。
  void cancelSettle() => _cancelSettle();

  /// 生命周期强制落定（§8.3）：编辑器 dispose / 路由离开 / 切后台时调用。
  ///
  /// settle 把状态翻转延迟了 1.5s，期间若 App 被杀或切后台，DB 仍停在旧
  /// 会话态而文本已是手改版 → 重开时状态/文本 mismatch。故这些点必须
  /// 立即提交（含当前文本与状态翻转，缺一不可）。
  Future<void> flush() async {
    _cancelSettle();
    await _evaluate();
  }

  /// 还原到基线（AI 动笔前）。返回应灌回编辑器的正文，无会话则 null。
  Future<String?> restore() async {
    _cancelSettle();
    // 实时读（不依赖内存旧值）：悬浮条可能在库态已被别处改写后才被点到。
    final item = await readItem();
    if (item == null) return null;
    final base = item.humanMdBaseline;
    if (base == null || base.isEmpty) return null;
    await apply(AiSessionCommand(itemId, phase: AiSessionPhase.restored));
    if (_disposed) return base;
    _phase = AiSessionPhase.restored;
    _baseline = base;
    notifyListeners();
    return base;
  }

  /// 换回 AI 版（恢复源 = `ai_revisions` 最新条，§3.2）。
  /// 返回应灌回编辑器的正文，无快照则 null。
  Future<String?> reapplyAi() async {
    _cancelSettle();
    final ai = await readLatestAi();
    if (ai == null || ai.isEmpty) return null;
    await apply(
      AiSessionCommand(itemId, phase: AiSessionPhase.pending, humanMd: ai),
    );
    if (_disposed) return ai;
    _phase = AiSessionPhase.pending;
    notifyListeners();
    return ai;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSettle();
    super.dispose();
  }

  void _cancelSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  Future<void> _onSettle() async {
    _settleTimer = null;
    await _evaluate();
  }

  /// 接管判定与闭环。**每次都以实时库态 + 实时文本为准**（§8.7）——
  /// 绝不依赖计时器闭包捕获的旧相位 / 旧基线。
  Future<void> _evaluate() async {
    final item = await readItem();
    if (item == null || _disposed) return;
    final phase = aiSessionPhaseOf(item);
    if (phase == AiSessionPhase.idle) return;
    final current = readText();
    // 进入状态时的快照：RESTORED=基线；PENDING=AI 版（取 ai_revisions 最新条，
    // 与 §3.2 同口径，不在 Meta 冗余存全文）。
    final start = phase == AiSessionPhase.restored
        ? (item.humanMdBaseline ?? '')
        : (await readLatestAi()) ?? (item.humanMd ?? '');
    if (!isAiTakeover(current, start)) return; // 删回原样 → 未接管，会话保留
    await _close(text: current);
  }

  /// 接管闭环（§5）：基线置 null + 会话关闭 + 当前文本落库，一步事务完成。
  ///
  /// 被放弃的 AI 版无需在此重复追加 `ai_revisions`——它在写回时已由
  /// `apply_ai_result` 落过一条（§5 步骤 1 的持久留痕由此成立），此处只负责
  /// 闭环与留好「可找回」的入口（Toast → 历史面板）。
  Future<void> _close({required String text}) async {
    await apply(
      AiSessionCommand(itemId, phase: AiSessionPhase.idle, humanMd: text),
    );
    if (_disposed) return;
    _phase = AiSessionPhase.idle;
    _baseline = null;
    notifyListeners();
    onTakeover?.call();
  }
}

/// AI 会话悬浮条（ai-writeback-revert §7）。
///
/// 非阻断、无确认框：AI_PENDING 给「查看对比 / 还原」，RESTORED 给
/// 「恢复 AI 改动」。原 `[接受]` 已按设计移除——满意时的自然动作是继续
/// 打字触发接管、或关文档触发 Settle，悬浮条随之退场。
class AiSessionBar extends StatelessWidget {
  const AiSessionBar({
    super.key,
    required this.phase,
    required this.summary,
    required this.onViewDiff,
    required this.onRestore,
    required this.onReapply,
  });

  final AiSessionPhase phase;
  final String summary;

  final VoidCallback onViewDiff;
  final VoidCallback onRestore;
  final VoidCallback onReapply;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final restored = phase == AiSessionPhase.restored;
    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.md, Insets.xs, Insets.md, 0),
      padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.sm, Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            restored ? Icons.history_rounded : Icons.auto_awesome_rounded,
            size: 18,
            color: scheme.primary,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  restored ? '已还原到你的版本' : 'AI 已改写这篇',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!restored && summary.isNotEmpty)
                  Text(
                    summary,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (!restored)
            TextButton(onPressed: onViewDiff, child: const Text('查看对比')),
          TextButton(
            onPressed: restored ? onReapply : onRestore,
            child: Text(restored ? '恢复 AI 改动' : '还原'),
          ),
        ],
      ),
    );
  }
}
