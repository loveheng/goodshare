import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/mcp/tools.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// MCP 工具扩展契约单测（PRD §7）：7 个新工具全部经 ItemActionHandler，
/// 拒绝语义（编辑锁/Schema 校验/Vault 隔离）与直连动作层完全一致。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

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
    final db = await Db.instance();
    await db.delete('ai_task_queue');
  });

  String textOf(List<Map<String, Object?>> blocks) =>
      (blocks.first['text'] as String);

  test('update_item：patch 生效；machine_json 对象自动编码并通过 Schema 校验', () async {
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '原文', createdAt: 1));
    final r = await callTool('update_item', {
      'id': it.id,
      'patch': {
        'title': '新标题',
        'tags': ['mcp'],
        'machine_json': {'schema': 'invoice.v1', 'amount': 9.9, 'date': '2026-09-27', 'merchant': '店'},
      },
    }, repo);
    expect(textOf(r), contains('已更新'));
    final after = await repo.byId(it.id!);
    expect(after!.humanTitle, '新标题');
    expect(after.tags, ['mcp']);
    expect(jsonDecode(after.machineJson!)['schema'], 'invoice.v1');
  });

  test('update_item：非法 machine_json / 编辑锁 拒绝；unlock_edit 后可写', () async {
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('update_item', {
        'id': it.id,
        'patch': {'machine_json': {'schema': 'unknown.v1'}},
      }, repo),
      throwsA(isA<McpRpcError>()),
    );

    final locked = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '合并链',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: 1,
    ));
    expect(
      () => callTool('update_item', {'id': locked.id, 'patch': {'title': '偷改'}}, repo),
      throwsA(isA<McpRpcError>()),
    );
    await callTool('unlock_edit', {'id': locked.id}, repo);
    final r = await callTool('update_item', {'id': locked.id, 'patch': {'title': '解锁后改'}}, repo);
    expect(textOf(r), contains('已更新'));
  });

  test('delete_item 软删除 + reprocess_item 重新入队', () async {
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '待删', createdAt: 1));
    await callTool('delete_item', {'id': it.id}, repo);
    expect(await repo.byId(it.id!), isNull);
    expect((await repo.listDeleted()).length, 1);

    final r = await repo.add(InboxItem(itemType: InboxItem.typeUrl, rawContent: 'https://a.b/c', createdAt: 1));
    await repo.update(r.id!, {'is_processed': 1});
    await callTool('reprocess_item', {'id': r.id}, repo);
    final tasks = await repo.pendingTasks();
    expect(tasks.length, 1);
    expect(tasks.first['task_action'], Repository.taskSummarizeUrl);
  });

  test('set_vault：MCP 可移入；移出被拒绝；移入后对 MCP 不可见', () async {
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '私密', createdAt: 1));
    final r = await callTool('set_vault', {'id': it.id, 'on': true}, repo);
    expect(textOf(r), contains('已移入'));
    expect(await repo.byId(it.id!), isNull, reason: '移入后对 MCP 物理不可见');
    expect(
      () => callTool('set_vault', {'id': it.id, 'on': false}, repo),
      throwsA(isA<McpRpcError>()),
      reason: '移出不可经 MCP，防大模型自行解除 Vault 隔离',
    );
  });

  test('query_machine_data：仅返回带机器态的条目，Vault 不可见', () async {
    final plain = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '无机器态', createdAt: 1));
    final invoice = await repo.add(InboxItem(itemType: InboxItem.typeImage, sourceType: InboxItem.typeImage, rawContent: '发票', createdAt: 2));
    const machine = '{"schema":"invoice.v1","amount":1,"date":"2026-09-27","merchant":"m"}';
    await handler.execute(UpdateItemCommand(id: invoice.id!, machineJson: machine));

    final r = await callTool('query_machine_data', {'type': InboxItem.typeImage}, repo);
    final payload = jsonDecode(textOf(r)) as Map<String, Object?>;
    expect(payload['total'], 1);
    final items = payload['items'] as List;
    expect((items.first as Map)['machine_json']['schema'], 'invoice.v1');
    expect(items.first, isNot(equals(plain.id)));

    // Vault 条目即便有机器态也不可见
    await handler.execute(SetVaultCommand(invoice.id!, true));
    final r2 = await callTool('query_machine_data', {}, repo);
    expect((jsonDecode(textOf(r2)) as Map<String, Object?>)['total'], 0);
  });

  test('get_timeline_context：返回当日收集，health/events 恒空', () async {
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '今天的一条', createdAt: now.millisecondsSinceEpoch));
    await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '昨天的',
      isVault: true,
      createdAt: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
    ));

    final r = await callTool('get_timeline_context', {'date': date}, repo);
    final payload = jsonDecode(textOf(r)) as Map<String, Object?>;
    expect(payload['date'], date);
    expect(payload['health'], isNull);
    expect((payload['events'] as List), isEmpty);
    final ingested = payload['ingested_items'] as List;
    expect(ingested.length, 1);
    expect((ingested.first as Map)['preview'], contains('今天的一条'));

    expect(
      () => callTool('get_timeline_context', {'date': '2026/09/27'}, repo),
      throwsA(isA<McpRpcError>()),
    );
  });

  test('工具清单共 12 个且不含 execute_action', () {
    final names = toolSchemas().map((s) => s['name']).toList();
    expect(names.length, 12);
    expect(names, isNot(contains('execute_action')));
    expect(names, containsAll(['update_item', 'unlock_edit', 'set_vault', 'reprocess_item', 'query_machine_data', 'get_timeline_context', 'batch_items', 'append_segment']));
  });

  test('expected_version 乐观锁：版本过期 → version_conflict，不静默覆盖', () async {
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '原文', createdAt: 1));
    final first = jsonDecode(textOf(await callTool('update_item', {
      'id': it.id,
      'patch': {'title': 'AI 改的'},
    }, repo))) as Map<String, Object?>;
    expect((first['item'] as Map<String, Object?>)['version'], 1, reason: '快照回传最新 version');

    try {
      await callTool('update_item', {
        'id': it.id,
        'patch': {'title': '拿着旧版本改'},
        'expected_version': 0,
      }, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect((e.data as Map<String, Object?>)['code'], ActionErrorCode.versionConflict);
    }
    expect((await repo.byId(it.id!))!.humanTitle, 'AI 改的');
  });

  test('append_segment：AI 可往合并链追加，散列条目被拒', () async {
    final chain = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '首段',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final payload = jsonDecode(textOf(await callTool('append_segment', {
      'id': chain.id,
      'text': 'AI 追加的段',
      'source_app': 'MCP (AI 写入)',
    }, repo))) as Map<String, Object?>;
    expect((payload['item'] as Map<String, Object?>)['text'], contains('AI 追加的段'));

    // 散列条目不可追加（模式约束在动作层，AI 同样受限）
    final plain = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('append_segment', {'id': plain.id, 'text': 'y'}, repo),
      throwsA(isA<McpRpcError>()),
    );
  });

  test('写工具返回最新条目快照（AI 上下文与数据库对齐）', () async {
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '原文', createdAt: 1));
    final payload = jsonDecode(textOf(await callTool('update_item', {
      'id': it.id,
      'patch': {'title': '最新标题', 'tags': ['对齐']},
    }, repo))) as Map<String, Object?>;
    final item = payload['item'] as Map<String, Object?>;
    expect(payload['ok'], isTrue);
    expect(item['title'], '最新标题');
    expect(item['tags'], ['对齐']);
    expect(item['edit_locked'], isFalse);
  });

  test('batch_items：解锁+改字+打标签 一次原子提交', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '合并链',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: 1,
    ));
    final payload = jsonDecode(textOf(await callTool('batch_items', {
      'commands': [
        {'op': 'unlock_edit', 'id': it.id},
        {'op': 'update', 'id': it.id, 'title': '批量标题', 'tags': ['x']},
      ],
    }, repo))) as Map<String, Object?>;
    expect(payload['count'], 2);
    final after = await repo.byId(it.id!);
    expect(after!.humanTitle, '批量标题');
    expect(after.tags, ['x']);
    expect(after.editLocked, isFalse);
  });

  test('batch_items：中途失败整批回滚，不留半成品', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '原文',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: 1,
    ));
    expect(
      () => callTool('batch_items', {
        'commands': [
          {'op': 'unlock_edit', 'id': it.id},
          {'op': 'update', 'id': it.id, 'title': '改了'},
          {'op': 'update', 'id': it.id, 'machine_json': {'schema': 'unknown.v1'}},
        ],
      }, repo),
      throwsA(isA<McpRpcError>()),
    );
    final after = await repo.byId(it.id!);
    expect(after!.editLocked, isTrue, reason: '解锁已回滚');
    expect(after.humanTitle, isNull, reason: '标题改动已回滚');
  });

  test('拒绝语义带机器可读 code：AI 可读懂并自我纠正', () async {
    final locked = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: 'x',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: 1,
    ));
    try {
      await callTool('update_item', {'id': locked.id, 'patch': {'title': '偷改'}}, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect(e.code, errInvalidParams);
      final data = e.data as Map<String, Object?>;
      expect(data['code'], ActionErrorCode.editLocked);
      expect(data['hint'], contains('unlock_edit'));
    }
  });
}
