// goodshare WAL 写路径并发压测（2026-11-09 自 goodhub 仓 integration_test 迁入，
// 归属裁决：断言主体是 goodshare 自身 DB 写路径 → 本仓；binder 传输层并发
// 由 goodhub 侧 goodshare_binder_e2e 继续覆盖）。
//
// 说明：进程内直调 callTool('add_item')，并发落库验证「写路径在并发下
// 无死锁/无库内 locked、全部提交成功」。隔离：独立测试库，不污染真机库。
//
// 运行（真机）：
//   flutter test integration_test/goodshare_wal_e2e_test.dart -d <device>

library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/tools.dart';

Future<T> _withTimeout<T>(Future<T> f, String label) => f.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw TimeoutException('超时: $label', const Duration(seconds: 30)),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WAL: concurrent add_item (write path)', (tester) async {
    // 隔离真实库：指向独立测试库，跑前清残留。
    final testPath = p.join(await getDatabasesPath(), 'goodshare_itest.db');
    Db.overridePath(testPath);
    try {
      await deleteDatabase(testPath);
    } catch (_) {}

    final repo = Repository();
    await Db.instance(); // 首次打开即建表

    const n = 12;
    debugPrint('[gs-wal] firing $n concurrent add_item in-process...');
    final futures = <Future<Object?>>[];
    for (var i = 0; i < n; i++) {
      futures.add(_withTimeout(
        callTool('add_item', <String, Object?>{
          'content': 'WAL 压测 #$i ${DateTime.now().microsecondsSinceEpoch}',
        }, repo),
        'add_item#$i',
      ));
    }
    final results = await Future.wait(futures);
    var ok = 0;
    for (final r in results) {
      final blocks = r is List ? r : const [];
      if (blocks.isNotEmpty &&
          jsonEncode(blocks).contains('"id"')) {
        ok++;
      }
    }
    debugPrint('[gs-wal] add_item 成功 $ok/$n');
    expect(ok, n, reason: '并发 add_item 应全部成功（无库内 locked/死锁）');
    debugPrint('[gs-wal] PASS: 写路径并发安全');
  });
}
