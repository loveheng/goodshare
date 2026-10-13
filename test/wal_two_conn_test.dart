// R1 验证：goodshare 主 isolate + binder isolate 对 goodshare.db 是「两条独立连接」，
// 同机 SQLite 并发写会争写锁。本测用低层 sqlite3 开两个独立连接，置于两个 Isolate
// 真正并发写：
//   (a) 默认（无 busy_timeout + 自动提交）→ 触发 SQLITE_BUSY（R1 风险属实）；
//   (b) busy_timeout=5000 + 每连接单事务批量写（文档推荐缓解）→ 无 BUSY、全部落库。
//
// 注：曾用 sqflite openDatabase(singleInstance:false) 在 ffi 宿主端被按路径去重成同一连接，
// 无法复现争锁；故直接用 sqlite3 原生连接 + Isolate 并发。
//
// 运行：cd goodshare && flutter test test/wal_two_conn_test.dart
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

(bool, int) _writer(
  String path,
  int start,
  int count,
  int busyTimeout,
  bool batch,
) {
  final db = sqlite3.open(path);
  if (busyTimeout > 0) db.execute('PRAGMA busy_timeout=$busyTimeout');
  var busy = false;
  void insertOne(int i) {
    try {
      db.execute("INSERT INTO t(id,v) VALUES ($i,'x$i')");
    } on SqliteException catch (e) {
      final s = e.message.toLowerCase();
      if (s.contains('busy') || s.contains('locked')) {
        busy = true;
      } else {
        rethrow;
      }
    }
  }

  if (batch) {
    db.execute('BEGIN');
    for (var i = start; i < start + count; i++) {
      insertOne(i);
    }
    db.execute('COMMIT');
  } else {
    for (var i = start; i < start + count; i++) {
      insertOne(i);
    }
  }
  int n = 0;
  try {
    n = (db.select('SELECT COUNT(*) c FROM t').first['c'] as int?) ?? 0;
  } on SqliteException catch (e) {
    if (e.message.toLowerCase().contains('busy') ||
        e.message.toLowerCase().contains('locked')) {
      busy = true;
    } else {
      rethrow;
    }
  }
  db.close();
  return (busy, n);
}

Future<(bool busy, int committed)> _run({
  required int busyTimeout,
  required bool batch,
}) async {
  final dir = Directory.systemTemp.createTempSync('gswal');
  final path = '${dir.path}/goodshare.db';
  // 先建表（避免两 isolate 并发建表互相干扰）
  final setup = sqlite3.open(path);
  setup.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
  setup.close();

  final fa = Isolate.run(() => _writer(path, 0, 300, busyTimeout, batch));
  final fb = Isolate.run(() => _writer(path, 100000, 300, busyTimeout, batch));
  final ra = await fa;
  final rb = await fb;
  final busy = ra.$1 || rb.$1;

  final db = sqlite3.open(path);
  final committed = (db.select('SELECT COUNT(*) c FROM t').first['c'] as int?) ?? 0;
  db.close();
  dir.deleteSync(recursive: true);
  return (busy, committed);
}

void main() {
  test('R1 风险: 默认（无 busy_timeout + 自动提交）两独立连接并发写 → SQLITE_BUSY',
      () async {
    final r = await _run(busyTimeout: 0, batch: false);
    print('[R1-default] busy=${r.$1} committed=${r.$2}');
    expect(r.$1, isTrue,
        reason: 'goodshare 未设 busy_timeout：主+binder 双连接并发写触发 SQLITE_BUSY（R1 风险属实）');
  });

  test('R1 缓解: busy_timeout=5000 + 单事务批量写 → 无 BUSY 且全提交',
      () async {
    final r = await _run(busyTimeout: 5000, batch: true);
    print('[R1-mitigated] busy=${r.$1} committed=${r.$2}');
    expect(r.$1, isFalse,
        reason: 'busy_timeout + 事务批量写后双连接并发写应全部成功（缓解有效）');
    expect(r.$2, 600, reason: '两个 writer 各 300 行应全部落库');
  });
}
