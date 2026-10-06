import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/ocr_reconstructor.dart';
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
      aiProcess: true, // 授权管线处理（默认关闭，测试显式开启）
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    final consumer = QueueConsumer(repo, ReconstructorRegistry.defaultRegistry(), handler);

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
      aiProcess: true, // 授权管线处理
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
    await QueueConsumer(repo, registry, handler).pollOnce();

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
      aiProcess: true, // 授权管线处理
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    await QueueConsumer(repo, ReconstructorRegistry([fake(throwError: true)]), handler).pollOnce();

    expect((await repo.byId(it.id!))!.isProcessed, -1);
    expect(await repo.pendingTasks(), isEmpty);
    // 错误原因必须落库（2026-09-28 决策：错误要被用户/AI 感知，不能只剩 debugPrint）
    final task = await repo.lastTaskOf(it.id!);
    expect(task?['status'], 'failed');
    expect(task?['last_note'], isNotEmpty);
  });

  test('完成但无产出：result.note 落库，状态仍 completed（非静默成功）', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: 'x',
      aiProcess: true, // 授权管线处理
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    // 模拟转写重构器：返回空产出但带原因说明（而非静默成功）
    await QueueConsumer(
      repo,
      ReconstructorRegistry([fake(result: ReconstructResult(humanMd: '', note: '未识别出语音内容'))]),
      handler,
    ).pollOnce();
    final task = await repo.lastTaskOf(it.id!);
    expect(task?['status'], 'completed');
    expect(task?['last_note'], contains('未识别出'));
  });

  test('reprocess 链路：Handler 重置处理态并入队，消费者再处理', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '再处理一次',
      aiProcess: true, // 授权管线处理
      createdAt: 1,
    ));
    await repo.update(it.id!, {'is_processed': 1, 'human_md': '旧产出'});
    await handler.execute(ReprocessCommand(it.id!));
    await QueueConsumer(repo, ReconstructorRegistry.defaultRegistry(), handler).pollOnce();

    final after = await repo.byId(it.id!);
    expect(after!.humanMd, '再处理一次', reason: '占位重跑覆盖旧产出');
    expect(after.isProcessed, 1);
  });

  test('OcrReconstructor：非图片走占位复制；图片 OCR 不可用时优雅降级不置死信', () async {
    // 非图片：占位复制
    final note = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '普通文本', aiProcess: true, createdAt: 1));
    await repo.enqueueTask(note.id!, null);
    await QueueConsumer(
      repo,
      ReconstructorRegistry([const OcrReconstructor(), const PlaceholderReconstructor()]),
      handler,
    ).pollOnce();
    expect((await repo.byId(note.id!))!.humanMd, '普通文本');

    // 图片：VM 测试无 ML Kit 平台通道 → 实现内捕获并降级为占位行为（is_processed=1，非死信）
    final img = await repo.add(InboxItem(
      itemType: InboxItem.typeImage,
      sourceType: InboxItem.typeImage,
      rawFilePath: '/tmp/nonexistent.jpg',
      aiProcess: true, // 授权管线处理
      createdAt: 2,
    ));
    await repo.enqueueTask(img.id!, Repository.taskOcrAndExtract);
    await QueueConsumer(
      repo,
      ReconstructorRegistry([const OcrReconstructor(), const PlaceholderReconstructor()]),
      handler,
    ).pollOnce();
    final after = await repo.byId(img.id!);
    expect(after!.isProcessed, 1, reason: 'OCR 失败降级不置 -1');
    expect(await repo.pendingTasks(), isEmpty);
  });

  test('OCR 开关门控：关闭后图片走占位复制（2026-09-27 决策）', () async {
    final img = await repo.add(InboxItem(
      itemType: InboxItem.typeImage,
      sourceType: InboxItem.typeImage,
      rawContent: '图片附带的文字',
      rawFilePath: '/tmp/whatever.jpg',
      aiProcess: true, // 授权管线处理
      createdAt: 3,
    ));
    await repo.enqueueTask(img.id!, Repository.taskOcrAndExtract);
    await QueueConsumer(
      repo,
      ReconstructorRegistry([
        OcrReconstructor(isOcrEnabled: () => false),
        const PlaceholderReconstructor(),
      ]),
      handler,
    ).pollOnce();
    final after = await repo.byId(img.id!);
    expect(after!.humanMd, '图片附带的文字', reason: '开关关闭 → 占位行为，不触发 OCR');
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
    await QueueConsumer(repo, ReconstructorRegistry.defaultRegistry(), handler).pollOnce();

    expect(await repo.pendingTasks(), isEmpty);
    final deleted = await repo.byId(it.id!, includeDeleted: true);
    expect(deleted!.humanMd, isNull, reason: '已删条目不被管线写入');
  });

  test('管线 machine_json 校验：非法 Schema → 任务 failed、is_processed=-1（堵脏数据）', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeImage,
      sourceType: InboxItem.typeImage,
      rawFilePath: '/tmp/a.jpg',
      aiProcess: true, // 授权管线处理
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, Repository.taskOcrAndExtract);
    final registry = ReconstructorRegistry([
      fake(result: ReconstructResult(
        humanMd: '产出',
        machineJson: {'schema': '未知', 'foo': 1}, // 非法 schema
      )),
    ]);
    await QueueConsumer(repo, registry, handler).pollOnce();

    expect((await repo.byId(it.id!))!.isProcessed, -1, reason: '非法 machine_json 被拒写，任务失败');
    expect(await repo.pendingTasks(), isEmpty);
  });

  test('第 3 档门控：canProcess=false 时不认领任务，队列停留 pending 等待时机', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '待处理脏数据',
      createdAt: 1,
    ));
    await repo.enqueueTask(it.id!, null);
    final consumer = QueueConsumer(repo, ReconstructorRegistry.defaultRegistry(), handler)
      ..canProcess = () async => false; // 低电量 / 内存压力：不允许推理

    final n = await consumer.pollOnce();

    expect(n, 0);
    expect(await repo.pendingCount(), 1, reason: '门控关闭：任务不被认领，仍为 pending（留待时机续跑）');
    expect((await repo.byId(it.id!))!.humanMd, isNull, reason: '门控关闭时管线未执行，条目保持未处理');
    expect((await repo.byId(it.id!))!.isProcessed, isNot(-1), reason: '非失败：未置死信');
    });

    test('管线回写不再要「允许 AI 处理」授权（2026-10-05 拍板）：ai_process=false 也直接跑', () async {
    final it = await repo.add(InboxItem(
    itemType: InboxItem.typeNote,
    rawContent: '未授权内容',
    createdAt: 1,
    )); // 默认 ai_process=false
    await repo.enqueueTask(it.id!, null);
    await QueueConsumer(repo, ReconstructorRegistry.defaultRegistry(), handler).pollOnce();

    final after = await repo.byId(it.id!);
    expect(after!.isProcessed, isNot(-1), reason: '照常处理，不标失败');
    final task = await repo.lastTaskOf(it.id!);
    expect(task?['status'], isNot('skipped'), reason: '门禁已移除，任务不再被 skip');
    });
    }

class FakeReconstructor implements AiReconstructor {
  FakeReconstructor({
    required this.available,
    this.result,
    this.throwError = false,
    this.handlesItemTypes,
  });

  final bool available;
  final ReconstructResult? result;
  final bool throwError;
  final Set<String>? handlesItemTypes;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      handlesItemTypes == null || handlesItemTypes!.contains(input.itemType);

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    if (throwError) throw StateError('模拟推理失败');
    return result!;
  }
}