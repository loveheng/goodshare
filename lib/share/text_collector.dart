import 'package:shared_preferences/shared_preferences.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../models/item.dart';
import 'text_parse.dart';

/// 文本收集服务：分散 / 合并模式（设计 §4.9）+ 入库即入队（PRD 模块二）。
///
/// 合并判定（F6 决策）：同一来源 App + 窗口期（默认 5 分钟，滚动计算到末段时间）内的
/// 连续文本收集追加进同一条目——raw_content 拼接、appendix_json 记段、edit_locked=1；
/// 窗口过期或换源则开启新链。MCP add_item 不走本服务，永远独立成条。
///
/// **本服务只做「策略」（并哪条链），不做「约束」**：
/// 落库与追加一律经 `ItemActionHandler`（`CollectCommand` / `AppendSegmentCommand`），
/// 模式与窗口的校验在动作层再拦一次（防呆下沉），AI 经 MCP `append_segment` 受同一约束。
class TextCollector {
  TextCollector(this._handler);

  final ItemActionHandler _handler;

  /// 合并窗口单一事实源取自动作层，避免两处窗口漂移。
  Duration get mergeWindow => _handler.mergeWindow;

  static const _prefMode = 'collect_mode';
  static const _defaultSourceApp = 'unknown';

  String _mode = InboxItem.modeScatter;
  String get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString(_prefMode) == InboxItem.modeMerge
        ? InboxItem.modeMerge
        : InboxItem.modeScatter;
  }

  /// 切换收集模式（设置页调用）；合并模式下新收集默认锁定，须「解除编辑」后方可改。
  Future<void> setMode(String m) async {
    _mode = m == InboxItem.modeMerge ? InboxItem.modeMerge : InboxItem.modeScatter;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefMode, _mode);
  }

  /// 收集一段文本（分享 / 粘贴 / 速记便签共用入口）。
  /// 返回落库条目；空文本返回 null。
  /// 边界：纯 URL 段不参与合并、始终独立成条（否则无法被 summarize_url 单独处理）；
  /// 仅 note 段进合并链（2026-09-27 实现期收窄，F6 精神内）。
  /// [tags]：速记便签「标签」按钮挂的标签，随条目落库（分享路径不传）。
  Future<InboxItem?> collectText(String text,
      {String? sourceApp, List<String>? tags}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final src = sourceApp ?? _defaultSourceApp;
    final parsed = parseCollectedText(trimmed);
    final merging = _mode == InboxItem.modeMerge && parsed.type == InboxItem.typeNote;

    if (merging) {
      final merged = await _mergeIntoRecent(trimmed, src);
      if (merged != null) return merged;
    }

    final r = await _handler.execute(
      CollectCommand(
        itemType: parsed.type,
        sourceApp: src,
        rawContent: parsed.text,
        humanTitle: parsed.title,
        tags: (tags == null || tags.isEmpty) ? null : tags,
        collectMode: merging ? InboxItem.modeMerge : InboxItem.modeScatter,
      ),
    );
    return r.item;
  }

  /// 尝试把新段追加进最近的合并链；无可并候选返回 null（由调用方开新链）。
  Future<InboxItem?> _mergeIntoRecent(String segment, String sourceApp) async {
    final candidates = await _handler.recentMergeItems(sourceApp: sourceApp, limit: 5);
    if (candidates.isEmpty) return null;
    final windowStart = DateTime.now().subtract(mergeWindow).millisecondsSinceEpoch;
    for (final item in candidates) {
      final lastTs = [
        item.createdAt,
        if (item.appendix.isNotEmpty) item.appendix.last.ts,
      ].reduce((a, b) => a > b ? a : b);
      if (lastTs < windowStart) continue; // 超窗口：不是候选，交给调用方开新链
      return (await _handler.execute(
        AppendSegmentCommand(item.id!, segment, sourceApp: sourceApp),
      ))
          .item;
    }
    return null;
  }
}
