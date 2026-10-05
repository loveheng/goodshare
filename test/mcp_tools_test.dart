import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
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
    expect(tasks.first['task_action'], Repository.taskSummarizeUrl);
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

  test('工具清单共 34 个且不含 execute_action', () {
    final names = toolSchemas().map((s) => s['name']).toList();
    expect(names.length, 34);
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
      'get_job_status', 'list_jobs',
    ]));
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

    // §2.6 门禁：AI 主体不豁免「允许 AI 处理」——未授权条目入队前即拒（零空耗）
    final locked = await repo.add(blockNote(md: '前言\n\n[录音]($key)', aiProcess: false));
    try {
      await callTool('block_transcribe_item', {'id': locked.id, 'block_key': key}, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect((e.data as Map<String, Object?>)['code'], ActionErrorCode.forbidden);
    }
    expect((await repo.pendingTasks()), hasLength(1), reason: '未授权任务根本不进队列');

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
    expect(actions, contains('block_summarize:$key'));

    // §6.6 互斥：同块同任务连发被拒
    expect(
      () => callTool('block_summarize_item', {'id': it.id, 'block_key': key}, repo),
      throwsA(isA<McpRpcError>()),
    );
  });
}
