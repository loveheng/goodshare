import 'dart:async';
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

  /// 写路径 FIFO 队尾（串行锁的实现载体，见 [synchronized]）。
  Future<void> _tail = Future<void>.value();

  /// **写路径串行锁（FIFO）**：把「读 → 校验 → 写」复合操作压平成一列。
  ///
  /// 为什么需要：sqflite 只保证**单条 SQL** 的原子性，保证不了动作层
  /// `_require`(读) → 校验 → `update`(写) 这种跨 `await` 的复合操作——
  /// 并发请求会在 `await` 处交错，导致「基于过期快照做校验」+「后写覆盖先写」（TOCTOU 竞态）。
  /// 大模型经 MCP 可在极短时间内甩来多个并发请求，UI 点击也会与之竞争。
  ///
  /// 零依赖实现：Dart 单线程 event loop + Future 链（不引 `pool` / `synchronized` 包）。
  ///
  /// **使用边界**：只包写路径；**读查询不得入队**，否则 MCP 写会阻塞 UI 列表刷新。
  /// 锁内不得做重活（大文件 IO / 网络），否则堵死全局写队列。
  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final next = Completer<void>();
    _tail = next.future;
    return previous.catchError((Object _) {/* 前序失败不阻断后续排队 */}).then((_) async {
      try {
        return await action();
      } finally {
        next.complete();
      }
    });
  }

  /// 批量事务：多条写命令「全成功才提交，中途出错整体回滚」（Human-AI 对称性 §4 原子性）。
  ///
  /// 事务内的读写必须走传入的 [txn]，否则读不到同一事务里上一条命令的未提交改动
  /// （如「先解锁再编辑」）。事务中不广播，提交后统一 [notifyListeners] 一次，避免 UI 抖动。
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    final db = await _database();
    final result = await db.transaction((txn) => action(txn));
    notifyListeners();
    return result;
  }

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
  /// [txn] 非空表示处于批量事务中：不单独广播，由 [transaction] 提交后统一通知。
  Future<InboxItem> add(InboxItem item, {Transaction? txn}) async {
    final db = txn ?? await _database();
    final full = (item.id == null || item.id!.isEmpty) ? item.copyWith(id: InboxItem.newId()) : item;
    await db.insert('inbox_items', full.toMap());
    if (txn == null) notifyListeners();
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
  Future<InboxItem?> byId(
    String id, {
    bool includeDeleted = false,
    bool includeVault = false,
    Transaction? txn,
  }) async {
    final db = txn ?? await _database();
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
  ///
  /// **乐观锁**：任何成功写入都会 `version + 1`。[expectedVersion] 非空时做 CAS——
  /// 版本不符则不写并返回 false（由动作层转成 `version_conflict` 冲突异常）。
  /// 返回是否实际写入。
  Future<bool> update(
    String id,
    Map<String, Object?> values, {
    int? expectedVersion,
    Transaction? txn,
  }) async {
    if (values.isEmpty) return false;
    final db = txn ?? await _database();
    final setSql = [for (final k in values.keys) '$k = ?', 'version = version + 1'].join(', ');
    final args = <Object?>[...values.values, id];
    if (expectedVersion != null) args.add(expectedVersion);
    final where = expectedVersion == null ? 'id = ?' : 'id = ? AND version = ?';
    final n = await db.rawUpdate('UPDATE inbox_items SET $setSql WHERE $where', args);
    if (n > 0 && txn == null) notifyListeners();
    return n > 0;
  }

  /// 软删除：置 is_deleted=1 并取消关联队列任务；30 天后由 purgeDeleted 物理清理。
  /// 同样受乐观锁保护（[expectedVersion]）：防止「AI 改了内容、人却删掉旧版本」。
  /// 返回是否实际删除。
  Future<bool> softDelete(String id, {int? expectedVersion, Transaction? txn}) async {
    final db = txn ?? await _database();
    final args = <Object?>[DateTime.now().millisecondsSinceEpoch, id];
    if (expectedVersion != null) args.add(expectedVersion);
    final where = expectedVersion == null ? 'id = ?' : 'id = ? AND version = ?';
    final n = await db.rawUpdate(
      'UPDATE inbox_items SET is_deleted = 1, deleted_at = ?, version = version + 1 WHERE $where',
      args,
    );
    if (n == 0) return false;
    await db.update(
      'ai_task_queue',
      {'status': 'cancelled'},
      where: "item_id = ? AND status IN ('pending', 'processing')",
      whereArgs: [id],
    );
    if (txn == null) notifyListeners();
    return true;
  }

  Future<bool> restore(String id, {Transaction? txn}) async {
    final db = txn ?? await _database();
    final n = await db.rawUpdate(
      'UPDATE inbox_items SET is_deleted = 0, deleted_at = NULL, version = version + 1 WHERE id = ?',
      [id],
    );
    if (n == 0) return false;
    if (txn == null) notifyListeners();
    return true;
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
  ///
  /// 注意：① 附件删除是文件系统副作用，**不随事务回滚**——故动作层禁止把它放进批量事务；
  /// ② **不做 CAS**——物理删除后行即消失，版本语义无意义（且先删文件再删行会留下孤儿文件）。
  Future<void> deleteForever(String id, {Transaction? txn}) async {
    final item = await byId(id, includeDeleted: true, includeVault: true, txn: txn);
    if (item == null) return;
    final f = item.rawFilePath;
    if (f != null && f.isNotEmpty) {
      try {
        final file = File(f);
        if (await file.exists()) await file.delete();
      } catch (_) {/* 附件可能已不存在，忽略 */}
    }
    final db = txn ?? await _database();
    await db.delete('inbox_items', where: 'id = ?', whereArgs: [id]);
    if (txn == null) notifyListeners();
  }

  /// 清空回收站（立即物理删除全部已删条目）。
  Future<void> purgeAllDeleted() => purgeDeleted(retention: Duration.zero);

  /// 入队后台 AI 任务（摄入与 reprocess 共用）。task_action 可空＝按 item_type 通用重构。
  Future<void> enqueueTask(String itemId, String? taskAction, {Transaction? txn}) async {
    final db = txn ?? await _database();
    await db.insert('ai_task_queue', {
      'task_id': InboxItem.newId(),
      'item_id': itemId,
      'task_action': taskAction,
      'status': 'pending',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 待处理任务总数（前台服务通知进度用）。
  Future<int> pendingCount() async {
    final db = await _database();
    final rows = await db.rawQuery(
      "SELECT COUNT(*) c FROM ai_task_queue WHERE status = 'pending'",
    );
    return rows.first['c'] as int? ?? 0;
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
      {'status': 'processing', 'updated_at': DateTime.now().millisecondsSinceEpoch},
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

  /// 心跳：刷新任务 updated_at，标记其仍在活跃处理（防止被误判为僵尸任务回收）。
  Future<void> touchTask(String taskId) async {
    final db = await _database();
    await db.update(
      'ai_task_queue',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
  }

  /// 回收僵尸任务：将 status='processing' 且 updated_at 超过 [timeout] 的任务重置为 pending。
  /// 配合消费者心跳（见 QueueConsumer），仅真正卡死（如进程被杀）的任务会被回收；
  /// 正在正常执行的耗时任务因心跳持续刷新 updated_at 不会被误杀。冷启动与 resumed 各调用一次。
  Future<int> reclaimStaleTasks({Duration timeout = const Duration(seconds: 30)}) async {
    final db = await _database();
    final threshold = DateTime.now().subtract(timeout).millisecondsSinceEpoch;
    return db.update(
      'ai_task_queue',
      {'status': 'pending'},
      where: "status = 'processing' AND (updated_at IS NULL OR updated_at < ?)",
      whereArgs: [threshold],
    );
  }

  /// 标记条目 AI 处理失败：将 is_processed 置 -1（与 [finishTask] / [claimTask] 一致的队列内部记账，非领域写）。
  /// 真正写入重构产出走 [ItemActionHandler.execute]（applyAiResult）。按 [update] 口径同步
  /// `version + 1` 并广播，使 UI 能刷新失败态。返回是否实际写入。
  Future<bool> markItemFailed(String itemId) async {
    final db = await _database();
    final n = await db.rawUpdate(
      'UPDATE inbox_items SET is_processed = -1, version = version + 1 WHERE id = ?',
      [itemId],
    );
    if (n > 0) notifyListeners();
    return n > 0;
  }

  // ---- 草稿表（drafts）：大段输入防抖落盘，进程被杀可恢复（规则一）----
  /// 草稿落盘：插入或覆盖（主键冲突替换）。
  Future<void> upsertDraft(String id, String targetId, String content) async {
    final db = await _database();
    await db.insert(
      'drafts',
      {'id': id, 'target_id': targetId, 'content': content, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取草稿正文；无则返回 null。
  Future<String?> getDraft(String id) async {
    final db = await _database();
    final rows = await db.query('drafts', columns: ['content'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['content'] as String?;
  }

  /// 删除草稿（保存 / 丢弃后调用）。
  Future<void> deleteDraft(String id) async {
    final db = await _database();
    await db.delete('drafts', where: 'id = ?', whereArgs: [id]);
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
