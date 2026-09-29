import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/sync/backup_manifest.dart';
import 'package:goodshare/sync/s3_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// S3 备份引擎单测（2026-09-29，设计 docs/design/s3-backup.md §4/§5）：
/// SigV4 签名向量校验、path-style URL/key 构造、快照导出（Vault 物理排除 + 计数）、
/// 快照→恢复全量替换、manifest 编解码与路径消毒。
/// 纯引擎路径，不触碰网络（S3Client 的 HTTP 行为需真机/集成环境）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  Directory? tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('s3_backup_test');
    // 清空上例残留
    final repo = Repository();
    for (final it in await repo.list(vault: true, includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    for (final it in await repo.list(includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    await repo.purgeAllDeleted();
  });

  tearDown(() async {
    if (tmp != null && await tmp!.exists()) await tmp!.delete(recursive: true);
  });

  test('manifest 编解码往返一致，字段缺失时报错不静默', () {
    final m = BackupManifest(
      ts: 1761750000000,
      schemaVersion: 2,
      itemCount: 10,
      vaultExcluded: 2,
      dbSize: 4096,
      attachments: const [BackupAttachment(rel: 'shares/a.txt', size: 100, itemId: 'x1')],
    );
    final back = BackupManifest.decode(m.encode());
    expect(back.ts, m.ts);
    expect(back.schemaVersion, 2);
    expect(back.itemCount, 10);
    expect(back.vaultExcluded, 2);
    expect(back.dbSize, 4096);
    expect(back.attachments.single.rel, 'shares/a.txt');

    // 缺字段 → 抛异常（坏清单不可信，拒绝恢复），不默认 0 蒙混
    expect(() => BackupManifest.decode('{"ts":1,"schema_version":1,"item_count":1}'),
        throwsA(isA<Exception>()));
  });

  test('路径白名单：../ 逃逸、绝对路径、空 rel 一律拒绝', () {
    expect(isSafeBackupRel('shares/a/b.txt'), isTrue);
    expect(isSafeBackupRel('annotations/x.png'), isTrue);
    expect(isSafeBackupRel('../escape.txt'), isFalse);
    expect(isSafeBackupRel('a/../../b.txt'), isFalse);
    expect(isSafeBackupRel('/abs.txt'), isFalse);
    expect(isSafeBackupRel(''), isFalse);
    expect(isSafeBackupRel('a/b\x00.txt'), isFalse);
  });

  test('SigV4 签名：固定时间向量对拍（测试侧独立派生签名链）', () {
    final client = S3Client(
      endpoint: 'https://s3.example.com:9000',
      bucket: 'mybucket',
      region: 'cn-north-1',
      accessKey: 'AKIDEXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    );
    final at = DateTime.utc(2026, 9, 29, 8, 15, 30);
    final headers = client.signForTest('PUT', 'goodshare/manifest.json', utcAt: at);

    // 结构断言：日期格式、scope、SignedHeaders 列表
    final auth = headers['Authorization']!;
    expect(auth, startsWith('AWS4-HMAC-SHA256 '));
    expect(auth, contains('Credential=AKIDEXAMPLE/20260929/cn-north-1/s3/aws4_request'));
    expect(auth, contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date'));
    expect(headers['x-amz-date'], '20260929T081530Z');
    expect(headers['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD');

    // 值断言：测试侧按 SigV4 规范独立重算签名串与派生链，比对最终 Signature
    final amzDate = '20260929T081530Z';
    final scope = '20260929/cn-north-1/s3/aws4_request';
    // canonical request（与客户端实现同一请求形态：path-style、逐段编码 key）
    final canonical = [
      'PUT',
      '/mybucket/goodshare/manifest.json',
      '',
      'host:s3.example.com:9000\n'
          'x-amz-content-sha256:UNSIGNED-PAYLOAD\n'
          'x-amz-date:$amzDate\n',
      'host;x-amz-content-sha256;x-amz-date',
      'UNSIGNED-PAYLOAD',
    ].join('\n');
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      hex(sha256.convert(utf8.encode(canonical)).bytes),
    ].join('\n');
    List<int> hmac(List<int> k, String m) => Hmac(sha256, k).convert(utf8.encode(m)).bytes;
    var key = hmac(utf8.encode('AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY'), '20260929');
    key = hmac(key, 'cn-north-1');
    key = hmac(key, 's3');
    key = hmac(key, 'aws4_request');
    final expected = hex(hmac(key, stringToSign));
    expect(auth, contains('Signature=$expected'));
  });

  test('ListObjectsV2 XML 解析：Key/Size 提取', () {
    const xml = '''
<ListBucketResult>
<Contents><Key>goodshare/manifest.json</Key><Size>1024</Size></Contents>
<Contents><Key>goodshare/db/goodshare.db</Key><Size>0</Size></Contents>
<Contents><Key>goodshare/attachments/shares/a%20b.txt</Key><Size>7</Size></Contents>
</ListBucketResult>''';
    final objs = S3Client.parseListResponseForTest(xml);
    expect(objs.length, 3);
    expect(objs[0].key, 'goodshare/manifest.json');
    expect(objs[0].size, 1024);
    expect(objs[1].size, 0);
    expect(objs[2].key, 'goodshare/attachments/shares/a b.txt');
  });

  test('computePartSize：默认 16MB，超 10000 片自动放大', () {
    const m16 = 16 * 1024 * 1024;
    final exact10000 = 10000 * m16; // 10000 片恰好不超上限的边界
    expect(S3Client.computePartSize(0), m16);
    expect(S3Client.computePartSize(100 * 1024 * 1024), m16, reason: '100MB → 7 片，用默认 16MB');
    expect(S3Client.computePartSize(exact10000), m16, reason: '恰好 10000 片，不放大');
    // 比边界多 1 字节 → 需 10001 片 → 片大小放大
    final big = S3Client.computePartSize(exact10000 + 1);
    expect(big, greaterThan(m16));
    expect((exact10000 + 1 + big - 1) ~/ big, lessThanOrEqualTo(10000),
        reason: '放大后总片数必须 ≤10000（S3 硬上限）');
  });

  test('completeMultipartBody：XML 组装与 ETag 转义', () {
    final body = S3Client.completeMultipartBody([
      (1, '"abc123"'),
      (2, '"d&amp;e<>"'),
    ]);
    expect(body, startsWith('<CompleteMultipartUpload>'));
    expect(body, contains('<PartNumber>1</PartNumber><ETag>"abc123"</ETag>'));
    expect(body, contains('<ETag>"d&amp;amp;e&lt;&gt;"</ETag>'), reason: 'ETag 内 XML 特殊字符须转义');
    expect(body, endsWith('</CompleteMultipartUpload>'));
  });

  test('快照：Vault 条目物理排除（计数不导出），非 Vault 全量保留', () async {
    final repo = Repository();
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '普通条目一', createdAt: 1));
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '普通条目二', createdAt: 2));
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'vault-secret', isVault: true, createdAt: 3));

    final dest = File('${tmp!.path}/snap.db');
    final r = await repo.snapshotTo(dest);

    expect(r.itemCount, 2, reason: '快照含 2 条非 Vault');
    expect(r.vaultExcluded, 1, reason: '1 条 Vault 被排除并计数');
    expect(await dest.exists(), isTrue);
    expect(dest.lengthSync(), greaterThan(0));

    // 恢复到一个「新库」场景由下例覆盖；这里直接校验快照文件不再含 Vault 正文：
    // 打开快照库验证 vault 计数为 0、正文检索不到 secret
    final snapDb = await databaseFactory.openDatabase(dest.path);
    try {
      final rows = await snapDb.rawQuery("SELECT COUNT(*) c FROM inbox_items WHERE is_vault = 1");
      expect(rows.first['c'] as int, 0, reason: '快照内不得再有 Vault 行');
      final hit = await snapDb.rawQuery(
          "SELECT COUNT(*) c FROM inbox_items WHERE raw_content = 'vault-secret'");
      expect(hit.first['c'] as int, 0, reason: 'VACUUM 压实后 Vault 正文不得残留');
    } finally {
      await snapDb.close();
    }
  });

  test('恢复：快照全量替换本地（含软删行），本地旧数据不残留', () async {
    // 先造「本地 A 状态」
    final repo = Repository();
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'A-state-old', createdAt: 1));
    await repo.softDelete((await repo.list()).first.id!); // 一条软删行（恢复需带回）

    // 快照 A 状态
    final snapA = File('${tmp!.path}/a.db');
    await repo.snapshotTo(snapA);

    // 本地演变到「B 状态」：删 A 全部 + 新加
    for (final it in await repo.list(includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    await repo.purgeAllDeleted();
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'B-state-new', createdAt: 9));

    // 从快照 A 恢复 → 回到 A 状态（含那条软删行），B 的条目被替换掉
    final r = await repo.restoreFrom(snapA);
    expect(r.itemCount, 1);
    // A 状态唯一条目是软删行：默认列表（过滤已删）应为空，软删行在 includeDeleted 里可见
    final live = await repo.list();
    expect(live, isEmpty, reason: 'A 状态唯一条目为软删行，默认列表应为空');
    final withDeleted = await repo.list(includeDeleted: true);
    expect(withDeleted.map((e) => e.rawContent), contains('A-state-old'));
    expect(withDeleted.map((e) => e.rawContent), isNot(contains('B-state-new')));
    expect(withDeleted.length, 1, reason: 'A 状态共 1 条（软删行已恢复）');
    expect(withDeleted.first.isDeleted, true);
  });

  test('向量派生数据（v9）：CRUD 往返、快照整表不携带、恢复即清 stale', () async {
    final repo = Repository();
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '带向量的条目', createdAt: 1));
    final id = (await repo.list()).first.id!;

    Uint8List f32(List<double> xs) {
      final b = ByteData(xs.length * 4);
      for (var i = 0; i < xs.length; i++) {
        b.setFloat32(i * 4, xs[i], Endian.little);
      }
      return b.buffer.asUint8List();
    }
    await repo.replaceItemEmbeddings(itemId: id, model: 'm1', vectors: [
      ItemEmbedding(chunkIndex: 0, dim: 2, dtype: 'f32', vec: f32([1.0, 2.0])),
      ItemEmbedding(chunkIndex: 1, dim: 2, dtype: 'f32', vec: f32([3.0, 4.0])),
    ]);
    await repo.replaceItemEmbeddings(itemId: id, model: 'm2', vectors: [
      ItemEmbedding(chunkIndex: 0, dim: 4, dtype: 'int8', vec: Uint8List.fromList([1, 2, 3, 4])),
    ]);
    expect(await repo.embeddingsCount(), 3);

    // 同模型整体替换（分块重算语义）：m1 的 2 行被替换为 1 行
    await repo.replaceItemEmbeddings(itemId: id, model: 'm1', vectors: [
      ItemEmbedding(chunkIndex: 0, dim: 2, dtype: 'f32', vec: f32([9.0, 8.0])),
    ]);
    expect(await repo.embeddingsCount(), 2);

    // 按模型删 / 全删
    await repo.deleteItemEmbeddings(id, model: 'm2');
    expect(await repo.embeddingsCount(), 1);

    final dest = File('${tmp!.path}/snap-emb.db');
    await repo.snapshotTo(dest);
    final snapDb = await databaseFactory.openDatabase(dest.path);
    try {
      final emb = await snapDb.rawQuery('SELECT COUNT(*) c FROM item_embeddings');
      expect(emb.first['c'] as int, 0, reason: '派生向量整表不进备份（可全量重算）');
    } finally {
      await snapDb.close();
    }

    // 恢复替换事实源后，本地旧向量指向恢复前世界 → 一并清空待重算
    final r = await repo.restoreFrom(dest);
    expect(r.itemCount, 1);
    expect(await repo.embeddingsCount(), 0, reason: '恢复语义 = 事实源全量替换 + 派生缓存归零');

    await repo.deleteItemEmbeddings(id);
    expect(await repo.embeddingsCount(), 0);
  });
}
