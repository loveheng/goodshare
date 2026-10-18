import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/ai/subtitle.dart';
import 'package:goodshare/data/block_artifacts.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/mcp/tools.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 含两行媒体的便签正文（块附件通道契约种子）：`jpg` 图块 + `m4a` 音块。
const String _kNoteMd = '前言\n\n![封面](local://shares/a.jpg)\n\n[录音](local://shares/a.m4a)';

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

  // 测试种子：模拟「用户已将该笔记分享给 AI」——对 AI 可见且可编辑（ai-visibility v20）。
  // 真实口径下 MCP 仅能看到 ai_visible=1 的条目，故绝大多数 MCP 测试基于此类种子。
  InboxItem aiItem({
    String? itemType,
    String? sourceType,
    String? rawContent,
    String? collectMode,
    bool? editLocked,
    bool? isVault,
    int? createdAt,
    bool aiVisible = true,
    bool aiEditable = true,
  }) =>
      InboxItem(
        itemType: itemType ?? InboxItem.typeNote,
        sourceType: sourceType ?? InboxItem.typeNote,
        rawContent: rawContent,
        collectMode: collectMode ?? InboxItem.modeScatter,
        editLocked: editLocked ?? false,
        isVault: isVault ?? false,
        createdAt: createdAt ?? 1,
        aiVisible: aiVisible,
        aiEditable: aiEditable,
      );

  test('update_item：patch 生效；machine_json 对象自动编码并通过 Schema 校验', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '原文', createdAt: 1));
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
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('update_item', {
        'id': it.id,
        'patch': {'machine_json': {'schema': 'unknown.v1'}},
      }, repo),
      throwsA(isA<McpRpcError>()),
    );

    final locked = await repo.add(aiItem(
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
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '待删', createdAt: 1));
    await callTool('delete_item', {'id': it.id}, repo);
    expect(await repo.byId(it.id!), isNull);
    expect((await repo.listDeleted()).length, 1);

    final r = await repo.add(aiItem(itemType: InboxItem.typeUrl, rawContent: 'https://a.b/c', createdAt: 1));
    await repo.update(r.id!, {'is_processed': 1});
    await callTool('reprocess_item', {'id': r.id}, repo);
    final tasks = await repo.pendingTasks();
    expect(tasks.length, 1);
    // 2026-10-09 二次收敛：taskActionFor(url) 回归 null（串联式单任务，抓取+摘要
    // 同任务内），reprocess_item 入队 task_action=null（占位消化，摘要走 summarizeHead）
    expect(tasks.first['task_action'], isNull);
  });

  test('set_vault：MCP 可移入；移出被拒绝；移入后对 MCP 不可见', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '私密', createdAt: 1));
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
    final plain = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '无机器态', createdAt: 1));
    final invoice = await repo.add(aiItem(itemType: InboxItem.typeImage, sourceType: InboxItem.typeImage, rawContent: '发票', createdAt: 2));
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
    await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '今天的一条', createdAt: now.millisecondsSinceEpoch));
    await repo.add(aiItem(
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

  test('get_job_status / list_jobs：job_id 与条目 id 双入口；失败原因可见', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '内容', createdAt: 1));
    await repo.enqueueTask(it.id!, Repository.taskTranslate);
    final taskId = (await repo.pendingTasks()).first['task_id'] as String;
    await repo.finishTask(taskId, 'failed', note: '无可用翻译引擎');

    // job_id 入口
    final byJob = jsonDecode(textOf(await callTool('get_job_status', {'job_id': taskId}, repo))) as Map<String, Object?>;
    expect(byJob['found'], isTrue);
    expect(byJob['job_id'], taskId);
    expect(byJob['status'], 'failed');
    expect(byJob['note'], '无可用翻译引擎');

    // 条目 id 入口（最近一次任务）
    final byItem = jsonDecode(textOf(await callTool('get_job_status', {'id': it.id}, repo))) as Map<String, Object?>;
    expect(byItem['found'], isTrue);
    expect(byItem['job_id'], taskId);

    // list_jobs 总览
    final list = jsonDecode(textOf(await callTool('list_jobs', {}, repo))) as Map<String, Object?>;
    expect(list['count'], 1);
    expect(((list['jobs'] as List).first as Map)['job_id'], taskId);

    // 参数全空拒绝
    expect(() => callTool('get_job_status', {}, repo), throwsA(isA<McpRpcError>()));
  });

  test('get_job_status：Vault 条目任务不可见（隐私隔离延伸到任务查询）', () async {
    final secret = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '私密', isVault: true, createdAt: 1));
    await repo.enqueueTask(secret.id!, Repository.taskTranslate);
    final taskId = (await repo.pendingTasks()).first['task_id'] as String;

    final byItem = jsonDecode(textOf(await callTool('get_job_status', {'id': secret.id}, repo))) as Map<String, Object?>;
    expect(byItem['found'], isFalse, reason: 'Vault 条目对 MCP 物理不可见，任务查询同样不回传');

    final byJob = jsonDecode(textOf(await callTool('get_job_status', {'job_id': taskId}, repo))) as Map<String, Object?>;
    expect(byJob['found'], isFalse, reason: 'job_id 入口也必须做条目可见性门控');
  });

  test('工具清单共 43 个且不含 execute_action', () {
    final names = toolSchemas().map((s) => s['name']).toList();
    expect(names.length, 43); // M3 +ai_suggest_tags；ai-template P1 +4 模板 CRUD；instant-ai-sampling T1 +ai_summarize_now
    expect(names, isNot(contains('execute_action')));
    expect(names, containsAll([
      'update_item', 'unlock_edit', 'set_vault', 'set_pin', 'reprocess_item',
      'query_machine_data', 'get_timeline_context', 'batch_items',
      'append_segment', 'translate_item', 'summarize_item', 'extract_tags',
      'classify_item', 'scan_barcode_item', 'analyze_text_item',
      'transcribe_item', 'ocr_item', 'block_transcribe_item',
      'block_ocr_item', 'block_translate_item', 'block_summarize_item',
      'block_extract_audio_item',
      'list_workspaces', 'create_workspace', 'rename_workspace',
      'delete_workspace', 'add_to_workspace', 'remove_from_workspace',
      // 内容生产模板（ai-template P1，AI 托管）
      'list_template', 'create_template', 'update_template', 'delete_template',
      'get_job_status', 'list_jobs',
      // AI 宿主 App 接缝（ai-app-split.md §3，M1）
      'claim_ai_task', 'touch_ai_task', 'apply_ai_result',
    ]));
  });

  test('readOnlyHint 声明：每个工具显式声明，纯查询七项+sampling 只读工具 true 其余 false（§3.5）', () {
    final schemas = toolSchemas();
    const readOnlySeven = [
      'list_items', 'get_item', 'query_machine_data',
      'list_workspaces', 'list_template', 'list_jobs', 'get_job_status', 'get_timeline_context',
      // M3：ai_suggest_tags 只读+反向推理，不产生任何写路径（ai-app-split.md §3.11）
      'ai_suggest_tags',
      // instant-ai-sampling T1：ai_summarize_now 只读+反向推理，零写路径（instant-ai-sampling.md §4.1）
      'ai_summarize_now',
    ];
    for (final s in schemas) {
      final annotations = s['annotations'] as Map<String, Object?>?;
      expect(annotations, isNotNull, reason: '${s['name']} 缺 annotations 声明');
      final hint = annotations!['readOnlyHint'];
      expect(hint, isA<bool>(), reason: '${s['name']} readOnlyHint 须显式布尔');
      final expected = readOnlySeven.contains(s['name']);
      expect(hint, expected,
          reason: '${s['name']} readOnlyHint 应为 $expected（只读清单之外一律 false）');
    }
  });

  test('expected_version 乐观锁：版本过期 → version_conflict，不静默覆盖', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '原文', createdAt: 1));
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
    final chain = await repo.add(aiItem(
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
    final plain = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('append_segment', {'id': plain.id, 'text': 'y'}, repo),
      throwsA(isA<McpRpcError>()),
    );
  });

  test('工作区 MCP 工具：创建 → 加入条目 → 移除（与 UI 同动作层）', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    final created = await callTool('create_workspace', {'name': '调研'}, repo);
    expect(jsonDecode(textOf(created))['ok'], isTrue);
    final ws = (await repo.listWorkspaces()).first;
    expect(ws.name, '调研');

    await callTool('add_to_workspace', {'workspace_id': ws.id, 'id': it.id}, repo);
    expect((await repo.listWorkspaceItems(ws.id)).length, 1);

    // 重复加入幂等：不会重复落关系行
    await callTool('add_to_workspace', {'workspace_id': ws.id, 'id': it.id}, repo);
    expect((await repo.listWorkspaceItems(ws.id)).length, 1);

    await callTool('remove_from_workspace', {'workspace_id': ws.id, 'id': it.id}, repo);
    expect((await repo.listWorkspaceItems(ws.id)).length, 0);
  });

  test('写工具返回最新条目快照（AI 上下文与数据库对齐）', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '原文', createdAt: 1));
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
    final it = await repo.add(aiItem(
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
    final it = await repo.add(aiItem(
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
    final locked = await repo.add(aiItem(
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

  test('get_item 回传最近任务原因（错误可感知，人与 AI 同读一份文字）', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '内容', createdAt: 1));
    await repo.enqueueTask(it.id!, Repository.taskTranslate);
    final taskId = (await repo.pendingTasks()).first['task_id'] as String;
    await repo.finishTask(taskId, 'failed', note: '无可用翻译引擎（语言包未就绪）');
    final blocks = await callTool('get_item', {'id': it.id}, repo);
    final json = jsonDecode(textOf(blocks)) as Map<String, Object?>;
    final task = json['last_task'] as Map<String, Object?>?;
    expect(task, isNotNull, reason: '失败原因必须随条目回传，否则 AI 只能猜「为什么没译文」');
    expect(task!['status'], 'failed');
    expect(task['note'], '无可用翻译引擎（语言包未就绪）');
  });

  test('get_item 回传 R1 URL 摘要（v2-requirements §3.2：summary 字段契约）', () async {
    final it = await repo.add(aiItem(
      itemType: InboxItem.typeUrl,
      rawContent: 'https://example.com/a',
      createdAt: 1,
    ));
    // 摘要经 _applyAiResult 落库后，get_item 必须可读——桌面 AI 客户端的核心消费面
    await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        const ReconstructResult(humanMd: '正文', summaryMd: 'TL;DR：一句话摘要', tags: ['科技']),
      ),
      actor: CommandActor.pipeline,
    );
    final blocks = await callTool('get_item', {'id': it.id}, repo);
    final json = jsonDecode(textOf(blocks)) as Map<String, Object?>;
    expect(json['summary'], 'TL;DR：一句话摘要');
    expect(json['summary_stale'], isFalse, reason: '锚与正文一致（刚产出）');
    // 正文被编辑后锚失配 → 摘要标记可能过期（消费方据此决定是否重摘要）
    await handler.execute(UpdateItemCommand(id: it.id!, humanMd: '用户改过的正文'));
    final after = jsonDecode(textOf(await callTool('get_item', {'id': it.id}, repo))) as Map<String, Object?>;
    expect(after['summary_stale'], isTrue, reason: '正文已变、摘要未重产 → 失配标记');
    // 无摘要条目不占字段（载荷干净）
    final bare = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'r', createdAt: 2));
    final plain = jsonDecode(textOf(await callTool('get_item', {'id': bare.id}, repo))) as Map<String, Object?>;
    expect(plain.containsKey('summary'), isFalse);
  });

  test('scan_barcode_item / analyze_text_item：空 id 拒绝；happy path 入队', () async {
    const blank = {'id': ''};
    expect(
      () => callTool('scan_barcode_item', blank, repo),
      throwsA(isA<McpRpcError>()),
    );
    expect(
      () => callTool('analyze_text_item', blank, repo),
      throwsA(isA<McpRpcError>()),
    );

    final img = await repo.add(aiItem(itemType: InboxItem.typeImage, rawContent: '', createdAt: 1));
    final note = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '分析我', createdAt: 1));
    final rb = jsonDecode(textOf(await callTool('scan_barcode_item', {'id': img.id}, repo))) as Map<String, Object?>;
    expect(rb['ok'], isTrue);
    final ra = jsonDecode(textOf(await callTool('analyze_text_item', {'id': note.id}, repo))) as Map<String, Object?>;
    expect(ra['ok'], isTrue);

    final actions = (await repo.pendingTasks()).map((t) => t['task_action']).toSet();
    expect(actions, containsAll([Repository.taskScanBarcode, Repository.taskAnalyzeText]));
  });

  test('scan_barcode_item：类型不符拒绝；Vault 条目对 AI actor 不可见', () async {
    final note = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('scan_barcode_item', {'id': note.id}, repo),
      throwsA(isA<McpRpcError>()),
      reason: '条码扫描仅图片条目可用',
    );

    final secret = await repo.add(aiItem(itemType: InboxItem.typeImage, rawContent: '', isVault: true, createdAt: 2));
    expect(
      () => callTool('scan_barcode_item', {'id': secret.id}, repo),
      throwsA(isA<McpRpcError>()),
      reason: 'Vault 隔离对 MCP（AI actor）同样生效',
    );
  });

  test('transcribe_item：音/视频入队 transcribe_audio；非媒体拒绝', () async {
    const blank = {'id': ''};
    expect(() => callTool('transcribe_item', blank, repo), throwsA(isA<McpRpcError>()));

    final note = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('transcribe_item', {'id': note.id}, repo),
      throwsA(isA<McpRpcError>()),
      reason: '转写仅音频 / 视频条目可用（校验在动作层）',
    );

    final audio = await repo.add(aiItem(itemType: InboxItem.typeAudio, rawContent: '', createdAt: 1));
    final r = jsonDecode(textOf(await callTool('transcribe_item', {'id': audio.id}, repo))) as Map<String, Object?>;
    expect(r['ok'], isTrue);
    expect(r['job_id'], isNotNull, reason: '耗时任务必须回 job_id 供 get_job_status 轮询');
    final actions = (await repo.pendingTasks()).map((t) => t['task_action']).toSet();
    expect(actions, contains(Repository.taskTranscribeAudio));
  });

  test('transcribe_item：subtitle_mode/target_lang 编码进动作串；非法值拒绝', () async {
    final video = await repo.add(aiItem(itemType: InboxItem.typeVideo, rawContent: '', createdAt: 1));
    await callTool('transcribe_item', {'id': video.id, 'subtitle_mode': 'bilingual'}, repo);
    await callTool('transcribe_item', {'id': video.id, 'subtitle_mode': 'separate', 'target_lang': 'en'}, repo);
    final actions = (await repo.pendingTasks()).map((t) => t['task_action'] as String).toList();
    expect(actions, contains('transcribe_audio:bilingual'));
    expect(actions, contains('transcribe_audio:separate:en'));
    // 解析回读：动作串是覆盖参数的唯一载体，解析错了整条覆盖链失效
    expect(Repository.transcribeSubtitleModeOf('transcribe_audio:separate:en'), 'separate');
    expect(Repository.transcribeTargetLangOf('transcribe_audio:separate:en'), 'en');
    expect(Repository.transcribeSubtitleModeOf(Repository.taskTranscribeAudio), isNull);
    expect(Repository.transcribeTargetLangOf('transcribe_audio:bilingual'), isNull);
    expect(Repository.isTranscribeAction('transcribe_audio:separate:en'), isTrue);

    final video2 = await repo.add(aiItem(itemType: InboxItem.typeVideo, rawContent: '', createdAt: 2));
    expect(
      () => callTool('transcribe_item', {'id': video2.id, 'subtitle_mode': 'dual'}, repo),
      throwsA(isA<McpRpcError>()),
      reason: '非法字幕模式在动作层拒绝（防呆不下放）',
    );
    expect(
      () => callTool('transcribe_item', {'id': video2.id, 'target_lang': 'xx'}, repo),
      throwsA(isA<McpRpcError>()),
      reason: '非法目标语言在动作层拒绝',
    );
  });

  test('ocr_item：图片入队 ocr_and_extract；非图片拒绝', () async {
    final note = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 1));
    expect(
      () => callTool('ocr_item', {'id': note.id}, repo),
      throwsA(isA<McpRpcError>()),
      reason: 'OCR 仅图片条目可用（校验在动作层）',
    );

    final img = await repo.add(aiItem(itemType: InboxItem.typeImage, rawContent: '', createdAt: 1));
    final r = jsonDecode(textOf(await callTool('ocr_item', {'id': img.id}, repo))) as Map<String, Object?>;
    expect(r['ok'], isTrue);
    final actions = (await repo.pendingTasks()).map((t) => t['task_action']).toSet();
    expect(actions, contains(Repository.taskOcrAndExtract));
  });

  test('get_item：已转写条目内联字幕产物（SRT/VTT 与译文文件）', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final docs = await Directory.systemTemp.createTemp('goodshare_subtitles_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => docs.path,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      docs.deleteSync(recursive: true);
    });

    final it = await repo.add(aiItem(itemType: InboxItem.typeVideo, rawContent: '', createdAt: 1));
    await SubtitleStore.save(it.id!, const [
      AsrCue(start: 168.382, duration: 0.322, text: '好的好'),
    ], mode: SubtitleMode.separate, targetLang: 'zh');

    final blocks = await callTool('get_item', {'id': it.id}, repo);
    final json = jsonDecode(textOf(blocks)) as Map<String, Object?>;
    final subs = json['subtitles'] as List<Object?>?;
    expect(subs, isNotNull, reason: '字幕产物必须对 MCP 可见（asr-subtitle §10 待定项）');
    final files = subs!.cast<Map<String, Object?>>();
    expect(files.map((f) => f['ext']).toSet(), {'srt', 'vtt'});
    expect(files.map((f) => f['lang']).whereType<String>().toSet(), {'zh'});
    final srt = files.firstWhere((f) => f['ext'] == 'srt' && f['lang'] == null);
    expect(srt['content'], contains('00:02:48,382 --> 00:02:48,704'));
    expect(srt['content'], contains('好的好'));

    final noSub = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 2));
    final plain = jsonDecode(textOf(await callTool('get_item', {'id': noSub.id}, repo))) as Map<String, Object?>;
    expect(plain.containsKey('subtitles'), isFalse, reason: '无字幕条目不携带 subtitles 键');
  });

  // ---- 块附件通道 MCP 契约（block-artifact-workflow.md §7，实施 Step 8）----

  /// 含两行媒体的便签种子：`m4a` 音块 + `jpg` 图块，AI 侧「已授权处理」。
  InboxItem blockNote({bool aiProcess = true, String md = _kNoteMd}) => InboxItem(
        itemType: InboxItem.typeNote,
        sourceType: InboxItem.typeNote,
        humanMd: md,
        collectMode: InboxItem.modeScatter,
        aiVisible: true,
        aiEditable: true,
        aiProcess: aiProcess,
        createdAt: 1,
      );

  test('get_item：块产物与活跃块任务走两个兄弟字段（产物是数据、任务是进度）', () async {
    final it = await repo.add(blockNote());
    const audioKey = 'local://shares/a.m4a';
    const imgKey = 'local://shares/a.jpg';
    await repo.blockArtifacts.upsertAll(it.id!, audioKey, const [
      BlockArtifactInput(BlockArtifactKind.transcript, text: '你好世界'),
    ]);
    final jobId = await repo.enqueueTask(it.id!, Repository.blockTranscribeTaskAction(audioKey));
    // 已完成任务不进 block_tasks：该字段只回答「还在跑吗」，产出看 block_artifacts
    final stale = await repo.enqueueTask(it.id!, Repository.blockOcrTaskAction(imgKey));
    await repo.finishTask(stale, 'completed');

    final json = jsonDecode(textOf(await callTool('get_item', {'id': it.id}, repo))) as Map<String, Object?>;
    final arts = (json['block_artifacts'] as List).cast<Map<String, Object?>>();
    expect(arts.single['block_key'], audioKey);
    expect(arts.single['kind'], BlockArtifactKind.transcript);
    expect(arts.single['text_size'], 4, reason: '文本不内联，只报字符数（同字幕 256KB 帽口径）');
    expect(arts.single.containsKey('text'), isFalse);

    final tasks = (json['block_tasks'] as List).cast<Map<String, Object?>>();
    expect(tasks, hasLength(1), reason: '仅 active（pending/processing）任务入列');
    expect(tasks.single['job_id'], jobId, reason: '带 job_id 便于 AI 轮询 / 取消');
    expect(tasks.single['action'], 'block_transcribe');
    expect(tasks.single['block_key'], audioKey);
    expect(tasks.single['status'], 'pending');
    expect(tasks.single['enqueued_at'], isA<String>());

    final plain = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: 'x', createdAt: 2));
    final plainJson = jsonDecode(textOf(await callTool('get_item', {'id': plain.id}, repo))) as Map<String, Object?>;
    expect(plainJson.containsKey('block_artifacts'), isFalse, reason: '无块产物条目零痕迹');
    expect(plainJson.containsKey('block_tasks'), isFalse);
  });

  test('block_transcribe_item：入队即返 queued，互斥与 AI 门禁不放松（§7 / §2.6）', () async {
    const key = 'local://shares/a.m4a';
    final it = await repo.add(blockNote(md: '前言\n\n[录音]($key)'));

    final payload = jsonDecode(textOf(await callTool('block_transcribe_item', {
      'id': it.id,
      'block_key': key,
      'subtitle_mode': 'bilingual',
      'target_lang': 'en',
    }, repo))) as Map<String, Object?>;
    expect(payload['status'], 'queued', reason: '§7 调用即返 queued，模型据此自我抑制重复发起');
    expect(payload['task_id'], isNotNull);
    expect(payload['message'], contains('block_artifacts'), reason: '明示产出落点');
    expect((await repo.pendingTasks()).single['task_action'], 'block_transcribe:$key|bilingual|en',
        reason: '参数按 | 分段编码进动作串（local:// 含冒号，勿用冒号分段）');

    // §6.6 入队互斥（动作头 + blockKey）：连发被拒而不是刷两个长任务
    try {
      await callTool('block_transcribe_item', {'id': it.id, 'block_key': key}, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect((e.data as Map<String, Object?>)['code'], ActionErrorCode.invalidRequest);
      expect((e.data as Map<String, Object?>)['hint'], contains('不重复入队'));
    }
    expect((await repo.pendingTasks()), hasLength(1), reason: '互斥拒绝不入队，队列无重复');

    // §2.6 门禁已移除（2026-10-05 拍板）：未授权条目（ai_process=false）的块任务照常入队
    final locked = await repo.add(blockNote(md: '前言\n\n[录音]($key)', aiProcess: false));
    final unlockedTask = jsonDecode(textOf(await callTool('block_transcribe_item', {
      'id': locked.id,
      'block_key': key,
    }, repo))) as Map<String, Object?>;
    expect(unlockedTask['status'], 'queued', reason: '门禁已移除，直接入队');
    expect((await repo.pendingTasks()), hasLength(2));

    // 块类型校验仍在动作层：图片块走转写被拒（AI 换个入口也绕不过）
    final img = await repo.add(blockNote(md: '![封面](local://shares/a.jpg)'));
    expect(
      () => callTool('block_transcribe_item', {'id': img.id, 'block_key': 'local://shares/a.jpg'}, repo),
      throwsA(isA<McpRpcError>()),
    );
  });

  test('block_ocr_item / block_extract_audio_item：入队即返 queued，块类型校验不放松', () async {
    const imgKey = 'local://shares/a.jpg';
    const videoKey = 'local://shares/a.mp4';

    final img = await repo.add(blockNote(md: '![封面]($imgKey)'));
    final ocr = jsonDecode(textOf(await callTool('block_ocr_item', {
      'id': img.id,
      'block_key': imgKey,
    }, repo))) as Map<String, Object?>;
    expect(ocr['status'], 'queued');
    expect(ocr['task_id'], isNotNull);

    final video = await repo.add(blockNote(md: '[视频]($videoKey)'));
    final audio = jsonDecode(textOf(await callTool('block_extract_audio_item', {
      'id': video.id,
      'block_key': videoKey,
    }, repo))) as Map<String, Object?>;
    expect(audio['status'], 'queued');

    // 非视频块提取音轨被拒（图片块无音轨）
    expect(
      () => callTool('block_extract_audio_item', {'id': img.id, 'block_key': imgKey}, repo),
      throwsA(isA<McpRpcError>()),
    );

    final actions = (await repo.pendingTasks()).map((t) => t['task_action']).toList();
    expect(actions, contains('block_ocr:$imgKey'));
    expect(actions, contains('block_extract_audio:$videoKey'));
  });

  test('block_translate_item / block_summarize_item：缺源产物拒绝，有源才入队', () async {
    const key = 'local://shares/a.m4a';
    final it = await repo.add(blockNote(md: '前言\n\n[录音]($key)'));

    // 无 transcript/ocr_text/subtitle 产物 → 动作层拒绝（提示先转写），且不入队空耗
    try {
      await callTool('block_translate_item', {
        'id': it.id,
        'block_key': key,
        'source_kind': BlockArtifactKind.transcript,
        'target_lang': 'en',
      }, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect((e.data as Map<String, Object?>)['hint'], contains('转写'));
    }
    // 注：异步闭包用 try/catch 而非 `expect(..., throwsA(...))`——后者对 Future 型
    // 闭包的匹配结果不稳定（本文件互斥断言同风格）
    try {
      await callTool('block_summarize_item', {'id': it.id, 'block_key': key}, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError {
      expect(true, isTrue);
    }
    expect((await repo.pendingTasks()), isEmpty);

    // 有源产物 → 入队，参数按 | 分段编码
    await repo.blockArtifacts.upsertAll(it.id!, key, const [
      BlockArtifactInput(BlockArtifactKind.transcript, text: '你好世界'),
    ]);
    final tr = jsonDecode(textOf(await callTool('block_translate_item', {
      'id': it.id,
      'block_key': key,
      'source_kind': BlockArtifactKind.transcript,
      'target_lang': 'en',
    }, repo))) as Map<String, Object?>;
    expect(tr['status'], 'queued');
    final sm = jsonDecode(textOf(await callTool('block_summarize_item', {
      'id': it.id,
      'block_key': key,
    }, repo))) as Map<String, Object?>;
    expect(sm['status'], 'queued');

    final actions = (await repo.pendingTasks()).map((t) => t['task_action']).toList();
    expect(actions, contains('block_translate:$key|en|transcript'));
    // block_summarize 是远程任务（ai-app-split.md §4 占位守卫）：被本地进程
    // pendingTasks 排除，只经 claim_ai_task 认领——断言它确实在远程队列里。
    expect(actions, isNot(contains('block_summarize:$key')));
    final claimedRemote =
        jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(claimedRemote['task_action'], 'block_summarize:$key');

    // §6.6 互斥：同块同任务连发被拒（processing 也计入 active 互斥）
    expect(
      () => callTool('block_summarize_item', {'id': it.id, 'block_key': key}, repo),
      throwsA(isA<McpRpcError>()),
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // AI 宿主 App 接缝（ai-app-split.md §3，M1 实施）：claim_ai_task /
  // touch_ai_task / apply_ai_result。
  //
  // 占位守卫（M2 验收第一条）是钉子测试：远程任务必须被 pendingTasks 的
  // SQL 层排除——摘除 LlmReconstructor 换 PlaceholderReconstructor（handles
  // 恒真）后，不排除就会把远程任务「占位完成」，宿主永远 claim 不到。
  // ────────────────────────────────────────────────────────────────────

  test('占位守卫：远程任务不进 pendingTasks，且与 isRemoteTaskAction 集合一致', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    await repo.enqueueTask(it.id!, Repository.taskLlmTags);
    await repo.enqueueTask(it.id!, 'block_summarize:local://shares/a.jpg');
    // 轻量任务（非远程）照常入队
    await repo.enqueueTask(it.id!, Repository.taskTranscribeAudio);

    final pending = (await repo.pendingTasks()).map((t) => t['task_action']).toList();
    expect(pending, [Repository.taskTranscribeAudio],
        reason: '远程任务对本进程消费者不可见，队列里只该剩轻量任务');

    // 远程集合单点判定（isRemoteTaskAction）与 pendingTasks/claim 的 SQL 形态互锁
    expect(Repository.isRemoteTaskAction(Repository.taskLlmSummarize), isTrue);
    expect(Repository.isRemoteTaskAction(Repository.taskLlmTags), isTrue);
    expect(Repository.isRemoteTaskAction('block_summarize:local://shares/a.jpg'), isTrue);
    expect(Repository.isRemoteTaskAction(Repository.taskTranscribeAudio), isFalse);
    expect(Repository.isRemoteTaskAction(null), isFalse);
  });

  test('claim_ai_task：空队 idle；摘要/关键词/块摘要载荷正确；轻量任务不被认领', () async {
    // 空队列
    final r0 = jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(r0['status'], 'idle');

    // 摘要：text = 正文（humanMd 缺省回退 rawContent），带乐观锁 version
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '你好世界', createdAt: 1));
    final ev = await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    final r1 = jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(r1['status'], 'claimed');
    expect(r1['task_id'], ev);
    expect(r1['item_id'], it.id);
    expect(r1['task_action'], Repository.taskLlmSummarize);
    expect(r1['text'], '你好世界');
    expect(r1['version'], it.version);
    expect((await repo.taskById(ev))!['status'], 'processing', reason: '认领即原子转 processing');

    // 关键词：附既有标签（合并基准）
    await callTool('update_item', {'id': it.id, 'patch': {'tags': ['既有标签']}}, repo);
    final ev2 = await repo.enqueueTask(it.id!, Repository.taskLlmTags);
    final r2 = jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(r2['status'], 'claimed');
    expect(r2['task_id'], ev2);
    expect(r2['human_tags'], contains('既有标签'));

    // 块摘要：text = 块源产物文本（transcript），附 block_key
    final note = await repo.add(aiItem(
        itemType: InboxItem.typeNote, rawContent: '前言\n\n[录音](local://shares/a.m4a)', createdAt: 2));
    const bkey = 'local://shares/a.m4a';
    await repo.blockArtifacts.upsertAll(note.id!, bkey, const [
      BlockArtifactInput(BlockArtifactKind.transcript, text: '录音转写文本'),
    ]);
    final ev3 = await repo.enqueueTask(note.id!, 'block_summarize:$bkey');
    final r3 = jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(r3['status'], 'claimed');
    expect(r3['task_id'], ev3);
    expect(r3['task_action'], 'block_summarize:$bkey');
    expect(r3['block_key'], bkey);
    expect(r3['text'], '录音转写文本');

    // 轻量任务留在本进程队列，claim 拿不到（分治边界：宿主只吃大模型任务）
    await repo.enqueueTask(note.id!, Repository.taskTranscribeAudio);
    final r4 = jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(r4['status'], 'idle');
  });

  test('touch_ai_task：刷新心跳 updated_at；不存在的任务 exists=false', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    final ev = await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    await callTool('claim_ai_task', {}, repo);
    final before = (await repo.taskById(ev))!['updated_at'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await callTool('touch_ai_task', {'task_id': ev}, repo);
    final after = (await repo.taskById(ev))!['updated_at'] as int;
    expect(after, greaterThan(before), reason: '心跳必须刷新 updated_at（僵尸回收判据）');

    final r = jsonDecode(textOf(await callTool('touch_ai_task', {'task_id': 'no-such-task'}, repo)))
        as Map<String, Object?>;
    expect(r['exists'], isFalse);
  });

  test('apply_ai_result：摘要/关键词/块摘要经管线同一出口落库（actor=pipeline）', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '长文正文内容', createdAt: 1));
    await callTool('update_item', {'id': it.id, 'patch': {'tags': ['既有标签']}}, repo);

    // 摘要：落 summary_md（与原文并列，不动 human_md）
    final ev = await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    await callTool('claim_ai_task', {}, repo);
    final rr = jsonDecode(textOf(await callTool('apply_ai_result', {
      'task_id': ev,
      'id': it.id,
      'summary_md': '摘要：核心内容',
    }, repo))) as Map<String, Object?>;
    expect(rr['task_status'], 'completed');
    expect((await repo.byId(it.id!))!.summaryMd, '摘要：核心内容');
    expect((await repo.taskById(ev))!['status'], 'completed');

    // 关键词：宿主传合并后完整列表，tags 并集落库
    final ev2 = await repo.enqueueTask(it.id!, Repository.taskLlmTags);
    await callTool('claim_ai_task', {}, repo);
    await callTool('apply_ai_result', {
      'task_id': ev2,
      'id': it.id,
      'tags': ['既有标签', '新关键词'],
    }, repo);
    expect((await repo.byId(it.id!))!.tags, containsAll(['既有标签', '新关键词']));
    expect((await repo.taskById(ev2))!['status'], 'completed');

    // 块摘要：产物落 block_artifacts，条目级字段零触碰（version 不 bump）
    final note = await repo.add(aiItem(
        itemType: InboxItem.typeNote, rawContent: '前言', createdAt: 2));
    const bkey = 'local://shares/a.m4a';
    await repo.blockArtifacts.upsertAll(note.id!, bkey, const [
      BlockArtifactInput(BlockArtifactKind.transcript, text: '录音转写文本'),
    ]);
    final verBefore = (await repo.byId(note.id!))!.version;
    final ev3 = await repo.enqueueTask(note.id!, 'block_summarize:$bkey');
    await callTool('claim_ai_task', {}, repo);
    await callTool('apply_ai_result', {
      'task_id': ev3,
      'id': note.id,
      'summary_md': '块摘要：说了什么',
      'block_key': bkey,
    }, repo);
    final art = await repo.blockArtifacts.get(note.id!, bkey, BlockArtifactKind.summary);
    expect(art?.text, '块摘要：说了什么');
    final note2 = await repo.byId(note.id!);
    expect(note2!.version, verBefore, reason: '块分支零触碰条目字段，version 不 bump');
    expect(note2.isProcessed, 0, reason: '块任务不标条目处理位');

    // 无产出但有 note（完成原因必须明说，R1）：允许 completed 且原因落任务
    final ev4 = await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    await callTool('claim_ai_task', {}, repo);
    await callTool('apply_ai_result', {
      'task_id': ev4,
      'id': it.id,
      'note': '正文过短，无法生成摘要',
    }, repo);
    final t4 = await repo.taskById(ev4);
    expect(t4!['status'], 'completed');
    expect(t4['last_note'], '正文过短，无法生成摘要');
  });

  test('apply_ai_result：版本冲突拒绝回写，任务标 failed 并留原因', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    final ev = await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    final claimed = jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    final claimedVersion = claimed['version'] as int;
    // 模拟推理期间人类并发编辑：条目版本已变
    await callTool('update_item', {'id': it.id, 'patch': {'title': '人类编辑'}}, repo);
    try {
      await callTool('apply_ai_result', {
        'task_id': ev,
        'id': it.id,
        'summary_md': '基于旧版本的摘要',
        'expected_version': claimedVersion,
      }, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect((e.data as Map<String, Object?>)['code'], 'version_conflict');
    }
    final t = await repo.taskById(ev);
    expect(t!['status'], 'failed');
    expect(t['last_note'], contains('version_conflict'), reason: '错误原因必须落库（人与 AI 同读）');
    expect((await repo.byId(it.id!))!.summaryMd, isNull, reason: '被拒产出不得落库');
  });

  test('apply_ai_result：参数校验（任务不存在 / 无产出且无 note）', () async {
    final it = await repo.add(aiItem(itemType: InboxItem.typeNote, rawContent: '正文', createdAt: 1));
    final ev = await repo.enqueueTask(it.id!, Repository.taskLlmSummarize);
    try {
      await callTool('apply_ai_result', {'task_id': 'no-such', 'id': it.id, 'summary_md': 'x'}, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (_) {}
    try {
      await callTool('apply_ai_result', {'task_id': ev, 'id': it.id}, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (_) {}
    // 参数被拒不改变任务状态（未动过它）
    expect((await repo.taskById(ev))!['status'], 'pending');
  });

  // ────────────────────────────────────────────────────────────────────
  // ai-template P2（docs/design/ai-template.md）：模板任务接缝 +
  // 只追加回写 + 授权断点（人类显式触发=一次性授权；MCP 发起守 ai_visible）。
  // ────────────────────────────────────────────────────────────────────

  test('ai-template P2：claim 回 template_id + apply 只追加回写 + MCP 发起守 ai_visible', () async {
    // 人类笔记（默认 ai_visible=0）：UI 显式触发 = 一次性授权，宿主读得到
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      rawContent: '本周进展：完成了 X',
      humanMd: '本周进展：完成了 X',
      createdAt: 1,
    ));
    final ws = await repo.createWorkspace('测试工作区');
    final tpl =
        await repo.createTemplate(workspaceId: ws.id, name: '周报', bodyMd: '# 周报');

    // UI 触发入队（人类显式授权，ai-template.md §4）
    await handler.execute(TemplateApplyCommand(it.id!, tpl.id), actor: CommandActor.ui);

    // claim：模板任务显式回 template_id（宿主免解析动作串）+ text = 条目正文
    final claimed =
        jsonDecode(textOf(await callTool('claim_ai_task', {}, repo))) as Map<String, Object?>;
    expect(claimed['status'], 'claimed');
    expect(claimed['template_id'], tpl.id);
    expect(claimed['text'], '本周进展：完成了 X');
    final taskId = claimed['task_id'] as String;
    final version = claimed['version'] as int;

    // apply：只追加——template_output 落库，human_md/raw_content 零触碰
    final applied = jsonDecode(textOf(await callTool('apply_ai_result', {
      'task_id': taskId,
      'id': it.id,
      'template_output': '# 周报\n本周完成 X',
      'template_id': tpl.id,
      'expected_version': version,
    }, repo))) as Map<String, Object?>;
    expect(applied['task_status'], 'completed');
    final after = (await repo.byId(it.id!))!;
    expect(after.templateOutput, '# 周报\n本周完成 X');
    expect(after.humanMd, '本周进展：完成了 X', reason: '只追加：human_md 零触碰');
    expect(after.rawContent, '本周进展：完成了 X');

    // MCP 发起对不可见条目拒写（v20 读门禁下沉入队口）：summarize_item 被拒
    expect(
      () => callTool('summarize_item', {'id': it.id}, repo),
      throwsA(isA<McpRpcError>()),
      reason: '人类笔记默认对 AI 不可见；AI 发起入队即被门禁拦下',
    );
  });
}
