import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 工作区命令单测（2026-09-30）：条目集合容器，多对多，见 ui-spec §4.11。
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
  });

  InboxItem newItem({bool vault = false}) => InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: 'raw body',
        isVault: vault,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  group('命令 JSON 往返', () {
    test('create_workspace：AI JSON 解析与 UI 组装等价', () {
      final c = ItemCommand.fromJson({'op': 'create_workspace', 'name': '旅行'});
      expect(c, isA<CreateWorkspaceCommand>());
      expect((c as CreateWorkspaceCommand).name, '旅行');
      expect(c.targetId, isNull);
    });

    test('rename / delete / add / remove 四命令往返', () {
      final r = ItemCommand.fromJson({
        'op': 'rename_workspace',
        'workspace_id': 'w1',
        'name': '新名',
      }) as RenameWorkspaceCommand;
      expect(r.workspaceId, 'w1');
      expect(r.name, '新名');

      final d = ItemCommand.fromJson({'op': 'delete_workspace', 'workspace_id': 'w1'})
          as DeleteWorkspaceCommand;
      expect(d.workspaceId, 'w1');
      final dAck = ItemCommand.fromJson({
        'op': 'delete_workspace',
        'workspace_id': 'w1',
        'ack_non_empty': true,
      }) as DeleteWorkspaceCommand;
      expect(dAck.ackNonEmpty, isTrue);

      final a = ItemCommand.fromJson({
        'op': 'add_to_workspace',
        'workspace_id': 'w1',
        'id': 'i1',
        'expected_version': 3,
      }) as AddToWorkspaceCommand;
      expect(a.workspaceId, 'w1');
      expect(a.targetId, 'i1');
      expect(a.expectedVersion, 3);

      final rm = ItemCommand.fromJson({
        'op': 'remove_from_workspace',
        'workspace_id': 'w1',
        'id': 'i1',
      }) as RemoveFromWorkspaceCommand;
      expect(rm.workspaceId, 'w1');
      expect(rm.targetId, 'i1');
    });

    test('supportedOps 含全部工作区命令', () {
      expect(ItemCommand.supportedOps, containsAll([
        'create_workspace',
        'rename_workspace',
        'delete_workspace',
        'add_to_workspace',
        'remove_from_workspace',
      ]));
    });
  });

  group('handler 执行', () {
    test('创建→加入→列出成员→移出 全链路', () async {
      final created = await handler.execute(const CreateWorkspaceCommand('旅行'));
      final wsId = created.targetId!;
      expect(created.note, contains('旅行'));

      final it = await repo.add(newItem());
      final added = await handler.execute(AddToWorkspaceCommand(wsId, it.id!));
      expect(added.note, contains('旅行'));

      final members = await repo.listWorkspaceItems(wsId);
      expect(members.map((e) => e.id), [it.id]);

      await handler.execute(RemoveFromWorkspaceCommand(wsId, it.id!));
      expect(await repo.listWorkspaceItems(wsId), isEmpty);
    });

    test('重复加入幂等：不报错、成员不重复', () async {
      final ws = await repo.createWorkspace('收藏');
      final it = await repo.add(newItem());
      await handler.execute(AddToWorkspaceCommand(ws.id, it.id!));
      await handler.execute(AddToWorkspaceCommand(ws.id, it.id!));
      final members = await repo.listWorkspaceItems(ws.id);
      expect(members.length, 1);
    });

    test('加入不存在的条目 / 不存在的工作区 → not_found', () async {
      final ws = await repo.createWorkspace('x');
      expect(
        () => handler.execute(AddToWorkspaceCommand(ws.id, 'no-such-item')),
        throwsA(predicate((e) => e.toString().contains('条目不存在'))),
      );

      final it = await repo.add(newItem());
      expect(
        () => handler.execute(AddToWorkspaceCommand('no-such-ws', it.id!)),
        throwsA(predicate((e) => e.toString().contains('工作区不存在'))),
      );
    });

    test('空名称拒绝；重命名与删除走 handler', () async {
      expect(
        () => handler.execute(const CreateWorkspaceCommand('  ')),
        throwsA(predicate((e) => e.toString().contains('名称不能为空'))),
      );

      final ws = await repo.createWorkspace('旧名');
      final renamed = await handler.execute(RenameWorkspaceCommand(ws.id, '新名'));
      expect(renamed.note, contains('新名'));
      expect((await repo.byIdWorkspace(ws.id))!.name, '新名');

      // 空工作区无需 ack 即可删
      final deleted = await handler.execute(DeleteWorkspaceCommand(ws.id));
      expect(deleted.note, contains('已删除工作区「新名」'));
      expect(await repo.byIdWorkspace(ws.id), isNull);
    });

    test('非空守门：无 ack 拒绝（计数同源）；ui 带 ack 快捷删、条目保留', () async {
      final ws = await repo.createWorkspace('收藏');
      final it = await repo.add(newItem());
      await handler.execute(AddToWorkspaceCommand(ws.id, it.id!));

      // 无 ack：被拦，工作区与归属都在
      await expectLater(
        handler.execute(DeleteWorkspaceCommand(ws.id)),
        throwsA(predicate((e) => e.toString().contains('还有 1 条内容'))),
      );
      expect(await repo.byIdWorkspace(ws.id), isNotNull);

      // ui 带 ack（弹窗「保留内容并删除」的落点）：删除成功，条目本身保留
      final deleted = await handler.execute(
        DeleteWorkspaceCommand(ws.id, ackNonEmpty: true),
      );
      expect(deleted.note, contains('1 条内容保留在「全部」'));
      expect(await repo.byIdWorkspace(ws.id), isNull);
      expect((await repo.byId(it.id!, includeDeleted: true))!.id, it.id);
      expect(
        await repo.listWorkspaceItems(ws.id),
        isEmpty,
        reason: '关系行随外键级联清理，条目仍在「全部」',
      );
    });

    test('非空守门对 AI 同口径：ack 只认 ui actor（D-WS2 对称性）', () async {
      final ws = await repo.createWorkspace('收藏');
      final it = await repo.add(newItem());
      await handler.execute(AddToWorkspaceCommand(ws.id, it.id!));

      // AI 无 ack：普通拦截（带条数）
      await expectLater(
        handler.execute(DeleteWorkspaceCommand(ws.id), actor: CommandActor.ai),
        throwsA(predicate((e) => e.toString().contains('还有 1 条内容'))),
      );
      // AI 自带 ack：仍然拒绝——确认权只在人类 UI
      await expectLater(
        handler.execute(
          DeleteWorkspaceCommand(ws.id, ackNonEmpty: true),
          actor: CommandActor.ai,
        ),
        throwsA(predicate((e) => e.toString().contains('仅人类 UI'))),
      );
      expect(await repo.byIdWorkspace(ws.id), isNotNull);
    });

    test('Vault 条目对 AI actor 不可加入（隐私后门拦截）', () async {
      final ws = await repo.createWorkspace('私密');
      final secret = await repo.add(newItem(vault: true));
      expect(
        () => handler.execute(
          AddToWorkspaceCommand(ws.id, secret.id!),
          actor: CommandActor.ai,
        ),
        throwsA(predicate((e) => e.toString().contains('不存在或不可见'))),
      );
      // UI（vaultContext）可以加入——保险箱页口径
      final ok = await handler.execute(
        AddToWorkspaceCommand(ws.id, secret.id!),
        vaultContext: true,
      );
      expect(ok.note, isNotNull);
    });

    test('删除工作区级联清关系行（外键 ON DELETE CASCADE）', () async {
      final ws = await repo.createWorkspace('级联');
      final it = await repo.add(newItem());
      await handler.execute(AddToWorkspaceCommand(ws.id, it.id!));
      await repo.deleteWorkspace(ws.id);
      expect(await repo.listWorkspaceItems(ws.id), isEmpty);
      // 关系行物理消失（级联而非悬空）：再次新建同名工作区后成员为空
      final ws2 = await repo.createWorkspace('级联');
      expect(await repo.listWorkspaceItems(ws2.id), isEmpty);
      expect(ws2.id, isNot(ws.id));
    });
  });

  group('数据层', () {
    test('listWorkspaces 按创建时间倒序；一个条目可进多个工作区', () async {
      final w1 = await repo.createWorkspace('a');
      // createdAt 是毫秒时间戳：同毫秒连续创建会打平（排序并列属合法结果），
      // 造数跨毫秒才能对严格倒序下断言（2026-09-30 修并发跑时的随机炸）
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final w2 = await repo.createWorkspace('b');
      final names = (await repo.listWorkspaces()).map((w) => w.name).toList();
      expect(names.indexOf('b'), lessThan(names.indexOf('a')));

      final it = await repo.add(newItem());
      await repo.addToWorkspace(w1.id, it.id!);
      await repo.addToWorkspace(w2.id, it.id!);
      final owners = await repo.listItemWorkspaces(it.id!);
      expect(owners.map((w) => w.id).toSet(), {w1.id, w2.id});
    });
  });
}
