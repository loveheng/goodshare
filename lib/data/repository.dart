import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/item.dart';
import 'db.dart';

/// 收集数据仓库：UI 与 MCP 工具共用的唯一入口。
/// 查询默认排除 Vault 与已删条目（PRD §7 隐私硬约束：
/// Machine-Readable 侧等价于 WHERE is_vault=0 AND is_deleted=0）。
class Repository extends ChangeNotifier {
  Database? _db;

  Future<Database> _database() async => _db ??= await Db.instance();

  // ai_task_queue 的 task_action 枚举（PRD §5.3）
  static const taskParseChatlog = 'parse_chatlog';
  static const taskOcrAndExtract = 'ocr_and_extract';
  static const taskSummarizeUrl = 'summarize_url';
  static const taskTranscribeAudio = 'transcribe_audio';

  /// item_type → 默认队列动作；note/document 无专属动作返回 null（消费者按类型通用重构）。
  static String? taskActionFor(String itemType) => switch (itemType) {
        InboxItem.typeUrl => taskSummarizeUrl,
        InboxItem.typeImage => taskOcrAndExtract,
        InboxItem.typeChatlog => taskParseChatlog,
        InboxItem.typeAudio => taskTranscribeAudio,
        _ => null,
      };

  /// 入库；id 为空时生成 uuid。返回带 id 的完整条目。
  Future<InboxItem> add(InboxItem item) async {
    final db = await _database();
    final full = (item.id == null || item.id!.isEmpty) ? item.copyWith(id: InboxItem.newId()) : item;
    await db.insert('inbox_items', full.toMap());
    notifyListeners();
    return full;
  }

  /// 列表/搜索：默认仅公开（非 Vault）且未删除条目。
  /// 关键词命中标题 / 原文 / 标签 / 人类态；type 为空则不过滤。
  Future<List<InboxItem>> list({
    String? query,
    String? type,
    bool vault = false,
    bool includeDeleted = false,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await _database();
    final (where, args) = _filters(
      query: query,
      type: type,
      vault: vault,
      includeDeleted: includeDeleted,
    );
    final rows = await db.query(
      'inbox_items',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC, rowid DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(InboxItem.fromMap).toList();
  }

  Future<int> count({String? query, String? type, bool vault = false}) async {
    final db = await _database();
    final (where, args) = _filters(query: query, type: type, vault: vault);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) c FROM inbox_items WHERE $where',
      args,
    );
    return rows.first['c'] as int? ?? 0;
  }

