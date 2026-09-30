import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/palette_reconstructor.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/action/machine_json_validator.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// V3 主色调（rich-text-component.md §6.1）：摄入队列 Job 化算图片主色，
/// hex 落 machine_json（color.v1），渲染前作占位底色。
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  group('纯函数（colorToHex / colorFromMachineJson）', () {
    test('Color → hex 六位无透明', () {
      expect(colorToHex(const Color(0xFFFF0000)), '#ff0000');
      expect(colorToHex(const Color(0x80123456)), '#123456', reason: '丢弃 alpha');
      expect(colorToHex(const Color(0xFF0A0B0C)), '#0a0b0c', reason: '补零');
    });

    test('machine_json 往返；坏输入安全返回 null', () {
      const raw = '{"schema":"color.v1","hex":"#a1b2c3"}';
      expect(colorFromMachineJson(raw), const Color(0xFFA1B2C3));
      expect(colorFromMachineJson('{"schema":"color.v1","hex":"a1b2c"}'),
          isNull, reason: '7 位既非 rrggbb 也非 aarrggbb');
      expect(colorFromMachineJson('{"schema":"color.v1","hex":"80123456"}'),
          const Color(0x80123456), reason: '容忍 8 位 aarrggbb');
      expect(colorFromMachineJson('not json'), isNull);
      expect(colorFromMachineJson('{"schema":"og.v1","hex":"#ffffff"}'), isNull);
      expect(colorFromMachineJson('{"schema":"color.v1","hex":"#zzzzzz"}'), isNull);
      expect(colorFromMachineJson(null), isNull);
    });

    test('color.v1 通过 schema 强校验；缺 hex 拒绝', () {
      expect(
          validateMachineJson(jsonEncode({'schema': 'color.v1', 'hex': '#aabbcc'})), isNull);
      expect(validateMachineJson(jsonEncode({'schema': 'color.v1'})), isNotNull);
    });
  });

  group('PaletteReconstructor（队列 Job）', () {
    final reconstructor = const PaletteReconstructor();

    ReconstructInput input({String? path, String? action}) => ReconstructInput(
          itemId: 'i1',
          itemType: InboxItem.typeImage,
          rawContent: '原始内容',
          rawFilePath: path,
          taskAction: action,
        );

    test('仅 image + extract_palette 认领', () async {
      expect(await reconstructor.handles(input(action: Repository.taskExtractPalette)), isTrue);
      expect(await reconstructor.handles(input(action: Repository.taskOcrAndExtract)), isFalse);
      expect(
          await reconstructor.handles(ReconstructInput(
            itemId: 'i2',
            itemType: InboxItem.typeNote,
            rawContent: 'x',
            taskAction: Repository.taskExtractPalette,
          )),
          isFalse);
    });

    test('文件缺失 → 占位完成 + 原因（不置死信）', () async {
      final r = await reconstructor.reconstruct(input(path: '/nonexistent/a.png'));
      expect(r.humanMd, '原始内容');
      expect(r.note, contains('不可访问'));
    });

    test('真实 PNG 夹具（纯红 2x1）→ 主色红系', () async {
      final r = await reconstructor.reconstruct(
          input(path: 'test/fixtures/probe_2x1.png', action: Repository.taskExtractPalette));
      expect(r.note, isNull, reason: '纯色图不应失败：${r.note}');
      final color = colorFromMachineJson(jsonEncode(r.machineJson));
      expect(color, isNotNull);
      // 默认 filter 避开纯红黑白，dominant 取近似红即可
      expect((color!.r * 255.0).round(), greaterThan(120));
    });
  });

  group('摄入路由（taskActionFor）', () {
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

    test('图片摄入自动入队 extract_palette；文本仍不入队', () async {
      expect(Repository.taskActionFor(InboxItem.typeImage), Repository.taskExtractPalette);
      final r = await handler.execute(const CollectCommand(
        itemType: InboxItem.typeImage,
        rawFilePath: '/tmp/x.png',
      ));
      final pending = await repo.pendingTasks();
      expect(pending.map((t) => t['task_action']), contains(Repository.taskExtractPalette));
      expect(r.targetId, isNotNull);
    });
  });
}
