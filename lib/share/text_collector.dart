import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/repository.dart';
import '../models/item.dart';
import 'text_parse.dart';

/// 文本收集服务：分散 / 合并模式（设计 §4.9）+ 入库即入队（PRD 模块二）。
///
/// 合并判定（F6 决策）：同一来源 App + 窗口期（默认 5 分钟，滚动计算到末段时间）内的
/// 连续文本收集追加进同一条目——raw_content 拼接、appendix_json 记段、edit_locked=1；
/// 窗口过期或换源则开启新链。MCP add_item 不走本服务，永远独立成条。
class TextCollector {
  TextCollector(this._repo, {this.mergeWindow = const Duration(minutes: 5)});

  final Repository _repo;
  final Duration mergeWindow;

  static const _prefMode = 'collect_mode';

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

  /// 收集一段文本（分享 / 粘贴 / FAB 速记共用入口）。
  /// 返回落库条目；空文本返回 null。
  /// 边界：纯 URL 段不参与合并、始终独立成条（否则无法被 summarize_url 单独处理）；
  /// 仅 note 段进合并链（2026-09-27 实现期收窄，F6 精神内）。
  Future<InboxItem?> collectText(String text, {String? sourceApp}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final parsed = parseCollectedText(trimmed);
    final merging = _mode == InboxItem.modeMerge && parsed.type == InboxItem.typeNote;

    if (merging) {
      final merged = await _mergeIntoRecent(trimmed, sourceApp);
      if (merged != null) return merged;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final saved = await _repo.add(InboxItem(
      itemType: parsed.type,
      sourceType: parsed.type,
      sourceApp: sourceApp,
      humanTitle: parsed.title,
      rawContent: parsed.text,
      collectMode: merging ? InboxItem.modeMerge : InboxItem.modeScatter,
      editLocked: merging,
      // 合并模式下首段同样记入 appendix（spec：每段记录 {ts,text,source}）
      appendix: merging
          ? [AppendixEntry(ts: now, text: parsed.text, source: sourceApp)]
          : const [],
      createdAt: now,
    ));
    await _repo.enqueueTask(saved.id!, Repository.taskActionFor(parsed.type));
    return saved;
  }

  /// 尝试把新段追加进最近的合并链；无可并候选返回 null。
  Future<InboxItem?> _mergeIntoRecent(String segment, String? sourceApp) async {
    final candidates = await _repo.recentMergeItems(sourceApp: sourceApp, limit: 5);
    if (candidates.isEmpty) return null;
    final windowStart = DateTime.now().subtract(mergeWindow).millisecondsSinceEpoch;
    for (final item in candidates) {
      final lastTs = [
        item.createdAt,
        if (item.appendix.isNotEmpty) item.appendix.last.ts,
      ].reduce((a, b) => a > b ? a : b);
      if (lastTs >= windowStart) return _append(item, segment, sourceApp);
    }
    return null;
  }

  Future<InboxItem> _append(InboxItem item, String segment, String? sourceApp) async {
    final entry = AppendixEntry(
      ts: DateTime.now().millisecondsSinceEpoch,
      text: segment,
      source: sourceApp,
    );
    final appendix = [...item.appendix, entry];
    await _repo.update(item.id!, {
      'raw_content': '${item.rawContent ?? ''}\n$segment',
      'appendix_json': jsonEncode([for (final a in appendix) a.toJson()]),
    });
    final merged = (await _repo.byId(item.id!, includeVault: true))!;
    await _repo.enqueueTask(item.id!, Repository.taskActionFor(merged.itemType));
    return merged;
  }
}