  /// 单条读取；默认不可见 Vault 与已删条目（MCP 走默认即安全）。
  Future<InboxItem?> byId(String id, {bool includeDeleted = false, bool includeVault = false}) async {
    final db = await _database();
    final conds = ['id = ?'];
    final args = <Object?>[id];
    if (!includeDeleted) conds.add('is_deleted = 0');
    if (!includeVault) conds.add('is_vault = 0');
    final rows = await db.query(
      'inbox_items',
      where: conds.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return InboxItem.fromMap(rows.first);
  }

  /// 「最近删除」（保留期内可恢复）。
  Future<List<InboxItem>> listDeleted({int limit = 200}) async {
    final db = await _database();
    final rows = await db.query(
      'inbox_items',
      where: 'is_deleted = 1',
      orderBy: 'deleted_at DESC',
      limit: limit,
    );
    return rows.map(InboxItem.fromMap).toList();
  }

  /// 某天的公开条目（本机时区；供 get_timeline_context 时光机上下文）。
  Future<List<InboxItem>> listByDate(String date, {int limit = 200}) async {
    final db = await _database();
    final rows = await db.rawQuery(
      "SELECT * FROM inbox_items WHERE is_vault = 0 AND is_deleted = 0 "
      "AND date(created_at/1000, 'unixepoch', 'localtime') = ? "
      'ORDER BY created_at ASC LIMIT ?',
      [date, limit],
    );
    return rows.map(InboxItem.fromMap).toList();
  }

  /// 按 id 更新列。values 的键必须是 inbox_items 合法列名，由调用方（ItemActionHandler）保证。
  Future<void> update(String id, Map<String, Object?> values) async {
    final db = await _database();
    await db.update('inbox_items', values, where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// 软删除：置 is_deleted=1 并取消关联队列任务；30 天后由 purgeDeleted 物理清理。
  Future<void> softDelete(String id) async {
    final db = await _database();
    await db.update('inbox_items', {
      'is_deleted': 1,
      'deleted_at': DateTime.now().millisecondsSinceEpoch,
    }, where: 'id = ?', whereArgs: [id]);
    await db.update(
      'ai_task_queue',
      {'status': 'cancelled'},
      where: "item_id = ? AND status IN ('pending', 'processing')",
      whereArgs: [id],
    );
    notifyListeners();
  }

  Future<void> restore(String id) async {
    final db = await _database();
    await db.update(
      'inbox_items',
      {'is_deleted': 0, 'deleted_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  /// 物理清理超过保留期的已删条目，一并删除本 app 复制落盘的附件。
  /// 返回清理条数；返回 0 时不广播（例行任务常态）。
  /// 注意比较用 <=：retention 为 0 时 cutoff 与清理时间同毫秒，< 会漏删同毫秒条目（CI 实测 flake）。
  Future<int> purgeDeleted({Duration retention = const Duration(days: 30)}) async {
    final db = await _database();
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    final rows = await db.query(
      'inbox_items',
      columns: ['id', 'raw_file_path'],
      where: 'is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at <= ?',
      whereArgs: [cutoff],
    );
    for (final r in rows) {
      final f = r['raw_file_path'] as String?;
      if (f != null && f.isNotEmpty) {
        try {
          final file = File(f);
          if (await file.exists()) await file.delete();
        } catch (_) {/* 附件可能已不存在，忽略 */}
      }
      await db.delete('inbox_items', where: 'id = ?', whereArgs: [r['id']]);
    }
    if (rows.isNotEmpty) notifyListeners();
    return rows.length;
  }

  /// 立即彻底删除单条已删条目（含附件），不保留恢复窗口（最近删除页手动操作）。
  Future<void> deleteForever(String id) async {
    final item = await byId(id, includeDeleted: true, includeVault: true);
    if (item == null) return;
    final f = item.rawFilePath;
    if (f != null && f.isNotEmpty) {
      try {
        final file = File(f);
        if (await file.exists()) await file.delete();
      } catch (_) {/* 附件可能已不存在，忽略 */}
    }
    final db = await _database();
    await db.delete('inbox_items', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// 清空回收站（立即物理删除全部已删条目）。
  Future<void> purgeAllDeleted() => purgeDeleted(retention: Duration.zero);

  /// 入队后台 AI 任务（摄入与 reprocess 共用）。task_action 可空＝按 item_type 通用重构。
  Future<void> enqueueTask(String itemId, String? taskAction) async {
    final db = await _database();
    await db.insert('ai_task_queue', {
      'task_id': InboxItem.newId(),
      'item_id': itemId,
      'task_action': taskAction,
      'status': 'pending',
    });
  }

  /// 待处理队列任务快照（占位消费者接管，先进先出）。
  Future<List<Map<String, Object?>>> pendingTasks({int limit = 20}) async {
    final db = await _database();
    return db.query(
      'ai_task_queue',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'rowid',
      limit: limit,
    );
  }

  /// 认领任务：pending → processing。返回是否认领成功（已取消/已认领则否）。
  Future<bool> claimTask(String taskId) async {
    final db = await _database();
    final n = await db.update(
      'ai_task_queue',
      {'status': 'processing'},
      where: 'task_id = ? AND status = ?',
      whereArgs: [taskId, 'pending'],
    );
    return n > 0;
  }

  /// 结束任务：completed / failed / cancelled。
  Future<void> finishTask(String taskId, String status) async {
    final db = await _database();
    await db.update('ai_task_queue', {'status': status}, where: 'task_id = ?', whereArgs: [taskId]);
  }

  /// 合并模式的追加候选：最近的 merge 条目（同来源、公开、未删），窗口过滤由调用方按末段时间做。
  Future<List<InboxItem>> recentMergeItems({String? sourceApp, int limit = 5}) async {
    final db = await _database();
    final rows = await db.query(
      'inbox_items',
      where: "collect_mode = 'merge' AND is_deleted = 0 AND is_vault = 0 AND source_app IS ?",
      whereArgs: [sourceApp],
      orderBy: 'created_at DESC, rowid DESC',
      limit: limit,
    );
    return rows.map(InboxItem.fromMap).toList();
  }

  (String, List<Object?>) _filters({
    String? query,
    String? type,
    bool vault = false,
    bool includeDeleted = false,
  }) {
    final where = <String>['is_vault = ?'];
    final args = <Object?>[vault ? 1 : 0];
    if (!includeDeleted) where.add('is_deleted = 0');
    final q = query?.trim() ?? '';
    if (q.isNotEmpty) {
      final like = '%$q%';
      where.add('(human_title LIKE ? OR raw_content LIKE ? OR human_md LIKE ? OR tags LIKE ?)');
      args.addAll([like, like, like, like]);
    }
    if (type != null && type.isNotEmpty) {
      where.add('item_type = ?');
      args.add(type);
    }
    return (where.join(' AND '), args);
  }
}
