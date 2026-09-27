import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据层契约单测：Schema 重建后的核心行为（PRD §5.3 / §7 隐私硬约束）。
void main() {
  setUpAll(() {
    // VM 单测用 ffi 数据库工厂；内存库做 isolate 级隔离（套件并行不互踩）
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  test('入库生成 uuid，默认查询排除 Vault 与已删', () async {
    final repo = Repository();
    final a = await repo.add(
      InboxItem(itemType: InboxItem.typeNote, rawContent: 'hello 世界', createdAt: 1),
    );
    expect(a.id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
    await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: 'vault only',
      isVault: true,
      createdAt: 2,
    ));
    expect(await repo.count(), 1, reason: 'count 默认排除 Vault');
    final listed = await repo.list();
    expect(listed.length, 1);
    expect(listed.first.rawContent, 'hello 世界');
    expect(await repo.byId(a.id!), isNotNull);
    expect((await repo.list(vault: true)).first.rawContent, 'vault only', reason: 'Vault 视图显式可查');
  });

  test('关键词与类型过滤命中标题/原文/标签', () async {
    final repo = Repository();
    await repo.add(InboxItem(
      itemType: InboxItem.typeUrl,
      humanTitle: '一篇好文章',
      rawContent: 'https://a.b/c',
      tags: const ['前端'],
      createdAt: 1,
    ));
    expect(await repo.count(query: '好文章'), 1);
    expect(await repo.count(query: '前端'), 1);
    expect(await repo.count(query: 'a.b/c'), 1);
    expect(await repo.count(type: InboxItem.typeUrl), 1);
    expect(await repo.count(type: InboxItem.typeVideo), 0);
  });

  test('软删除→默认不可见→可恢复；关联队列任务被取消', () async {
    final repo = Repository();
    final it = await repo.add(
      InboxItem(itemType: InboxItem.typeUrl, rawContent: 'https://a.b/c', createdAt: 1),
    );
    await repo.enqueueTask(it.id!, Repository.taskSummarizeUrl);
    expect((await repo.pendingTasks()).length, 1);

    await repo.softDelete(it.id!);
    expect(await repo.byId(it.id!), isNull, reason: '已删条目不可读');
    expect((await repo.listDeleted()).length, 1);
    expect(await repo.pendingTasks(), isEmpty, reason: '软删应取消关联任务');

    await repo.restore(it.id!);
    expect(await repo.byId(it.id!), isNotNull);
    expect((await repo.listDeleted()), isEmpty);
  });

  test('purgeDeleted 超过保留期物理清理', () async {
    final repo = Repository();
    final it = await repo.add(
      InboxItem(itemType: InboxItem.typeNote, rawContent: '老的已删条目', createdAt: 1),
    );
    await repo.softDelete(it.id!);
    final purged = await repo.purgeDeleted(retention: Duration.zero);
    expect(purged, 1);
    expect((await repo.listDeleted()), isEmpty);
    expect(await repo.byId(it.id!, includeDeleted: true), isNull);
  });

  test('update 按列写回，byId 反映新值', () async {
    final repo = Repository();
    final it = await repo.add(
      InboxItem(itemType: InboxItem.typeNote, rawContent: 'raw', createdAt: 1),
    );
    await repo.update(it.id!, {'human_title': '新标题', 'human_tldr': '一句话'});
    final after = await repo.byId(it.id!);
    expect(after?.humanTitle, '新标题');
    expect(after?.humanTldr, '一句话');
    expect(after?.preview, '新标题');
  });

  test('模型 round-trip：tags/facets/appendix/todo_state JSON 序列化', () {
    final item = InboxItem(
      id: 'x',
      itemType: InboxItem.typeImage,
      rawFilePath: '/tmp/a.jpg',
      tags: const ['a', 'b'],
      facets: const {'主题': ['前端']},
      appendix: const [AppendixEntry(ts: 1, text: '段一', source: 'clipboard')],
      todoState: const [TodoMark(hash: 'h1', done: true)],
      createdAt: 5,
    );
    final back = InboxItem.fromMap(item.toMap());
    expect(back.tags, ['a', 'b']);
    expect(back.facets?['主题'], ['前端']);
    expect(back.appendix.single.text, '段一');
    expect(back.todoState.single.done, isTrue);
    expect(back.hasAttachment, isTrue);
  });
}
