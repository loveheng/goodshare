import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 存储层：inbox_items（三层集散表）+ daily_metrics（时光机上下文）+ ai_task_queue（后台队列）。
/// Schema 唯一出处为 PRD §5.3；v1 单表 items 未经设计，升级时弃旧数据整体重建（不迁移）。
class Db {
  static Database? _db;

  /// 库路径覆盖口：单测用内存库（inMemoryDatabasePath）做 isolate 级隔离，运行时不设置。
  static String? _pathOverride;
  static void overridePath(String path) => _pathOverride = path;

  static Future<Database> instance() async {
    final cached = _db;
    if (cached != null) return cached;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      _pathOverride ?? p.join(dir, 'goodshare.db'),
      version: 15,
      onCreate: (db, version) => _createAll(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v1 单表 items 升级：弃旧数据整体重建（不迁移），PRD §5.3 决策
          await db.execute('DROP TABLE IF EXISTS items');
          await _createAll(db);
        }
        if (oldVersion < 4) {
          // v2/v3 升级：补齐 drafts 表（_createAll 内 IF NOT EXISTS，已含则跳过）
          await _createAll(db);
        }
        // 幂等补齐 ai_task_queue.updated_at（v2→v3 迁移；v1 经 _createAll 已含则跳过）
        await _ensureQueueUpdatedAt(db);
        // 幂等补齐 inbox_items.version（v4→v5 乐观锁；v1 经 _createAll 已含则跳过）
        await _ensureItemVersion(db);
        // 幂等补齐译文两列（v5→v6 翻译层；v1 经 _createAll 已含则跳过）
        await _ensureTranslationColumns(db);
        // 幂等补齐 ai_task_queue.last_note（v6→v7 失败原因可感知）
        await _ensureTaskNoteColumn(db);
        // 幂等补齐 inbox_items.summary_md（v7→v8 端侧 LLM 摘要）
        await _ensureSummaryColumn(db);
        // 幂等补齐 item_embeddings 派生表（v8→v9 向量派生数据分表）
        await _ensureEmbeddingsTable(db);
        // 幂等补齐 inbox_items.clips_json（v9→v10 视频切片附属记录）
        await _ensureClipsColumn(db);
        // 幂等补齐 inbox_items.video_whole_marked（v10→v11 整片标记=备份 opt-in）
        await _ensureWholeMarkedColumn(db);
        // 幂等补齐 inbox_items.doc_meta_json（v11→v12 归一化覆盖率与确认状态）
        await _ensureDocMetaColumn(db);
        // 幂等补齐 inbox_items.attach_state（v12→v13 文件引用状态机）
        await _ensureAttachStateColumn(db);
        // 幂等补齐工作区两表（v13→v14 条目集合容器，多对多）
        await _ensureWorkspaceTables(db);
        // 幂等补齐 inbox_items.aspect_ratio（v14→v15 图片尺寸前置，渲染免抖动）
        await _ensureAspectRatioColumn(db);
      },
      onOpen: (db) async {
        // ai_task_queue 的外键级联依赖此开关，sqflite 默认关闭
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    _db = db;
    return db;
  }

