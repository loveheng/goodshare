import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/item.dart';
import 'db.dart';

/// 收集数据仓库：UI 与 MCP 工具共用的唯一入口。
class Repository extends ChangeNotifier {
  Database? _db;

  Future<Database> _database() async => _db ??= await Db.instance();

  Future<int> add(CollectItem item) async {
    final db = await _database();
    final id = await db.insert('items', item.toMap());
    notifyListeners();
    return id;
  }

  /// 关键词命中标题 / 正文 / 标签；type 为空则不过滤。
  Future<List<CollectItem>> list({
    String? query,
    String? type,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await _database();
    final where = <String>[];
    final args = <Object?>[];
    if (query != null && query.trim().isNotEmpty) {
      final like = '%${query.trim()}%';
      where.add('(title LIKE ? OR text LIKE ? OR tags LIKE ?)');
      args.addAll([like, like, like]);
    }
    if (type != null && type.isNotEmpty) {
      where.add('type = ?');
      args.add(type);
    }
    final rows = await db.query(
      'items',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(CollectItem.fromMap).toList();
  }

  Future<int> count({String? query, String? type}) async {
    final db = await _database();
    final where = <String>[];
    final args = <Object?>[];
    if (query != null && query.trim().isNotEmpty) {
      final like = '%${query.trim()}%';
      where.add('(title LIKE ? OR text LIKE ? OR tags LIKE ?)');
      args.addAll([like, like, like]);
    }
    if (type != null && type.isNotEmpty) {
      where.add('type = ?');
      args.add(type);
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) c FROM items${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      where.isEmpty ? null : args,
    );
    return rows.first['c'] as int? ?? 0;
  }

  Future<CollectItem?> byId(int id) async {
    final db = await _database();
    final rows = await db.query('items', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return CollectItem.fromMap(rows.first);
  }

  Future<void> delete(int id) async {
    final item = await byId(id);
    final db = await _database();
    await db.delete('items', where: 'id = ?', whereArgs: [id]);
    // 删除本 app 复制落盘的附件；不触碰源 app 的内容。
    for (final f in item?.files ?? const <String>[]) {
      try {
        final file = File(f);
        if (await file.exists()) await file.delete();
      } catch (_) {/* 文件可能已不存在，忽略 */}
    }
    notifyListeners();
  }
}
