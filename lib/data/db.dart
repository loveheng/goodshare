import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 单表存储：items。标签/文件列表用逗号、换行拼接（个人规模数据，避免过度设计）。
class Db {
  static Database? _db;

  static Future<Database> instance() async {
    final cached = _db;
    if (cached != null) return cached;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'goodshare.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            title TEXT,
            text TEXT,
            mime TEXT,
            source_package TEXT,
            source_app TEXT,
            tags TEXT,
            files TEXT,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_items_created ON items(created_at DESC)');
      },
    );
    _db = db;
    return db;
  }
}