  static Future<void> _createAll(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inbox_items (
        rowid INTEGER PRIMARY KEY AUTOINCREMENT,   -- FTS5 外容表映射用（V2 启用）
        id TEXT NOT NULL UNIQUE,                    -- uuid，对外稳定标识
        item_type TEXT NOT NULL,                    -- 'note','url','image','video','audio','chatlog','document'（AI 可重分类）
        source_type TEXT,                           -- 入库原始类型（如截图），入库后不变
        source_app TEXT,                            -- 来源 e.g. 'wechat','clipboard'
        raw_content TEXT,                           -- 原始脏数据层
        raw_file_path TEXT,                         -- 原始图片/文件本地路径（单文件）
        human_title TEXT,                           -- AI 重构标题
        human_tldr TEXT,                            -- AI 3 句摘要
        human_md TEXT,                              -- AI 重构 Markdown（含 [ ] 待办）
        machine_json TEXT,                          -- 强类型结构化数据
        translated_md TEXT,                         -- 译文（翻译层产出，与 human_md 并列不覆盖）
        translate_lang TEXT,                        -- 译文语言码（BCP-47），与 translated_md 成对
        summary_md TEXT,                            -- 端侧 LLM 摘要（与 human_md 并列不覆盖，2026-09-28 v8）
        clips_json TEXT,                            -- 视频切片（关键区间）附属记录（2026-09-29 v10，lib/ai/video_clips.dart）
        video_whole_marked INTEGER NOT NULL DEFAULT 0, -- 整片标记：1=用户认为整个视频重要，备份时携带源文件（2026-09-29 v11）
        doc_meta_json TEXT,                         -- 归一化覆盖率与确认状态（2026-09-30 v12，content-pipeline §7）
        attach_state TEXT NOT NULL DEFAULT 'owned', -- 文件引用状态 ref/owned/lost（2026-09-30 v13）
        aspect_ratio REAL,                          -- 图片宽高比（宽/高，摄入时解码图片头探测；null=未探测）（2026-09-30 v15）
        tags TEXT,                                  -- JSON Array: ["前端","团建"]
        facets_json TEXT,                           -- JSON: 视角→标签数组，AI 分类页消费（V2）
        is_vault INTEGER NOT NULL DEFAULT 0,        -- 0 公开 / 1 私密保险箱
        is_processed INTEGER NOT NULL DEFAULT 0,    -- 0 待处理 / 1 完成 / -1 失败
        collect_mode TEXT NOT NULL DEFAULT 'scatter', -- 'scatter' 分散 / 'merge' 合并
        appendix_json TEXT,                         -- 合并模式各段附加记录 [{ts,text,source}]
        edit_locked INTEGER NOT NULL DEFAULT 0,     -- 合并模式默认 1（锁定不可编辑）
        is_deleted INTEGER NOT NULL DEFAULT 0,      -- 0 正常 / 1 已删（软删除）
        deleted_at INTEGER,                         -- 软删除时间戳（毫秒），30 天保留期以此计算
        todo_state_json TEXT,                       -- 待办勾选状态 [{hash,done,ts}]（V2）
        created_at INTEGER NOT NULL,                -- 毫秒时间戳
        version INTEGER NOT NULL DEFAULT 0          -- 乐观锁版本号：任何写 +1，CAS 校验用（2026-09-28 v5）
      )
    ''');
    // 工作区（2026-09-30 v14）：条目集合容器，与条目多对多。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT NOT NULL UNIQUE,          -- uuid
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL       -- 毫秒时间戳
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workspace_items (
        workspace_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (workspace_id, item_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (item_id) REFERENCES inbox_items(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_inbox_created ON inbox_items(created_at DESC)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_inbox_vault ON inbox_items(is_vault)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_metrics (
        date TEXT PRIMARY KEY,                      -- YYYY-MM-DD
        steps INTEGER NOT NULL DEFAULT 0,
        sleep_minutes INTEGER NOT NULL DEFAULT 0,
        calendar_events_json TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_task_queue (
        task_id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
        task_action TEXT,                           -- 'parse_chatlog','ocr_and_extract','summarize_url','transcribe_audio'
        status TEXT NOT NULL DEFAULT 'pending',     -- pending/processing/completed/failed/cancelled
        updated_at INTEGER,                         -- 心跳时间戳（毫秒）；回收僵尸任务用，见 reclaimStaleTasks
        last_note TEXT                              -- 最近一次执行的原因说明：失败时为错误原因，
                                                    -- 「完成但无产出」时为提示（2026-09-28 v7：
                                                    -- 错误必须被用户感知，且同一份信息对 AI 同样可读）
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_queue_status ON ai_task_queue(status)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS drafts (
        id TEXT PRIMARY KEY,                   -- 草稿主键（如 'quick_note' / 'edit:<itemId>:<field>'）
        target_id TEXT,                        -- 关联对象（item id / 'quick_note'）
        content TEXT,                          -- 草稿正文
        updated_at INTEGER NOT NULL            -- 毫秒时间戳
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS item_embeddings (
        item_id TEXT NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
        model TEXT NOT NULL,                   -- 嵌入模型标识（换模型 = 全量重算，旧档先清）
        chunk_index INTEGER NOT NULL,          -- 分块序号 0 起（短条目整条一向量恒 0）
        dim INTEGER NOT NULL,                  -- 向量维度（读取侧校验用）
        dtype TEXT NOT NULL DEFAULT 'f32',     -- 字节编码 f32/int8（int8 量化约定见 docs/design/vector-embeddings.md §2）
        vec BLOB NOT NULL,                     -- 向量字节（f32=小端 float32 / int8=量化字节）
        created_at INTEGER NOT NULL,           -- 毫秒时间戳
        PRIMARY KEY (item_id, model, chunk_index)
      )
    ''');
  }

  /// 幂等补齐 ai_task_queue.updated_at 列（v2→v3 迁移；已存在则跳过，避免 ALTER 报错）。
  static Future<void> _ensureQueueUpdatedAt(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(ai_task_queue)');
    final has = cols.any((c) => (c['name'] as String?) == 'updated_at');
    if (!has) {
      await db.execute('ALTER TABLE ai_task_queue ADD COLUMN updated_at INTEGER');
    }
  }

  /// 幂等补齐 inbox_items.version 列（v4→v5 乐观锁；已存在则跳过，避免 ALTER 报错）。
  /// 存量行取 DEFAULT 0，与「未做并发控制的历史数据」语义一致。
  static Future<void> _ensureItemVersion(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'version');
    if (!has) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN version INTEGER NOT NULL DEFAULT 0');
    }
  }

  /// 幂等补齐 inbox_items 译文两列（v5→v6 翻译层）。
  static Future<void> _ensureTranslationColumns(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final names = {for (final c in cols) (c['name'] as String?)};
    if (!names.contains('translated_md')) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN translated_md TEXT');
    }
    if (!names.contains('translate_lang')) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN translate_lang TEXT');
    }
  }

  /// 幂等补齐 ai_task_queue.last_note（v6→v7）。
  static Future<void> _ensureTaskNoteColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(ai_task_queue)');
    final has = cols.any((c) => (c['name'] as String?) == 'last_note');
    if (!has) {
      await db.execute('ALTER TABLE ai_task_queue ADD COLUMN last_note TEXT');
    }
  }

  /// 幂等补齐 inbox_items.summary_md（v7→v8 端侧 LLM 摘要，与 human_md 并列不覆盖）。
  static Future<void> _ensureSummaryColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'summary_md');
    if (!has) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN summary_md TEXT');
    }
  }

  /// 幂等建 item_embeddings 派生表（v8→v9，2026-09-29）。
  ///
  /// 派生数据分表决策：向量是源文本的可再生衍生物，独立成表保证
  /// ①事实源（四表）体积不随向量增长 ②换嵌入模型可整表重算
  /// ③备份/恢复把整表当缓存对待（快照清空、恢复即清），见 docs/design/vector-embeddings.md。
  static Future<void> _ensureEmbeddingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS item_embeddings (
        item_id TEXT NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
        model TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        dim INTEGER NOT NULL,
        dtype TEXT NOT NULL DEFAULT 'f32',
        vec BLOB NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (item_id, model, chunk_index)
      )
    ''');
  }

  /// 幂等补齐 inbox_items.video_whole_marked（v10→v11 整片标记，2026-09-29）。
  ///
  /// 两极标记的「整片」极：用户认为整个视频重要 → 备份时携带源文件（D3 默认排除的
  /// 逐条目 opt-in）。标记本身不触发上传，上传仍由手动备份触发。
  static Future<void> _ensureWholeMarkedColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'video_whole_marked');
    if (!has) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN video_whole_marked INTEGER NOT NULL DEFAULT 0');
    }
  }

  /// 幂等补齐 inbox_items.doc_meta_json（v11→v12，2026-09-30）。
  ///
  /// 文档归一化**是有损的**（PDF 结构靠启发式、表格降级），故每次转换都记录
  /// 覆盖率指标（字数 / 降级块数 / 是否截断）与用户确认状态，供 UI 明示
  /// （content-pipeline.md §7：降级必须被感知，不允许静默成功）。
  static Future<void> _ensureDocMetaColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'doc_meta_json');
    if (!has) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN doc_meta_json TEXT');
    }
  }

  /// 幂等补齐 inbox_items.attach_state（v12→v13，2026-09-30）。
  ///
  /// 引用模式：`ref`=引用原件未复制（app 不持有，不给用户存储添麻烦）、
  /// `owned`=已持有副本、`lost`=原件不可访问。
  /// **存量默认 owned**——它们确实是复制进私有目录的，语义不能倒填。
  static Future<void> _ensureAttachStateColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'attach_state');
    if (!has) {
      await db.execute(
        "ALTER TABLE inbox_items ADD COLUMN attach_state TEXT NOT NULL DEFAULT 'owned'",
      );
    }
  }

  /// 幂等补齐 inbox_items.aspect_ratio（v14→v15，2026-09-30）。
  ///
  /// 图片尺寸前置（rich-text-component.md §6.1 V1）：摄入时解码图片头取宽高比，
  /// 渲染处 AspectRatio + 占位底色包图，消灭列表/详情加载抖动。专用列而非
  /// machine_json/facets_json——AI 回写对两者整替，摄入元数据会被冲掉。
  static Future<void> _ensureAspectRatioColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'aspect_ratio');
    if (!has) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN aspect_ratio REAL');
    }
  }

  /// 幂等补齐工作区两表（v13→v14，2026-09-30）。
  ///
  /// 条目集合容器，与条目多对多；关系行外键级联清理
  /// （`PRAGMA foreign_keys = ON` 在 onOpen 打开，升级路径同样生效）。
  static Future<void> _ensureWorkspaceTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT NOT NULL UNIQUE,          -- uuid
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL       -- 毫秒时间戳
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workspace_items (
        workspace_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (workspace_id, item_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (item_id) REFERENCES inbox_items(id) ON DELETE CASCADE
      )
    ''');
  }

  /// 幂等补齐 inbox_items.clips_json（v9→v10 视频切片，2026-09-29）。
  ///
  /// 切片结果为原条目附属记录（JSON 列，与 appendix/facets 同风格）：
  /// 每段 {start_ms, end_ms, text, summary, note, created_at}，见 lib/ai/video_clips.dart。
  static Future<void> _ensureClipsColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(inbox_items)');
    final has = cols.any((c) => (c['name'] as String?) == 'clips_json');
    if (!has) {
      await db.execute('ALTER TABLE inbox_items ADD COLUMN clips_json TEXT');
    }
  }
}
