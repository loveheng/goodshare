import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/share/share_intake.dart';
import 'package:goodshare/share/text_collector.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// ShareIntake PDF 恒持有分档（2026-10-02 拍板，content-pipeline §6）：
/// mimeType / 扩展名双判定 + owned 落盘断言；非 PDF 附件仍走引用模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  late Directory docs;
  late Repository repo;
  late ShareIntake intake;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('goodshare_docs_test');
    // path_provider → 系统临时目录（copyToAppDir 落盘目标的测试替身）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => docs.path,
    );
    repo = Repository();
    final handler = ItemActionHandler(repo);
    intake = ShareIntake(handler, TextCollector(handler));
    // 清空上例残留（内存库按测试文件共享）
    for (final it in await repo.list(vault: true, includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    for (final it in await repo.list(includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    await repo.purgeDeleted(retention: Duration.zero);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  File makeSourcePdf(String name) {
    final f = File('${Directory.systemTemp.path}/$name');
    f.writeAsBytesSync([0x25, 0x50, 0x44, 0x46]); // %PDF 头
    return f;
  }

  test('PDF 恒持有（mime 判定）：引用模式下仍复制 → owned 且副本在 shares/', () async {
    final src = makeSourcePdf('share_mime_${DateTime.now().millisecondsSinceEpoch}.pdf');
    addTearDown(() => src.deleteSync());
    await intake.handleForTest([
      SharedMediaFile(path: src.path, type: SharedMediaType.file, mimeType: 'application/pdf'),
    ]);
    final items = await repo.list();
    expect(items, hasLength(1));
    expect(items.single.itemType, InboxItem.typeDocument);
    expect(items.single.attachState, InboxItem.attachOwned, reason: 'PDF 是事实来源，恒持有');
    expect(items.single.rawFilePath, startsWith(docs.path));
    expect(File(items.single.rawFilePath!).existsSync(), isTrue);
  });

  test('PDF 扩展名兜底：mimeType 缺失时按 .pdf 后缀判定', () async {
    final src = makeSourcePdf('share_ext_${DateTime.now().millisecondsSinceEpoch}.pdf');
    addTearDown(() => src.deleteSync());
    await intake.handleForTest([
      SharedMediaFile(path: src.path, type: SharedMediaType.file),
    ]);
    final items = await repo.list();
    expect(items, hasLength(1));
    expect(items.single.attachState, InboxItem.attachOwned);
  });

  test('非 PDF 附件不受影响：引用模式照旧 ref + 原路径保留', () async {
    await intake.handleForTest([
      SharedMediaFile(path: '/tmp/not_real.jpg', type: SharedMediaType.image, mimeType: 'image/jpeg'),
    ]);
    final items = await repo.list();
    expect(items, hasLength(1));
    expect(items.single.attachState, InboxItem.attachRef);
    expect(items.single.rawFilePath, '/tmp/not_real.jpg');
  });
}
