import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/ai_tags_guard.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/mcp/tools.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// AI 回写标签领域护栏：数据 owner 侧的唯一写入口 + MCP / 管线失败可观测。
///
/// goodhub 是通用能力层、不为单个服务写适配；模型产出整段 markdown 时由本仓
/// 动作层拒绝，任务 failed + last_note 说明原因（R1/R3），条目零污染。
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

  InboxItem aiItem(String raw, {List<String> tags = const []}) => InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: raw,
        tags: tags,
        aiVisible: true,
        aiEditable: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  // 真机复现的坏样本：整段 markdown 被通用分隔符切碎后的「标签」。
  const badTags = <String>[
    '人工标签',
    '**核心架构与能力**',
    '*   **来源渠道**：微信（朋友圈',
    '拾贝 Android 应用处理结果摘要：',
    '推理结果通过 MCP (Model Context Protocol) 标准接口回写至条目',
    '智能标签化与字幕化内容。其 AI 推理引擎由宿主应用内置插件管理',
    '聊天）',
    '浏览器（网页链接）。',
    '生成摘要',
    '图片内容',
    '链接',
    '**当前处理周期**：自动化任务启动',
    '人脑与 AI 共同处理同一状态内容。',
    'MCP',
  ];

  group('invalidAiTags（纯函数）', () {
    test('合规短关键词 + 原有标签不受约束 → 无问题', () {
      expect(
        invalidAiTags(
          const ['人工标签', '用户自己写的长标题也不该被 AI 校验拦下'],
          const ['人工标签', '分享收集器', 'MCP', '本地 AI'],
        ),
        isEmpty,
      );
    });

    test('整段 markdown 碎片 → 数量、超长、结构标记同时被抓', () {
      final problems = invalidAiTags(const ['人工标签'], badTags);
      expect(problems.length, greaterThanOrEqualTo(3));
      expect(problems.join('；'), contains('疑似整段文本被切碎'));
      expect(problems.join('；'), contains('markdown/句子标记'));
      expect(problems.join('；'), contains('超过 $kMaxAiTagLength 字'));
    });

    test('单个超长 / 空 / 空白碎片各自被抓', () {
      expect(invalidAiTags(const [], const ['这是一段远远超过二十四字符上限的长句子当作标签使用']).join(),
          contains('超过'));
      expect(invalidAiTags(const [], const ['   ']).join(), contains('空标签'));
      expect(invalidAiTags(const [], const ['微信  朋友圈  浏览器  剪藏']).join(),
          contains('句子碎片'));
    });

    test('数量恰好到上限不报数量问题', () {
      final tags = List<String>.generate(kMaxAiTagsPerResult, (i) => '标签$i');
      expect(invalidAiTags(const [], tags), isEmpty);
    });
  });

  test('动作层：不合规标签整批拒绝，条目零变更', () async {
    final it = await repo.add(aiItem('正文', tags: const ['人工标签']));
    final before = (await repo.byId(it.id!))!;

    await expectLater(
      handler.execute(
        ApplyAiResultCommand(
          it.id!,
          ReconstructResult(humanMd: '正文', tags: badTags),
        ),
        actor: CommandActor.pipeline,
      ),
      throwsA(
        isA<ActionException>()
            .having((e) => e.code, 'code', ActionErrorCode.schemaInvalid)
            .having((e) => e.message, 'message', contains('标签形态不合规'))
            .having((e) => e.hint, 'hint', contains('重跑')),
      ),
    );

    final after = (await repo.byId(it.id!))!;
    expect(after.tags, before.tags, reason: '碎片标签不得落库');
    expect(after.version, before.version);
    expect(after.humanMd, before.humanMd);
    expect(after.isProcessed, before.isProcessed);
  });

  test('动作层：合规标签并集落库（D2 只增不删）', () async {
    final it = await repo.add(aiItem('正文', tags: const ['人工标签']));
    final before = (await repo.byId(it.id!))!;

    final r = await handler.execute(
      ApplyAiResultCommand(
        it.id!,
        const ReconstructResult(
            humanMd: 'AI 整理后的正文',
            tags: ['人工标签', '分享收集器', 'MCP']),
      ),
      actor: CommandActor.pipeline,
    );
    expect(r.op, 'apply_ai_result');

    final after = (await repo.byId(it.id!))!;
    expect(after.tags, containsAll(<String>['人工标签', '分享收集器', 'MCP']));
    expect(after.version, greaterThan(before.version));
    expect(after.isProcessed, 1);
  });

  test('MCP apply_ai_result：不合规产出 → failed + note 可观测 + 条目零污染', () async {
    final it = await repo.add(aiItem('正文', tags: const ['人工标签']));
    final before = (await repo.byId(it.id!))!;
    final taskId = await repo.enqueueTask(it.id!, Repository.taskLlmTags);
    await callTool('claim_ai_task', const <String, Object?>{}, repo);

    try {
      await callTool('apply_ai_result', <String, Object?>{
        'task_id': taskId,
        'id': it.id,
        'tags': badTags,
      }, repo);
      fail('应抛 McpRpcError');
    } on McpRpcError catch (e) {
      expect((e.data as Map<String, Object?>)['code'],
          ActionErrorCode.schemaInvalid);
      expect(e.message, contains('标签形态不合规'));
    }

    final task = await repo.taskById(taskId);
    expect(task!['status'], 'failed');
    expect(task['last_note'], contains('标签形态不合规'),
        reason: '具体原因必须落库，人与 AI 同读（R1）');
    expect(task['last_note'], contains(ActionErrorCode.schemaInvalid));

    final after = (await repo.byId(it.id!))!;
    expect(after.tags, before.tags);
    expect(after.version, before.version);
    expect(after.humanMd, before.humanMd);
  });

  test('MCP apply_ai_result：合规产出仍 completed（既有路径不回归）', () async {
    final it = await repo.add(aiItem('正文', tags: const ['人工标签']));
    final taskId = await repo.enqueueTask(it.id!, Repository.taskLlmTags);
    await callTool('claim_ai_task', const <String, Object?>{}, repo);

    final blocks = await callTool('apply_ai_result', <String, Object?>{
      'task_id': taskId,
      'id': it.id,
      'tags': const ['人工标签', '新关键词'],
    }, repo);
    final rr = jsonDecode(blocks.first['text']! as String) as Map<String, Object?>;
    expect(rr['task_status'], 'completed');
    expect((await repo.byId(it.id!))!.tags,
        containsAll(<String>['人工标签', '新关键词']));
    expect((await repo.taskById(taskId))!['status'], 'completed');
  });
}
