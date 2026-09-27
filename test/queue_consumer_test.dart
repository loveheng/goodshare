import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/queue_consumer.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 队列消费者契约单测：占位管线端到端、Registry 路由、失败路径、删除竞态兜底。
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

  /// 测试用假实现：可控可用性 / 固定产出 / 可抛错。
  FakeReconstructor fake({
    bool available = true,
    ReconstructResult? result,
    bool throwError = false,
  }) =>
      FakeReconstructor(
        available: available,
        result: result ??
            const ReconstructResult(humanMd: '占位产出', tags: ['测试'], masked: true),
        throwError: throwError,
      );

  test('占位端到端：入队 → 消费 → human_md=raw、is_processed=1、任务完成', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '原始脏数据',
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    final consumer = QueueConsumer(repo, ReconstructorRegistry.defaultRegistry());

    final n = await consumer.pollOnce();
    expect(n, 1);
    final after = await repo.byId(it.id!);
    expect(after!.humanMd, '原始脏数据', reason: '占位管线原样复制 raw→human_md');
    expect(after.isProcessed, 1);
    expect(after.machineJson, isNull, reason: '占位实现 machine_json 留空');
    expect(await repo.pendingTasks(), isEmpty);
  });

  test('Registry 路由：首个可用实现优先，产出全字段落库', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeImage,
      sourceType: InboxItem.typeImage,
      rawContent: null,
      rawFilePath: '/tmp/a.jpg',
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, Repository.taskOcrAndExtract);
    final registry = ReconstructorRegistry([
      fake(available: false),
      fake(result: ReconstructResult(
        humanMd: '重分类产出',
        machineJson: {'schema': 'invoice.v1', 'amount': 1, 'date': 'd', 'merchant': 'm'},
        tags: const ['发票'],
        itemType: InboxItem.typeDocument,
        facets: const {'主题': ['报销']},
      )),
      const PlaceholderReconstructor(),
    ]);
    await QueueConsumer(repo, registry).pollOnce();

    final after = await repo.byId(it.id!);
    expect(after!.humanMd, '重分类产出');
    expect(after.machineJson, isNotNull);
    expect(after.tags, ['发票']);
    expect(after.itemType, InboxItem.typeDocument, reason: 'AI 重分类走管线特权路径');
    expect(after.facets?['主题'], ['报销']);
  });

  test('失败路径：实现抛错 → 任务 failed、is_processed=-1', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: 'x',
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    await QueueConsumer(repo, ReconstructorRegistry([fake(throwError: true)])).pollOnce();

    expect((await repo.byId(it.id!))!.isProcessed, -1);
    expect(await repo.pendingTasks(), isEmpty);
  });

  test('reprocess 链路：Handler 重置处理态并入队，消费者再处理', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '再处理一次',
      createdAt: 1,
    ));
    await repo.update(it.id!, {'is_processed': 1, 'human_md': '旧产出'});
    await handler.reprocess(it.id!);
    await QueueConsumer(repo, ReconstructorRegistry.defaultRegistry()).pollOnce();

    final after = await repo.byId(it.id!);
    expect(after!.humanMd, '再处理一次', reason: '占位重跑覆盖旧产出');
    expect(after.isProcessed, 1);
  });

  test('已删条目竞态兜底：任务置 cancelled，条目不被写入', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '待删',
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    await repo.softDelete(it.id!);
    await QueueConsumer(repo, ReconstructorRegistry.defaultRegistry()).pollOnce();

    expect(await repo.pendingTasks(), isEmpty);
    final deleted = await repo.byId(it.id!, includeDeleted: true);
    expect(deleted!.humanMd, isNull, reason: '已删条目不被管线写入');
  });
}

class FakeReconstructor implements AiReconstructor {
  FakeReconstructor({
    required this.available,
    this.result,
    this.throwError = false,
  });

  final bool available;
  final ReconstructResult? result;
  final bool throwError;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    if (throwError) throw StateError('模拟推理失败');
    return result!;
  }
}