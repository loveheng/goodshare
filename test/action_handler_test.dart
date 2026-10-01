import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 共用动作层契约单测（PRD §7 / D4·F7 决策 + Human-AI 对称性 4 项增强）。
/// UI 与 MCP 的写路径都经此层，差异只在 actor——故越权用例在此断言。
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

  // ───────── §1 命令模式：UI 与 AI 同一入参 ─────────

  test('命令 JSON 往返：toJson → fromJson 与 UI 组装的等价', () async {
    final it = await repo.add(newItem());
    const uiBuilt = UpdateItemCommand(id: 'x', title: 't', tags: ['a', 'b'], humanMd: '# m');
    final fromAi = ItemCommand.fromJson(uiBuilt.toJson());
    expect(fromAi, isA<UpdateItemCommand>());
    final c = fromAi as UpdateItemCommand;
    expect(c.id, uiBuilt.id);
    expect(c.tags, uiBuilt.tags);

    // AI 侧从 JSON 组装的命令，落到同一条目上与 UI 组装的效果一致
    final r = await handler.execute(
      ItemCommand.fromJson({'op': 'update', 'id': it.id, 'title': '来自 AI'}),
      actor: CommandActor.ai,
    );
    expect(r.item!.humanTitle, '来自 AI');
  });

  test('update 写回标题/标签/人类态，并返回最新快照', () async {
    final it = await repo.add(newItem());
    final r = await handler.execute(
      UpdateItemCommand(id: it.id!, title: '新标题', tags: ['x'], humanMd: '# md'),
    );
    expect(r.op, 'update');
    expect(r.item!.humanTitle, '新标题');
    expect(r.item!.tags, ['x']);
    expect(r.item!.humanMd, '# md');
  });

  test('合并锁定条目拒绝编辑，解锁后方可写', () async {
    final it = await repo.add(newItem(locked: true));
    expect(
      () => handler.execute(UpdateItemCommand(id: it.id!, title: '偷改')),
      throwsA(isA<ActionException>()),
    );
    await handler.execute(UnlockEditCommand(it.id!));
    final after = await handler.execute(UpdateItemCommand(id: it.id!, title: '解锁后改'));
    expect(after.item!.humanTitle, '解锁后改');
    expect(after.item!.editLocked, isFalse);
  });

  test('machine_json 强校验：非法 JSON / 未知 schema / 缺必填字段 / 合法 invoice.v1', () async {
    final it = await repo.add(newItem());
    expect(
      () => handler.execute(UpdateItemCommand(id: it.id!, machineJson: '{oops')),
      throwsA(isA<ActionException>()),
    );
    expect(
      () => handler.execute(UpdateItemCommand(id: it.id!, machineJson: '{"schema":"nope.v9"}')),
      throwsA(isA<ActionException>()),
    );
    expect(
      () => handler.execute(UpdateItemCommand(id: it.id!, machineJson: '{"schema":"invoice.v1","amount":1}')),
      throwsA(isA<ActionException>()),
    );
    const ok = '{"schema":"invoice.v1","amount":12.5,"date":"2026-09-27","merchant":"店家"}';
    final after = await handler.execute(UpdateItemCommand(id: it.id!, machineJson: ok));
    expect(after.item!.machineJson, ok);
  });

  test('重分类白名单：仅 source_type=image 可 image→chatlog/document', () async {
    final shot = await repo.add(newItem(type: InboxItem.typeImage, sourceType: InboxItem.typeImage));
    final moved = await handler.execute(ReclassifyCommand(shot.id!, InboxItem.typeChatlog));
    expect(moved.item!.itemType, InboxItem.typeChatlog);

    final note = await repo.add(newItem());
    expect(
      () => handler.execute(ReclassifyCommand(note.id!, InboxItem.typeChatlog)),
      throwsA(isA<ActionException>()),
    );

    final img2 = await repo.add(newItem(type: InboxItem.typeImage, sourceType: InboxItem.typeImage));
    expect(
      () => handler.execute(ReclassifyCommand(img2.id!, InboxItem.typeUrl)),
      throwsA(isA<ActionException>()),
    );
    // update 的 item_type 路径走同一校验
    expect(
      () => handler.execute(UpdateItemCommand(id: img2.id!, itemType: InboxItem.typeChatlog)),
      returnsNormally,
    );
  });

  test('setVault 进出保险箱；非 vaultContext 动作对 Vault 条目不可见', () async {
    final it = await repo.add(newItem());
    await handler.execute(SetVaultCommand(it.id!, true));
    expect((await repo.list()), isEmpty, reason: 'Vault 条目对默认查询不可见');
    expect((await repo.list(vault: true)).length, 1);
    // MCP 口径（actor=ai）看不到 Vault 条目
    expect(
      () => handler.execute(DeleteItemCommand(it.id!), actor: CommandActor.ai),
      throwsA(isA<ActionException>()),
    );
    // UI 保险箱页口径（vaultContext=true）可操作
    await handler.execute(DeleteItemCommand(it.id!), vaultContext: true);
    expect((await repo.list(vault: true, includeDeleted: true)).first.isDeleted, isTrue);
  });

  test('reprocess 重置处理态并入队；note 类型用 null action 走通用重构', () async {
    final it = await repo.add(newItem());
    await repo.update(it.id!, {'is_processed': 1});
    await handler.execute(ReprocessCommand(it.id!));
    final after = await repo.byId(it.id!);
    expect(after?.isProcessed, 0);
    final tasks = await repo.pendingTasks();
    expect(tasks.length, 1);
    expect(tasks.first['item_id'], it.id);
    expect(tasks.first['task_action'], isNull, reason: 'note 无专属 task_action，由消费者按类型通用重构');
  });

  test('delete 软删除并入最近删除', () async {
    final it = await repo.add(newItem());
    await handler.execute(DeleteItemCommand(it.id!));
    expect(await repo.byId(it.id!), isNull);
    expect((await repo.listDeleted()).length, 1);
  });

  // ───────── §2 防呆下沉：越权在动作层拦截，不在传输层 ─────────

  test('AI 越权拦截：移出保险箱 / 彻底删除 / 管线回写 均被拒', () async {
    final it = await repo.add(newItem());

    // 移出保险箱：原规则写在 MCP 层，现已下沉——换个入口也绕不过
    expect(
      () => handler.execute(SetVaultCommand(it.id!, false), actor: CommandActor.ai),
      throwsA(isA<ActionException>()),
      reason: 'AI 不得自行解除 Vault 隔离',
    );
    // 彻底删除：不可逆，仅 UI
    expect(
      () => handler.execute(DeleteForeverCommand(it.id!), actor: CommandActor.ai),
      throwsA(isA<ActionException>()),
    );
    // 管线特权入口：AI 不得借它绕过 edit_locked
    expect(
      () => handler.execute(
        ApplyAiResultCommand(it.id!, const ReconstructResult(humanMd: 'x')),
        actor: CommandActor.ai,
      ),
      throwsA(isA<ActionException>()),
    );
    // UI 与管线各自放行
    expect(() => handler.execute(DeleteForeverCommand(it.id!)), returnsNormally);
  });

  test('collect 防呆：正文与附件皆空 / 未知类型 被拒', () async {
    expect(
      () => handler.execute(const CollectCommand(itemType: InboxItem.typeNote)),
      throwsA(isA<ActionException>()),
    );
    expect(
      () => handler.execute(const CollectCommand(itemType: 'nope', rawContent: 'x')),
      throwsA(isA<ActionException>()),
    );
    final r = await handler.execute(
      const CollectCommand(itemType: InboxItem.typeNote, sourceApp: '测试', rawContent: '内容'),
    );
    expect(r.item!.rawContent, '内容');
    expect((await repo.pendingTasks()).length, 1, reason: '入库即入队');
  });

  test('Vault 隐私：AI 把条目移入保险箱后，返回值不再含条目内容', () async {
    final it = await repo.add(newItem());
    final r = await handler.execute(SetVaultCommand(it.id!, true), actor: CommandActor.ai);
    expect(r.item, isNull, reason: '移出可见域后不回传内容');
    expect(r.note, contains('已移入'));

    // UI 保险箱页口径可移出，且能拿到快照
    final out = await handler.execute(SetVaultCommand(it.id!, false), vaultContext: true);
    expect(out.item!.isVault, isFalse);
  });

  test('锁定条目被拒时带机器可读 code + hint（供 AI 自我纠正）', () async {
    final it = await repo.add(newItem(locked: true));
    try {
      await handler.execute(UpdateItemCommand(id: it.id!, title: 'x'));
      fail('应抛 ActionException');
    } on ActionException catch (e) {
      expect(e.code, ActionErrorCode.editLocked);
      expect(e.hint, contains('unlock_edit'));
    }
  });

  // ───────── §4 原子性：批量全成功或全回滚 ─────────

  test('批量原子性：中途失败整批回滚，不留半成品脏数据', () async {
    final it = await repo.add(newItem(locked: true));
    expect(
      () => handler.executeAll([
        UnlockEditCommand(it.id!),
        UpdateItemCommand(id: it.id!, title: '改了标题'),
        UpdateItemCommand(id: it.id!, machineJson: '{非法'),
      ]),
      throwsA(isA<ActionException>()),
    );
    final after = await repo.byId(it.id!, includeVault: true);
    expect(after!.editLocked, isTrue, reason: '解锁已被回滚');
    expect(after.humanTitle, isNull, reason: '标题改动已被回滚');
  });

  test('批量成功：解锁 + 改字 + 打标签 一次提交，返回每条结果与最终快照', () async {
    final it = await repo.add(newItem(locked: true));
    final results = await handler.executeAll([
      UnlockEditCommand(it.id!),
      UpdateItemCommand(id: it.id!, title: '复合标题', tags: ['a', 'b']),
    ]);
    expect(results.length, 2);
    expect(results.first.op, 'unlock_edit');
    final last = results.last;
    expect(last.item!.humanTitle, '复合标题');
    expect(last.item!.tags, ['a', 'b']);
    expect(last.item!.editLocked, isFalse);

    final fresh = await repo.byId(it.id!);
    expect(fresh!.humanTitle, '复合标题');
    expect(fresh.tags, ['a', 'b']);
    expect(fresh.editLocked, isFalse);
  });

  test('collect 合并模式：建链即锁定，首段记入 appendix', () async {
    final r = await handler.execute(
      const CollectCommand(
        itemType: InboxItem.typeNote,
        sourceApp: 'test',
        rawContent: '第一段',
        collectMode: InboxItem.modeMerge,
      ),
    );
    expect(r.item!.collectMode, InboxItem.modeMerge);
    expect(r.item!.editLocked, isTrue);
    expect(r.item!.appendix.single.text, '第一段');
  });

  test('append_segment：合并链可追加（edit_locked=1 仍允许，追加≠改写）', () async {
    final chain = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '首段',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final r = await handler.execute(
      AppendSegmentCommand(chain.id!, '第二段', sourceApp: 'test'),
    );
    expect(r.item!.rawContent, contains('第二段'));
    expect(r.item!.editLocked, isTrue, reason: '追加是链的生长，不改变锁定态');
    expect(r.item!.appendix.length, 1);
    // AI 主体同样可用（Human-AI 对称：人类连续速记能做的事 AI 也能）
    final byAi = await handler.execute(
      AppendSegmentCommand(chain.id!, 'AI 段', sourceApp: 'MCP (AI 写入)'),
      actor: CommandActor.ai,
    );
    expect(byAi.item!.rawContent, contains('AI 段'));
  });

  test('append_segment 防呆：散列条目 / 超窗口 / 空文本 均被拒', () async {
    final plain = await repo.add(newItem());
    expect(
      () => handler.execute(AppendSegmentCommand(plain.id!, 'x')),
      throwsA(isA<ActionException>()),
      reason: '非合并模式条目不得追加',
    );

    final old = DateTime.now().subtract(const Duration(minutes: 30)).millisecondsSinceEpoch;
    final stale = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '旧段',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      appendix: [AppendixEntry(ts: old, text: '旧段', source: 'wechat')],
      createdAt: old,
    ));
    expect(
      () => handler.execute(AppendSegmentCommand(stale.id!, '新段')),
      throwsA(isA<ActionException>()),
      reason: '末段超出合并窗口不得追加',
    );

    final fresh = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: 'f',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(
      () => handler.execute(AppendSegmentCommand(fresh.id!, '   ')),
      throwsA(isA<ActionException>()),
    );
  });

  // ───────── §5 乐观锁 + 串行化：抹平「人类串行慢操作」与「AI 并发狂轰」的差异 ─────────

  test('乐观锁：version 随每次写入递增，带正确版本可写', () async {
    final it = await repo.add(newItem());
    expect(it.version, 0);
    final r1 = await handler.execute(
      UpdateItemCommand(id: it.id!, title: 'A', expectedVersion: 0),
    );
    expect(r1.item!.version, 1);
    final r2 = await handler.execute(
      UpdateItemCommand(id: it.id!, title: 'B', expectedVersion: 1),
    );
    expect(r2.item!.version, 2);
    expect(r2.item!.humanTitle, 'B');
  });

  test('乐观锁：过期版本写入被拒，AI 的改动不被人类静默覆盖', () async {
    final it = await repo.add(newItem());
    await handler.execute(UpdateItemCommand(id: it.id!, title: 'AI 先改的'));
    // 人类拿着进入编辑器时的旧 version 保存 → 必须被拒
    try {
      await handler.execute(
        UpdateItemCommand(id: it.id!, title: '人类慢速保存', expectedVersion: 0),
      );
      fail('应抛 ActionException');
    } on ActionException catch (e) {
      expect(e.code, ActionErrorCode.versionConflict);
      expect(e.hint, contains('expected_version'));
    }
    expect((await repo.byId(it.id!))!.humanTitle, 'AI 先改的', reason: 'AI 的改动未被静默覆盖');
  });

  test('乐观锁：不带 expectedVersion 不校验（既有调用零改动，渐进接入）', () async {
    final it = await repo.add(newItem());
    await handler.execute(UpdateItemCommand(id: it.id!, title: 'A'));
    final r = await handler.execute(UpdateItemCommand(id: it.id!, title: 'B'));
    expect(r.item!.humanTitle, 'B');
    expect(r.item!.version, 2);
  });

  test('乐观锁：删除同样受 CAS 保护（防「AI 改了内容、人却删掉旧版本」）', () async {
    final it = await repo.add(newItem());
    await handler.execute(UpdateItemCommand(id: it.id!, title: 'x'));
    expect(
      () => handler.execute(DeleteItemCommand(it.id!, expectedVersion: 0)),
      throwsA(isA<ActionException>()),
    );
    expect(await repo.byId(it.id!), isNotNull);
  });

  test('写路径串行化：并发追加不丢更新（消除 TOCTOU 后写覆盖先写）', () async {
    final chain = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '首段',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    // 模拟大模型极短时间内甩来的并发请求
    await Future.wait([
      handler.execute(AppendSegmentCommand(chain.id!, '并发段 A')),
      handler.execute(AppendSegmentCommand(chain.id!, '并发段 B')),
    ]);
    final after = await repo.byId(chain.id!, includeVault: true);
    expect(after!.appendix.length, 2, reason: '两段都应记入 appendix，不应后写覆盖先写');
    expect(after.rawContent, contains('并发段 A'));
    expect(after.rawContent, contains('并发段 B'));
  });

  test('批量拒绝不可逆命令（delete_forever 的文件删除不随事务回滚）', () async {
    final it = await repo.add(newItem());
    expect(
      () => handler.executeAll([DeleteItemCommand(it.id!), DeleteForeverCommand(it.id!)]),
      throwsA(isA<ActionException>()),
    );
    expect(await repo.byId(it.id!), isNotNull, reason: '整批未执行');
  });

  test('AI 防冲刷护城河：apply_ai_result 丢失行内媒体块 → human_md 保留原文', () async {
    final md = '前文\n\n![拍照](local://shares/a.jpg)\n\n[录音](local://shares/a.m4a)';
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '前文',
      humanMd: md,
      createdAt: 1,
    ));
    // AI 润色产出把媒体块删了 → human_md 必须保留原文，原因进 note 可感知
    final r = await handler.execute(
      ApplyAiResultCommand(it.id!, const ReconstructResult(humanMd: 'AI 润色后的纯文本')),
      actor: CommandActor.pipeline,
    );
    expect((await repo.byId(it.id!))!.humanMd, md, reason: '用户媒体资产不被 AI 整替冲刷');
    expect(r.note, contains('媒体块'));

    // 媒体全保留（即使文字被改写）→ 放行
    const kept = '重写后的前文\n\n![拍照](local://shares/a.jpg)\n\n[录音](local://shares/a.m4a)';
    await handler.execute(
      ApplyAiResultCommand(it.id!, const ReconstructResult(humanMd: kept)),
      actor: CommandActor.pipeline,
    );
    expect((await repo.byId(it.id!))!.humanMd, kept);

    // 原文无媒体块 → AI 正常整替
    final it2 = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '纯文本',
      humanMd: '原文',
      createdAt: 2,
    ));
    await handler.execute(
      ApplyAiResultCommand(it2.id!, const ReconstructResult(humanMd: 'AI 版')),
      actor: CommandActor.pipeline,
    );
    expect((await repo.byId(it2.id!))!.humanMd, 'AI 版');
  });
}
