import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../ai/video_clips.dart';
import '../models/item.dart';
import '../models/workspace.dart';
import 'db.dart';

/// 列表排序（2026-09-30：时光机降为主列表的「排序维度」后新增）。
///
/// 原实现把 `created_at DESC` 硬编码在 `list()` 里，时间维度的正序 / 倒序
/// 无从表达。排序值只在此处定义，避免 SQL 片段散落调用方。
enum ItemSort {
  /// 最新在前（默认，与历史行为一致）。
  newest('created_at DESC, rowid DESC'),

  /// 最早在前（时光机的「从头看」）。
  oldest('created_at ASC, rowid ASC');

  const ItemSort(this.orderBy);

  /// 直接用于 sqflite `orderBy` 的片段（唯一定义处）。
  final String orderBy;
}

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
  static const taskTranslate = 'translate';
  // 图片分类（ML Kit Image Labeling，2026-09-29）：仅手动触发，产出写入 facets['分类']
  static const taskClassifyImage = 'classify_image';
  // 条码 / 二维码扫描（ML Kit Barcode Scanning，2026-09-29）：仅手动触发，产出写入 facets['条码']
  static const taskScanBarcode = 'scan_barcode';
  // 文本分析（ML Kit Language ID + Entity Extraction，2026-09-29）：仅笔记手动触发，
  // 产出写入 facets['语言'] 与 facets['实体']
  static const taskAnalyzeText = 'analyze_text';
  // 图片主色提取（palette_generator，2026-09-30 V3）：摄入自动入队（唯一自动跑的
  // 图片任务——非模型推理，64px 降采样量化，毫秒级），hex 落 machine_json color.v1
  static const taskExtractPalette = 'extract_palette';
  // 文档扫描（ML Kit Document Scanner，2026-09-29）：前台相机流，不经队列，
  // 产出直接新建条目；仅作 handles 契约占位与 UI taskAction 对齐用
  static const taskScanDocument = 'scan_document';
  // 端侧 LLM 任务动作（2026-09-28，设计见 docs/design/on-device-llm.md §5）：
  // 摘要 / 关键词均由专门命令显式入队（手动触发，绝不自动入队）。
  static const taskLlmSummarize = 'llm_summarize';
  static const taskLlmTags = 'llm_tags';

  // 视频切片（2026-09-29，设计 docs/design/video-clips.md）：区间编码进动作串
  // （队列表无参数列，与 translate:<lang> 同口径）。
  static const taskClipPrefix = 'clip:';

  /// 视频切片任务动作：`clip:<startMs>-<endMs>:<steps>`（步骤字母 e/t/s，见
  /// video_clips.dart 的 normalizeClipSteps——E2 摘要自动带动转写前置）。
  static String clipTaskAction(int startMs, int endMs, List<String> steps) {
    final letters = [for (final s in normalizeClipSteps(steps)) switch (s) {
      'extract' => 'e',
      'transcribe' => 't',
      'summary' => 's',
      _ => '',
    }];
    return '$taskClipPrefix$startMs-$endMs:${letters.join()}';
  }

  /// 解析 clip 任务动作；非 clip 前缀 / 格式坏 / 步骤为空 → null。
  static (int, int, List<String>)? parseClipTaskAction(String? action) {
    if (action == null || !action.startsWith(taskClipPrefix)) return null;
    final m = RegExp(r'^clip:(\d+)-(\d+):([ets]{1,3})$').firstMatch(action);
    if (m == null) return null;
    final steps = <String>[
      for (final ch in m.group(3)!.split(''))
        if (ch == 'e') 'extract' else if (ch == 't') 'transcribe' else if (ch == 's') 'summary',
    ];
    if (steps.isEmpty) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!), steps);
  }

  /// translate 任务动作串：可带目标语言后缀（`translate` / `translate:ja`）。
  /// 队列表无参数列，故把「单次指定的目标语言」编码进动作串，避免为一次覆盖加列。
  static String translateTaskAction([String? lang]) =>
      (lang == null || lang.isEmpty) ? taskTranslate : '$taskTranslate:$lang';

  /// 是否为翻译类任务动作。
  static bool isTranslateAction(String? action) =>
      action == taskTranslate || (action?.startsWith('$taskTranslate:') ?? false);

  /// 取任务动作串里携带的目标语言；无则 null（表示沿用设置项）。
  static String? translateTargetOf(String? action) {
    if (action == null || !action.startsWith('$taskTranslate:')) return null;
    final lang = action.substring(taskTranslate.length + 1).trim();
    return lang.isEmpty ? null : lang;
  }

  /// transcribe 任务动作串：可带字幕译文模式与目标语言后缀——
  /// `transcribe_audio` / `transcribe_audio:bilingual` / `transcribe_audio:bilingual:en`。
  /// 队列表无参数列，与 `translate:<lang>` / `clip:<start>-<end>` 同口径：
  /// 把「单次指定的字幕模式 / 目标语言」编码进动作串做任务级覆盖（MCP transcribe_item），
  /// 缺省沿用设置项。模式白名单见 [transcribeSubtitleModes]。
  static const transcribeSubtitleModes = ['sourceOnly', 'bilingual', 'separate'];

  static String transcribeTaskAction({String? subtitleMode, String? targetLang}) {
    final mode = (subtitleMode ?? '').trim();
    final lang = (targetLang ?? '').trim();
    if (mode.isEmpty && lang.isEmpty) return taskTranscribeAudio;
    final suffix = [if (mode.isNotEmpty) mode, if (lang.isNotEmpty) lang].join(':');
    return '$taskTranscribeAudio:$suffix';
  }

  /// 是否为转写类任务动作（含带覆盖后缀的变体）。
  static bool isTranscribeAction(String? action) =>
      action == taskTranscribeAudio ||
      (action?.startsWith('$taskTranscribeAudio:') ?? false);

  /// 取任务动作串里携带的字幕译文模式；无 / 坏值 → null（沿用设置项）。
  static String? transcribeSubtitleModeOf(String? action) {
    if (action == null || !action.startsWith('$taskTranscribeAudio:')) return null;
    final first = action.substring(taskTranscribeAudio.length + 1).split(':').first.trim();
    return transcribeSubtitleModes.contains(first) ? first : null;
  }

  /// 取任务动作串里携带的目标语言；无 → null（沿用设置项）。
  /// 语义与位置绑定：`transcribe_audio:<mode>:<lang>` 中 lang 恒为第二段；
  /// mode 段缺省时动作串不会带 lang（构造端保证）。
  static String? transcribeTargetLangOf(String? action) {
    if (action == null || !action.startsWith('$taskTranscribeAudio:')) return null;
    final parts = action.substring(taskTranscribeAudio.length + 1).split(':');
    if (parts.length < 2) return null;
    final lang = parts[1].trim();
    return lang.isEmpty ? null : lang;
  }

  /// item_type → 默认队列动作；note/document 无专属动作返回 null（消费者按类型通用重构）。
  static String? taskActionFor(String itemType) => switch (itemType) {
        InboxItem.typeUrl => taskSummarizeUrl,
        InboxItem.typeChatlog => taskParseChatlog,
        // 图片摄入自动跑主色提取（V3，非模型推理毫秒级）；OCR 保持手动
        // （2026-09-28 拍板只存文件）——录音转写由 TranscribeCommand 入队
        // taskTranscribeAudio，图片 OCR 由 OcrCommand 入队 taskOcrAndExtract。
        InboxItem.typeImage => taskExtractPalette,
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
  ///
  /// [sort] 排序（2026-09-30：时光机降为主列表的排序维度后，排序不再是硬编码）。
  Future<List<InboxItem>> list({
    String? query,
    String? type,
    bool vault = false,
    bool includeDeleted = false,
    ItemSort sort = ItemSort.newest,
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
      orderBy: sort.orderBy,
      limit: limit,
      offset: offset,
    );
    return rows.map(InboxItem.fromMap).toList();
  }

  /// 引用附件清单（content-pipeline §7 迁移页）：所有 attach_state=ref 的未删条目
  /// （含 Vault——迁移是持有态修复，与隐私可见性无关，列表页由调用方再过滤）。
  /// 只读查询，不入写锁。
  Future<List<InboxItem>> listRefs({int limit = 500}) async {
    final db = await _database();
    final rows = await db.query(
      'inbox_items',
      where: 'attach_state = ? AND is_deleted = 0',
      whereArgs: [InboxItem.attachRef],
      orderBy: 'created_at DESC',
      limit: limit,
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
  // ───────── 工作区（2026-09-30：条目集合容器，多对多） ─────────
  //
  // 与「AI 分类标签（facets）」的区别：标签是 AI 产出的属性（扁平、只可筛选），
  // 工作区是容器（用户可创建 / 命名 / 增删条目）。见 ui-spec §4.11。

  Future<Workspace> createWorkspace(String name) async {
    final db = await _database();
    final ws = Workspace(
      id: InboxItem.newId(),
      name: name.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insert('workspaces', ws.toMap());
    notifyListeners();
    return ws;
  }

  Future<void> renameWorkspace(String id, String name) async {
    final db = await _database();
    await db.update(
      'workspaces',
      {'name': name.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  /// 删除工作区；关系行由外键级联清理（`PRAGMA foreign_keys = ON` 已开）。
  Future<void> deleteWorkspace(String id) async {
    final db = await _database();
    await db.delete('workspaces', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<List<Workspace>> listWorkspaces() async {
    final db = await _database();
    final rows = await db.query('workspaces', orderBy: 'created_at DESC');
    return rows.map(Workspace.fromMap).toList();
  }

  /// 单个工作区（不存在返回 null）。
  Future<Workspace?> byIdWorkspace(String id, {Transaction? txn}) async {
    final db = txn ?? await _database();
    final rows = await db.query(
      'workspaces',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Workspace.fromMap(rows.first);
  }

  /// 加入工作区；重复加入**幂等**（主键冲突忽略，不报错）。
  Future<void> addToWorkspace(
    String workspaceId,
    String itemId, {
    Transaction? txn,
  }) async {
    final db = txn ?? await _database();
    await db.insert(
      'workspace_items',
      {
        'workspace_id': workspaceId,
        'item_id': itemId,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    notifyListeners();
  }

  Future<void> removeFromWorkspace(String workspaceId, String itemId) async {
    final db = await _database();
    await db.delete(
      'workspace_items',
      where: 'workspace_id = ? AND item_id = ?',
      whereArgs: [workspaceId, itemId],
    );
    notifyListeners();
  }

  /// 某工作区内的条目——**与 [list] 同口径**：默认排除 Vault 与已删，
  /// 工作区不得成为隐私隔离的后门。
  Future<List<InboxItem>> listWorkspaceItems(
    String workspaceId, {
    bool vault = false,
  }) async {
    final db = await _database();
    final rows = await db.rawQuery(
      'SELECT i.* FROM inbox_items AS i '
      'JOIN workspace_items AS wi ON wi.item_id = i.id '
      'WHERE wi.workspace_id = ? AND i.is_vault = ? AND i.is_deleted = 0 '
      'ORDER BY i.created_at DESC',
      [workspaceId, vault ? 1 : 0],
    );
    return rows.map(InboxItem.fromMap).toList();
  }

  /// 某条目所属的工作区（详情页展示「在哪些工作区」）。
  Future<List<Workspace>> listItemWorkspaces(String itemId) async {
    final db = await _database();
    final rows = await db.rawQuery(
      'SELECT w.* FROM workspaces AS w '
      'JOIN workspace_items AS wi ON wi.workspace_id = w.id '
      'WHERE wi.item_id = ? ORDER BY w.created_at DESC',
      [itemId],
    );
    return rows.map(Workspace.fromMap).toList();
  }

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
  /// 返回 task_id（= job_id，供 CommandResult 回传、AI 经任务工具查询状态）。
  Future<String> enqueueTask(String itemId, String? taskAction, {Transaction? txn}) async {
    final db = txn ?? await _database();
    final taskId = InboxItem.newId();
    await db.insert('ai_task_queue', {
      'task_id': taskId,
      'item_id': itemId,
      'task_action': taskAction,
      'status': 'pending',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    return taskId;
  }

  /// 待处理任务总数（前台服务通知进度用）。
  Future<int> pendingCount() async {
    final db = await _database();
    final rows = await db.rawQuery(
      "SELECT COUNT(*) c FROM ai_task_queue WHERE status = 'pending'",
    );
    return rows.first['c'] as int? ?? 0;
  }

  /// AI 任务队列快照（含关联条目信息，供任务列表页展示；条目已删也能查到）。
  /// 按 rowid 倒序（最新在前），与消费顺序（正序）相反，便于看最近动态。
  Future<List<Map<String, Object?>>> listTasks({int limit = 50}) async {
    final db = await _database();
    return db.rawQuery(
      '''
      SELECT q.task_id, q.item_id, q.task_action, q.status, q.updated_at, q.last_note,
             i.human_title, i.item_type, i.is_processed
      FROM ai_task_queue AS q
      LEFT JOIN inbox_items AS i ON i.id = q.item_id
      ORDER BY q.rowid DESC
      LIMIT ?
      ''',
      [limit],
    );
  }

  /// 该条目最近一次任务（按 rowid 倒序首条），供任务队列原因展示与 MCP `get_item`
  /// 回传——**同一份失败原因既给人看也给 AI 读**（2026-09-28 决策）。
  Future<Map<String, Object?>?> lastTaskOf(String itemId) async {
    final db = await _database();
    final rows = await db.rawQuery(
      'SELECT task_id, item_id, task_action, status, updated_at, last_note '
      'FROM ai_task_queue WHERE item_id = ? ORDER BY rowid DESC LIMIT 1',
      [itemId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 按 task_id 查单个任务（MCP `get_job_status` 用；条目已删也能查到）。
  Future<Map<String, Object?>?> taskById(String taskId) async {
    final db = await _database();
    final rows = await db.query(
      'ai_task_queue',
      where: 'task_id = ?',
      whereArgs: [taskId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 暂停任务：pending → paused（**不被消费者认领**，但保留在队列中可手动恢复）。
  /// 只暂停尚未开始的任务；已在 processing 的不打断（打断需消费者侧配合）。
  Future<bool> pauseTask(String taskId) async {
    final db = await _database();
    final n = await db.update(
      'ai_task_queue',
      {'status': 'paused', 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'task_id = ? AND status = ?',
      whereArgs: [taskId, 'pending'],
    );
    return n > 0;
  }

  /// 启动（恢复）任务：paused / failed / cancelled → pending，重新进入消费队列。
  Future<bool> resumeTask(String taskId) async {
    final db = await _database();
    final n = await db.update(
      'ai_task_queue',
      {'status': 'pending', 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: "task_id = ? AND status IN ('paused', 'failed', 'cancelled')",
      whereArgs: [taskId],
    );
    return n > 0;
  }

  /// 删除任务（仅从队列移除，不删除条目本身）。
  Future<bool> deleteTask(String taskId) async {
    final db = await _database();
    final n = await db.delete('ai_task_queue', where: 'task_id = ?', whereArgs: [taskId]);
    return n > 0;
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
  ///
  /// [note] 为**原因说明**（失败时写错误原因，「完成但无产出」时写提示）——
  /// 错误必须被用户感知（2026-09-28 决策），且这份信息对 AI 同样可读：
  /// 队列任务本身不进 MCP 返回体，但任务队列页与详情页状态条共用同一份文本，
  /// 避免"人看到一句、AI 猜另一句"。
  Future<void> finishTask(String taskId, String status, {String? note}) async {
    final db = await _database();
    await db.update(
      'ai_task_queue',
      {
        'status': status,
        'last_note': ?note,
      },
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
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

  // ---- S3 备份快照与恢复（2026-09-29，设计 docs/design/s3-backup.md §4/§5）----

  /// 整库快照到 [dest]（`VACUUM INTO`，原子一致）。
  ///
  /// 安全边界：DB 快照含**未加密正文**，而备份目的地（未加密远端）不可信，
  /// 故快照副本上先物理删除 Vault 条目（含关联队列/草稿行）再 `VACUUM` 回收页——
  /// 不 VACUUM 则已删内容仍留在文件页里。Vault 只排除计数，不进快照。
  ///
  /// 版本约束：`VACUUM INTO` 需 SQLite 3.22+（Android 10+ 系统库；minSdk 24 的
  /// 老设备会失败）——运行时探测，不满足时抛带设备级说明的异常（错误可感知，不静默降级）。
  /// 过程文件走 `dest.snap.part`，成功后 rename 到 [dest]，中断不留半截快照。
  Future<SnapshotResult> snapshotTo(File dest) async {
    final db = await _database();
    // SQLite 版本探测走标准函数 sqlite_version()：sqflite ffi 下 `PRAGMA sqlite_version`
    // 返回空结果集（实测），标准 SELECT 两种实现都稳定
    final verRow = await db.rawQuery('SELECT sqlite_version() AS v');
    final ver = '${verRow.first['v']}';
    if (!_sqliteVersionAtLeast(ver, 3, 22)) {
      throw Exception('备份不可用：本机 SQLite $ver 过旧（备份需 3.22+，即 Android 10+ 系统库）');
    }
    final temp = File('${dest.path}.snap.part');
    if (await temp.exists()) await temp.delete();
    await db.execute('VACUUM INTO ?', [temp.path]);
    // 打开快照（独立连接，不动主库），删 Vault 行后 VACUUM 压实
    final snap = await openDatabase(temp.path);
    late final SnapshotResult result;
    try {
      final count = (await snap.rawQuery('SELECT COUNT(*) c FROM inbox_items WHERE is_vault = 1'))
          .first['c'] as int? ?? 0;
      final embCount =
          (await snap.rawQuery('SELECT COUNT(*) c FROM item_embeddings')).first['c'] as int? ?? 0;
      if (count > 0 || embCount > 0) {
        await snap.transaction((txn) async {
          // 先删依赖方（队列按 item_id 级联/草稿按 target_id 前缀 'edit:<itemId>:<field>'），再删本体
          await txn.rawQuery(
            'DELETE FROM ai_task_queue WHERE item_id IN (SELECT id FROM inbox_items WHERE is_vault = 1)',
          );
          await txn.rawQuery(
            "DELETE FROM drafts WHERE EXISTS (SELECT 1 FROM inbox_items v "
            "WHERE v.is_vault = 1 AND drafts.target_id LIKE 'edit:' || v.id || ':%')",
          );
          await txn.rawQuery('DELETE FROM inbox_items WHERE is_vault = 1');
          // 向量等派生数据整表不进备份（可全量重算，备份只保护事实源）
          await txn.execute('DELETE FROM item_embeddings');
        });
        await snap.execute('VACUUM'); // 物理回收页：已删正文不得留在文件里
      }
      final kept = (await snap.rawQuery('SELECT COUNT(*) c FROM inbox_items')).first['c'] as int? ?? 0;
      result = SnapshotResult(itemCount: kept, vaultExcluded: count);
    } finally {
      await snap.close();
    }
    await temp.rename(dest.path); // 成功后才转正：调用方拿到 dest 即完整快照
    return result;
  }

  /// 版本比较：`PRAGMA sqlite_version` 返回如 '3.40.1'；按数字段比较，避免字符串序误判。
  static bool _sqliteVersionAtLeast(String ver, int major, int minor) {
    final parts = ver.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final maj = parts.isNotEmpty ? parts[0] : 0;
    final min = parts.length > 1 ? parts[1] : 0;
    return maj > major || (maj == major && min >= minor);
  }

  /// 从快照文件 [src] 全量恢复（设计 §5：云端为源，本地被整体替换）。
  ///
  /// 走 ATTACH + 事务：单事务内 DELETE 本地各表 + INSERT FROM 快照，中途失败整体回滚，
  /// 本地数据不会被恢复动作破坏一半。rowid 一并保留（FTS5 外容表映射依赖 rowid 稳定）。
  ///
  /// 恢复表 = 条目域四表 + **工作区两表**（workspaces / workspace_items，schema v14，
  /// 属用户事实数据非派生，须随备份带入；漏恢复会导致「备份里有、恢复后丢」的不一致）。
  Future<RestoreResult> restoreFrom(File src) async {
    final db = await _database();
    await db.execute("ATTACH DATABASE ? AS gs_backup", [src.path]);
    try {
      await db.transaction((txn) async {
        for (final t in const [
          'inbox_items',
          'ai_task_queue',
          'daily_metrics',
          'drafts',
          'workspaces',
          'workspace_items',
        ]) {
          await txn.execute('DELETE FROM $t');
          await txn.execute('INSERT INTO $t SELECT * FROM gs_backup.$t');
        }
        // 派生向量随本地事实源一起失效（快照里本就没有；旧向量指向恢复前条目），
        // 清空待重算，恢复语义恒为「事实源全量替换 + 缓存归零」
        await txn.execute('DELETE FROM item_embeddings');
      });
    } finally {
      await db.execute('DETACH DATABASE gs_backup');
    }
    final kept = (await db.rawQuery('SELECT COUNT(*) c FROM inbox_items')).first['c'] as int? ?? 0;
    notifyListeners(); // 恢复后 UI 整体刷新（与 [transaction] 同口径：导入完成统一广播一次）
    return RestoreResult(itemCount: kept);
  }

  /// 当前 DB schema 版本（备份 manifest 记录用，恢复端可据此提示跨大版本风险）。
  ///
  /// 读 `PRAGMA user_version`——openDatabase(version: 9) 由 sqflite 维护的应用级版本；
  /// `PRAGMA schema_version` 是 SQLite 内部 schema cookie（DDL 即变），不是项目语义。
  Future<int> schemaVersion() async {
    final db = await _database();
    final v = await db.rawQuery('PRAGMA user_version');
    return v.first.values.first is int ? v.first.values.first as int : 0;
  }

  // ---- 向量派生数据（schema v9，设计 docs/design/vector-embeddings.md）----

  /// 整体替换某条目在某模型下的全部向量（分块嵌入：长文本多 chunk，短条目恒单 chunk）。
  ///
  /// 派生缓存治理，非条目域写：不 bump 乐观锁 version、不 notifyListeners（不进任何
  /// UI 读路径，消费方是未来的向量检索引擎）；写入方（嵌入管线）接入时无需经
  /// ItemActionHandler——与 snapshotTo/restoreFrom 同属「数据层维护原语」。
  Future<void> replaceItemEmbeddings({
    required String itemId,
    required String model,
    required List<ItemEmbedding> vectors,
  }) async {
    final db = await _database();
    await db.transaction((txn) async {
      await txn.delete(
        'item_embeddings',
        where: 'item_id = ? AND model = ?',
        whereArgs: [itemId, model],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final v in vectors) {
        await txn.insert('item_embeddings', {
          'item_id': itemId,
          'model': model,
          'chunk_index': v.chunkIndex,
          'dim': v.dim,
          'dtype': v.dtype,
          'vec': v.vec,
          'created_at': now,
        });
      }
    });
  }

  /// 删除某条目的向量（缺省全模型；换模型重算前清旧档用）。
  Future<void> deleteItemEmbeddings(String itemId, {String? model}) async {
    final db = await _database();
    await db.delete(
      'item_embeddings',
      where: model == null ? 'item_id = ?' : 'item_id = ? AND model = ?',
      whereArgs: model == null ? [itemId] : [itemId, model],
    );
  }

  /// 当前库内向量总行数（体积观测与测试用）。
  Future<int> embeddingsCount() async {
    final db = await _database();
    final rows = await db.rawQuery('SELECT COUNT(*) c FROM item_embeddings');
    return rows.first['c'] as int? ?? 0;
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

/// 快照导出结果（[Repository.snapshotTo]）：快照内条目数（不含 Vault）与被排除的 Vault 计数。
class SnapshotResult {
  const SnapshotResult({required this.itemCount, required this.vaultExcluded});

  final int itemCount;
  final int vaultExcluded;
}

/// 恢复导入结果（[Repository.restoreFrom]）：导入后本地条目数（含软删，全量替换语义）。
class RestoreResult {
  const RestoreResult({required this.itemCount});

  final int itemCount;
}

/// 单条向量（[Repository.replaceItemEmbeddings] 载荷）。
///
/// [vec] 为原始字节，按 [dtype] 解释：`f32` = 小端 float32（每维 4 字节）、
/// `int8` = 量化字节（每维 1 字节，量化约定见 docs/design/vector-embeddings.md §2）。
class ItemEmbedding {
  const ItemEmbedding({
    required this.chunkIndex,
    required this.dim,
    required this.dtype,
    required this.vec,
  });

  final int chunkIndex;
  final int dim;
  final String dtype;
  final Uint8List vec;
}
