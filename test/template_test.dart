import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 内容生产模板（ai-template P1）契约单测：Repository CRUD + 乐观锁 + 删除不
/// 级联产出 + handler 命令出口（R2）+ itemToJson 暴露 template_output。
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
    await db.delete('templates');
    await db.delete('workspaces');
  });

  Future<String> seedWorkspace() async {
    final ws = await repo.createWorkspace('测试工作区');
    return ws.id;
  }

  test('Repository Template CRUD：create/list/byId/update/delete', () async {
    final wsId = await seedWorkspace();
    final t = await repo.createTemplate(
      workspaceId: wsId,
      name: '会议纪要',
      bodyMd: '# {{date}}\n参会：{{who}}',
      description: '会议模板',
    );
    expect(t.name, '会议纪要');
    expect(t.version, 0);
    expect(t.origin, 'ai');

    expect((await repo.listTemplates()).length, 1);
    expect((await repo.byIdTemplate(t.id))!.bodyMd, contains('{{date}}'));

    final updated = await repo.updateTemplate(t.id, name: '会议纪要 v2', bodyMd: '# 新');
    expect(updated!.name, '会议纪要 v2');
    expect(updated.version, 1);

    await repo.deleteTemplate(t.id);
    expect(await repo.byIdTemplate(t.id), isNull);
  });

  test('updateTemplate 乐观锁：expectedVersion 不符抛 StateError，符和则 version+1', () async {
    final wsId = await seedWorkspace();
    final t = await repo.createTemplate(workspaceId: wsId, name: 'T', bodyMd: 'x');
    expect(
      () => repo.updateTemplate(t.id, name: 'X', expectedVersion: 5),
      throwsA(isA<StateError>()),
    );
    final ok = await repo.updateTemplate(t.id, name: 'X', expectedVersion: 0);
    expect(ok!.version, 1);
  });

  test('deleteTemplate 不级联 template_output（松散关联，产出作归档保留）', () async {
    final wsId = await seedWorkspace();
    final t = await repo.createTemplate(workspaceId: wsId, name: 'T', bodyMd: 'x');
    final it = await repo.add(
        InboxItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    // 直接写库造 template_output（P2 才经 apply_落库；此处验证数据层契约）
    final db = await Db.instance();
    await db.update(
      'inbox_items',
      {'template_output': '结构化产出', 'template_id': t.id},
      where: 'id = ?',
      whereArgs: [it.id],
    );
    await repo.deleteTemplate(t.id);
    // 模板没了，但条目的 template_output 仍作为归档内容保留
    expect(await repo.byIdTemplate(t.id), isNull);
    final after = await repo.byId(it.id!);
    expect(after!.templateOutput, '结构化产出');
    expect(after.templateId, t.id);
  });

  test('handler.execute 模板命令：create/update CAS/delete 走 R2 出口', () async {
    final wsId = await seedWorkspace();
    final r1 = await handler.execute(
        CreateTemplateCommand(wsId, '纪要', bodyMd: '# x'),
        actor: CommandActor.ai);
    expect(r1.op, 'create_template');
    final tid = r1.targetId!;

    await handler.execute(UpdateTemplateCommand(tid, name: '纪要2', expectedVersion: 0),
        actor: CommandActor.ai);
    expect((await repo.byIdTemplate(tid))!.version, 1);

    // 版本冲突 → version_conflict（ActionException），不静默覆盖
    expect(
      () => handler.execute(UpdateTemplateCommand(tid, name: 'X', expectedVersion: 0),
          actor: CommandActor.ai),
      throwsA(isA<ActionException>()),
    );

    final r3 = await handler.execute(DeleteTemplateCommand(tid), actor: CommandActor.ai);
    expect(r3.op, 'delete_template');
    expect(await repo.byIdTemplate(tid), isNull);
  });

  test('itemToJson 暴露 template_output（与 summary 对称、语义分离）', () async {
    final wsId = await seedWorkspace();
    final t = await repo.createTemplate(workspaceId: wsId, name: 'T', bodyMd: 'x');
    final it = await repo.add(
        InboxItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    final db = await Db.instance();
    await db.update(
      'inbox_items',
      {'template_output': '产出内容', 'template_id': t.id},
      where: 'id = ?',
      whereArgs: [it.id],
    );
    final fresh = await repo.byId(it.id!);
    final json = itemToJson(fresh!);
    expect(json['template_output'], '产出内容');
    expect(json['template_id'], t.id);
    expect(json['template_output_stale'], isA<bool>());
    // 语义分离：无摘要时不应出现 summary 字段，template_output 独立落点
    expect(json.containsKey('summary'), isFalse);
  });
}
