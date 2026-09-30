import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/share/image_aspect.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// V1 尺寸前置（rich-text-component.md §6.1）：摄入探测图片宽高比入
/// inbox_items.aspect_ratio（v15 专用列），渲染处 AspectRatio 占位消灭加载抖动。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  group('probeImageAspect（图片头探测）', () {
    test('PNG 夹具 2x1 → 宽高比 2.0', () async {
      final ratio = await probeImageAspect('test/fixtures/probe_2x1.png');
      expect(ratio, closeTo(2.0, 0.001));
    });

    test('文件不存在 → null（不抛异常）', () async {
      expect(await probeImageAspect('/nonexistent/none.png'), isNull);
    });

    test('非图片文件 → null（解码器拒绝，不抛异常）', () async {
      final f = File('${Directory.systemTemp.path}/not_image_${DateTime.now().microsecondsSinceEpoch}.txt');
      await f.writeAsString('not an image');
      try {
        expect(await probeImageAspect(f.path), isNull);
      } finally {
        await f.delete();
      }
    });
  });

  group('aspect_ratio 落库链路（CollectCommand → handler → Repository）', () {
    late Repository repo;
    late ItemActionHandler handler;

    setUp(() async {
      repo = Repository();
      handler = ItemActionHandler(repo);
      for (final it in await repo.list(vault: true, includeDeleted: true)) {
        await repo.softDelete(it.id!);
      }
      for (final it in await repo.list(includeDeleted: true)) {
        await repo.softDelete(it.id!);
      }
      await repo.purgeDeleted(retention: Duration.zero);
    });

    test('collect 携带 aspectRatio → 条目持久化', () async {
      final r = await handler.execute(const CollectCommand(
        itemType: InboxItem.typeImage,
        rawFilePath: '/tmp/x.png',
        aspectRatio: 1.5,
      ));
      final item = await repo.byId(r.targetId!);
      expect(item!.aspectRatio, closeTo(1.5, 0.0001));
    });

    test('collect 不带 aspectRatio（文本/MCP add_item 同源）→ null', () async {
      final r = await handler.execute(const CollectCommand(
        itemType: InboxItem.typeNote,
        rawContent: 'hello',
      ));
      final item = await repo.byId(r.targetId!);
      expect(item!.aspectRatio, isNull);
    });

    test('toMap/fromMap 往返保留 aspectRatio', () {
      const raw = {
        'id': 'a1',
        'item_type': InboxItem.typeImage,
        'created_at': 1,
        'aspect_ratio': 0.75,
      };
      final item = InboxItem.fromMap(raw);
      expect(item.aspectRatio, closeTo(0.75, 0.0001));
      expect(item.copyWith().toMap()['aspect_ratio'], closeTo(0.75, 0.0001));
    });
  });
}
