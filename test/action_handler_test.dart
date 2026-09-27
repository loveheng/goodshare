import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 共用动作层契约单测：UI 与 MCP 的写路径都经此层（PRD §7 / D4·F7 决策）。
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
    // 清空上例残留（内存库按测试文件共享）：Vault 内外全部软删后物理清理
    for (final it in await repo.list(vault: true, includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    for (final it in await repo.list(includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    await repo.purgeDeleted(retention: Duration.zero);
  });

  InboxItem newItem({String? type, String? sourceType, bool locked = false, bool vault = false}) =>
      InboxItem(
        itemType: type ?? InboxItem.typeNote,
        sourceType: sourceType,
        rawContent: 'raw body',
        editLocked: locked,
        isVault: vault,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  test('edit 写回标题/标签/人类态', () async {
    final it = await repo.add(newItem());
    final after = await handler.edit(it.id!, title: '新标题', tags: ['x'], humanMd: '# md');
    expect(after.humanTitle, '新标题');
    expect(after.tags, ['x']);
    expect(after.humanMd, '# md');
  });

  test('合并锁定条目拒绝编辑，解锁后方可写', () async {
    final it = await repo.add(newItem(locked: true));
    expect(() => handler.edit(it.id!, title: '偷改'), throwsA(isA<ActionException>()));
    await handler.unlockEdit(it.id!);
    final after = await handler.edit(it.id!, title: '解锁后改');
    expect(after.humanTitle, '解锁后改');
    expect(after.editLocked, isFalse);
  });

  test('machine_json 强校验：非法 JSON / 未知 schema / 缺必填字段 / 合法 invoice.v1', () async {
    final it = await repo.add(newItem());
    expect(() => handler.edit(it.id!, machineJson: '{oops'), throwsA(isA<ActionException>()));
    expect(
      () => handler.edit(it.id!, machineJson: '{"schema":"nope.v9"}'),
      throwsA(isA<ActionException>()),
    );
    expect(
      () => handler.edit(it.id!, machineJson: '{"schema":"invoice.v1","amount":1}'),
      throwsA(isA<ActionException>()),
    );
    final ok = '{"schema":"invoice.v1","amount":12.5,"date":"2026-09-27","merchant":"店家"}';
    final after = await handler.edit(it.id!, machineJson: ok);
    expect(after.machineJson, ok);
  });

  test('重分类白名单：仅 source_type=image 可 image→chatlog/document', () async {
    final shot = await repo.add(newItem(type: InboxItem.typeImage, sourceType: InboxItem.typeImage));
    final moved = await handler.reclassify(shot.id!, InboxItem.typeChatlog);
    expect(moved.itemType, InboxItem.typeChatlog);

    final note = await repo.add(newItem());
    expect(
      () => handler.reclassify(note.id!, InboxItem.typeChatlog),
      throwsA(isA<ActionException>()),
    );

    final img2 = await repo.add(newItem(type: InboxItem.typeImage, sourceType: InboxItem.typeImage));
    expect(
      () => handler.reclassify(img2.id!, InboxItem.typeUrl),
      throwsA(isA<ActionException>()),
    );
    // update_item 的 item_type 路径走同一校验
    expect(
      () => handler.edit(img2.id!, itemType: InboxItem.typeChatlog),
      returnsNormally,
    );
  });

  test('setVault 进出保险箱；非 vaultContext 动作对 Vault 条目不可见', () async {
    final it = await repo.add(newItem());
    await handler.setVault(it.id!, true);
    expect((await repo.list()), isEmpty, reason: 'Vault 条目对默认查询不可见');
    expect((await repo.list(vault: true)).length, 1);
    // MCP 口径（vaultContext=false）看不到 Vault 条目
    expect(() => handler.delete(it.id!), throwsA(isA<ActionException>()));
    // UI 保险箱页口径（vaultContext=true）可操作
    await handler.delete(it.id!, vaultContext: true);
    expect((await repo.list(vault: true, includeDeleted: true)).first.isDeleted, isTrue);
  });

  test('reprocess 重置处理态并入队；note 用 null action 走通用重构', () async {
    final it = await repo.add(newItem());
    await repo.update(it.id!, {'is_processed': 1});
    await handler.reprocess(it.id!);
    final after = await repo.byId(it.id!);
    expect(after?.isProcessed, 0);
    final tasks = await repo.pendingTasks();
    expect(tasks.length, 1);
    expect(tasks.first['item_id'], it.id);
    expect(tasks.first['task_action'], isNull, reason: 'note 无专属 task_action，由消费者按类型通用重构');
  });

  test('delete 软删除并入最近删除', () async {
    final it = await repo.add(newItem());
    await handler.delete(it.id!);
    expect(await repo.byId(it.id!), isNull);
    expect((await repo.listDeleted()).length, 1);
  });
}
