import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
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

  // ── P2：template_apply 远程任务链路（复刻 llm_summarize 接缝）──

  test('template_apply 进入远程集合：isRemoteTaskAction 识别 + claimRemoteTask 认领 + pendingTasks 排除', () async {
    expect(Repository.isRemoteTaskAction('${Repository.taskTemplateApply}:abc'), isTrue);
    expect(Repository.isRemoteTaskAction('llm_summarize'), isTrue);
    expect(Repository.isRemoteTaskAction('ocr_and_extract'), isFalse);

    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    await repo.enqueueTask(it.id!, '${Repository.taskTemplateApply}:tpl-9');
    // 本地消费者不吃远程任务（占位守卫排除），避免双消费
    final local = await repo.pendingTasks();
    expect(
      local.any((t) => (t['task_action'] as String? ?? '').startsWith('${Repository.taskTemplateApply}:')),
      isFalse,
    );
    // 宿主可认领远程任务
    final claimed = await repo.claimRemoteTask();
    expect(claimed, isNotNull);
    expect((claimed!['task_action'] as String).startsWith('${Repository.taskTemplateApply}:'), isTrue);
  });

  test('TemplateApplyCommand：校验模板/正文后入队 template_apply 远程任务', () async {
    final wsId = await seedWorkspace();
    final tpl = await repo.createTemplate(workspaceId: wsId, name: '周报', bodyMd: '# 周报');
    final it = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '本周做了X', createdAt: 1));

    final r = await handler.execute(TemplateApplyCommand(it.id!, tpl.id), actor: CommandActor.ui);
    expect(r.op, 'apply_template');
    expect(r.jobId, isNotNull);
    final claimed = await repo.claimRemoteTask();
    expect(claimed, isNotNull);
    expect((claimed!['task_action'] as String), '${Repository.taskTemplateApply}:${tpl.id}');

    // 模板不存在 → 拒绝
    expect(
      () => handler.execute(TemplateApplyCommand(it.id!, 'no-such'), actor: CommandActor.ui),
      throwsA(isA<ActionException>()),
    );
    // 无正文条目 → 拒绝（与摘要同构，确保 AI 有可处理文本）
    final empty = await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: '', createdAt: 2));
    expect(
      () => handler.execute(TemplateApplyCommand(empty.id!, tpl.id), actor: CommandActor.ui),
      throwsA(isA<ActionException>()),
    );
  });

  test('apply_ai_result 回写 template_output：落三列 + 锚', () async {
    final it = await repo.add(InboxItem(
        itemType: InboxItem.typeNote, rawContent: '原始正文', humanMd: '原始正文', createdAt: 1));
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(humanMd: it.humanMd ?? '', templateOutput: '结构化产出内容', templateId: 'tpl-1'),
      ),
      actor: CommandActor.pipeline,
    );
    final after = await repo.byId(it.id!);
    expect(after!.templateOutput, '结构化产出内容');
    expect(after.templateId, 'tpl-1');
    expect(after.templateOutputAnchor, isNotEmpty);
  });

  // ── P2：只追加回写硬约束（ai-template.md §3：用户文本一个字不动）──

  test('只追加钉子：模板任务回写后 human_md/raw_content 逐字相等（含 AI 夹带改写）', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '原始正文',
      humanMd: '用户改过的正文',
      createdAt: 1,
    ));
    await repo.update(it.id!, {'is_processed': 0});
    // 宿主载荷里夹带一份「AI 改写的正文」——模板分支必须忽略它（只写模板三列）
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(
          humanMd: 'AI 擅自改写的内容',
          templateOutput: '模板产出',
          templateId: 'tpl-1',
        ),
        taskAction: '${Repository.taskTemplateApply}:tpl-1',
      ),
      actor: CommandActor.pipeline,
    );
    final after = (await repo.byId(it.id!))!;
    expect(after.humanMd, '用户改过的正文', reason: '只追加：human_md 零触碰');
    expect(after.rawContent, '原始正文');
    expect(after.isProcessed, 0, reason: '模板任务不翻条目处理态');
    expect(after.templateOutput, '模板产出');
  });

  test('只追加钉子：human_md 为空的条目也不会被填入 rawContent', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '只有原文',
      createdAt: 1,
    ));
    expect(it.humanMd, anyOf(isNull, isEmpty));
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(
          humanMd: '', // 通用路径本会把它当 rawEcho 失配 → 填入 rawContent
          templateOutput: '产出',
          templateId: 'tpl-1',
        ),
        taskAction: '${Repository.taskTemplateApply}:tpl-1',
      ),
      actor: CommandActor.pipeline,
    );
    final after = (await repo.byId(it.id!))!;
    expect(after.humanMd ?? '', isEmpty,
        reason: '空 human_md 保持空——不被原文回填（=改了用户文本）');
    expect(after.rawContent, '只有原文');
    expect(after.templateOutput, '产出');
  });

  test('模板任务无产出（note 收尾）：不写任何列，旧产出保留', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '正文',
      humanMd: '正文',
      createdAt: 1,
    ));
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(
          humanMd: '正文',
          templateOutput: '上一轮产出',
          templateId: 'tpl-1',
        ),
        taskAction: '${Repository.taskTemplateApply}:tpl-1',
      ),
      actor: CommandActor.pipeline,
    );
    // 第二轮宿主失败：只带 note，无 template_output
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(humanMd: '正文', note: '宿主引擎不可用'),
        taskAction: '${Repository.taskTemplateApply}:tpl-1',
      ),
      actor: CommandActor.pipeline,
    );
    final after = (await repo.byId(it.id!))!;
    expect(after.templateOutput, '上一轮产出', reason: '失败重跑不清空旧产出');
    expect(after.humanMd, '正文');
  });

  test('模板产出过打码层（身份证 GB11643 校验位样本）', () async {
    // 校验位有效的 18 位身份证（隐私打码单测同款构造口径）
    const id = '11010519491231002X';
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '正文',
      humanMd: '正文',
      createdAt: 1,
    ));
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(
          humanMd: '正文',
          templateOutput: '参会人身份证 $id 已登记',
          templateId: 'tpl-1',
        ),
        taskAction: '${Repository.taskTemplateApply}:tpl-1',
      ),
      actor: CommandActor.pipeline,
    );
    final after = (await repo.byId(it.id!))!;
    expect(after.templateOutput, isNot(contains(id)), reason: '明文身份证不得落库');
    expect(after.templateOutput, contains('1101**********002X'));
    expect(after.rawContent, '正文', reason: 'raw_content 保留明文（打码只作用于 AI 产出）');
    expect(after.humanMd, '正文');
  });

  test('模板产出版本锚：正文修改后 isTemplateOutputStale 为真', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '正文',
      humanMd: '正文',
      createdAt: 1,
    ));
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        ReconstructResult(
          humanMd: '正文',
          templateOutput: '产出',
          templateId: 'tpl-1',
        ),
        taskAction: '${Repository.taskTemplateApply}:tpl-1',
      ),
      actor: CommandActor.pipeline,
    );
    expect((await repo.byId(it.id!))!.isTemplateOutputStale, isFalse);
    await handler.execute(
      UpdateItemCommand(id: it.id!, humanMd: '改过的正文'),
      actor: CommandActor.ui,
    );
    expect((await repo.byId(it.id!))!.isTemplateOutputStale, isTrue);
  });

  // ── P2：授权断点（ai-template.md §4：人类显式触发=一次性授权；AI 发起守门）──

  test('ai_visible 门禁：MCP 发起 LLM/模板任务对人类笔记拒写，UI 显式触发放行', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '正文',
      humanMd: '正文',
      createdAt: 1,
    ));
    expect(it.aiVisible, isFalse, reason: '人类笔记默认对 AI 不可见（v20）');

    // MCP（actor=ai）发起 → forbidden + hint
    for (final cmd in <ItemCommand>[
      SummarizeCommand(it.id!),
      ExtractTagsCommand(it.id!),
    ]) {
      expect(
        () => handler.execute(cmd, actor: CommandActor.ai),
        throwsA(isA<ActionException>()
            .having((e) => e.code, 'code', ActionErrorCode.forbidden)),
      );
    }
    // 队列干净：被拒的任务不得入队
    expect(await repo.pendingTasks(), isEmpty);

    // UI（人类显式触发）= 一次性授权 → 放行入队
    final r = await handler.execute(SummarizeCommand(it.id!), actor: CommandActor.ui);
    expect(r.jobId, isNotNull);
  });

  test('ai_visible=1 的条目：MCP 发起也放行（门禁只挡不可见条目）', () async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '正文',
      humanMd: '正文',
      aiVisible: true,
      createdAt: 1,
    ));
    final r = await handler.execute(ExtractTagsCommand(it.id!), actor: CommandActor.ai);
    expect(r.jobId, isNotNull);
  });

  test('Vault 条目不可按模板处理（隐私隔离：UI 触发即被 _require 拒）', () async {
    final wsId = await seedWorkspace();
    final tpl = await repo.createTemplate(workspaceId: wsId, name: 'T', bodyMd: 'x');
    final secret = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '私密',
      isVault: true,
      createdAt: 1,
    ));
    expect(
      () => handler.execute(TemplateApplyCommand(secret.id!, tpl.id), actor: CommandActor.ui),
      throwsA(isA<ActionException>()),
    );
  });

  test('入队互斥：同条目同模板 active 任务在队即拒；换模板可入', () async {
    final wsId = await seedWorkspace();
    final tplA = await repo.createTemplate(workspaceId: wsId, name: 'A', bodyMd: 'x');
    final tplB = await repo.createTemplate(workspaceId: wsId, name: 'B', bodyMd: 'x');
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '正文',
      humanMd: '正文',
      createdAt: 1,
    ));
    await handler.execute(TemplateApplyCommand(it.id!, tplA.id), actor: CommandActor.ui);
    expect(
      () => handler.execute(TemplateApplyCommand(it.id!, tplA.id), actor: CommandActor.ui),
      throwsA(isA<ActionException>()),
      reason: '同名模板任务在队：拒重复入队（防连点烧宿主推理额度）',
    );
    // 换模板允许（用户可能想用另一个模板处理同一条）
    await handler.execute(TemplateApplyCommand(it.id!, tplB.id), actor: CommandActor.ui);
    expect((await repo.pendingTasks()).length, 0, reason: '远程任务不进本地 pending 视图');
  });
}
