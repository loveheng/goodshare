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
      version: 2,
      onCreate: (db, version) => _createAll(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.execute('DROP TABLE IF EXISTS items');
        await _createAll(db);
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
        created_at INTEGER NOT NULL                 -- 毫秒时间戳
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
        status TEXT NOT NULL DEFAULT 'pending'      -- pending/processing/completed/failed/cancelled
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_queue_status ON ai_task_queue(status)');
  }
}
