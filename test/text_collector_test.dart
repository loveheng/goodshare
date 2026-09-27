import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/tools.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/share/text_collector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 文本收集模式契约单测：分散/合并、同源+窗口判定、add_item 不参与合并（F6 决策）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  late Repository repo;
  late TextCollector collector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repo = Repository();
    collector = TextCollector(repo);
    // 清空上例残留（内存库按测试文件共享）：Vault 内外全部软删后物理清理
    for (final it in await repo.list(vault: true, includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    for (final it in await repo.list(includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    await repo.purgeDeleted(retention: Duration.zero);
    await repo.pendingTasks(limit: 1000); // 触发一次 db 就绪
    final db = await Db.instance();
    await db.delete('ai_task_queue');
  });

  test('分散模式（默认）：每次收集独立成条、不锁定、入库即入队', () async {
    final a = await collector.collectText('第一条');
    final b = await collector.collectText('第二条');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(await repo.count(), 2);
    for (final it in await repo.list()) {
      expect(it.collectMode, InboxItem.modeScatter);
      expect(it.editLocked, isFalse);
    }
    expect((await repo.pendingTasks()).length, 2);
  });

  test('合并模式：同源窗口内连续收集追加为一条（appendix 记段 + 默认锁定）', () async {
    await collector.setMode(InboxItem.modeMerge);
    final a = await collector.collectText('碎碎念第一段', sourceApp: 'wechat');
    final b = await collector.collectText('第二段紧跟着来', sourceApp: 'wechat');
    expect(b!.id, a!.id, reason: '同源窗口内应追加进同一条目');
    final merged = await repo.byId(a.id!);
    expect(merged!.collectMode, InboxItem.modeMerge);
    expect(merged.editLocked, isTrue);
    expect(merged.rawContent, contains('第一段'));
    expect(merged.rawContent, contains('第二段'));
    expect(merged.appendix.length, 2);
    expect(merged.appendix.last.source, 'wechat');
    expect((await repo.pendingTasks()).length, 2, reason: '首段与追加段各入队一次');
  });

  test('合并模式：换源不并；纯 URL 不进链、独立成条（分散语义）', () async {
    await collector.setMode(InboxItem.modeMerge);
    final a = await collector.collectText('来自微信', sourceApp: 'wechat');
    final b = await collector.collectText('来自备忘录', sourceApp: 'notes');
    expect(b!.id, isNot(a!.id));
    final url = await collector.collectText('https://x.y/z', sourceApp: 'notes');
    expect(url!.itemType, InboxItem.typeUrl);
    expect(url.collectMode, InboxItem.modeScatter, reason: 'URL 不参与合并，保持可编辑可独立处理');
    expect(url.editLocked, isFalse);
    expect(await repo.count(), 3);
  });

  test('合并模式：窗口过期后开启新链', () async {
    await collector.setMode(InboxItem.modeMerge);
    final old = DateTime.now().subtract(const Duration(minutes: 30)).millisecondsSinceEpoch;
    final stale = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceApp: 'wechat',
      rawContent: '很久以前的段',
      collectMode: InboxItem.modeMerge,
      editLocked: true,
      appendix: [AppendixEntry(ts: old, text: '很久以前的段', source: 'wechat')],
      createdAt: old,
    ));
    final fresh = await collector.collectText('新的一段', sourceApp: 'wechat');
    expect(fresh!.id, isNot(stale.id), reason: '末段超出窗口不得并入旧链');
    expect((await repo.list()).length, 2);
  });

  test('合并模式：MCP add_item 不参与合并，永远独立成条（F6）', () async {
    await collector.setMode(InboxItem.modeMerge);
    await collector.collectText('手机上的一段', sourceApp: 'wechat');
    final r1 = await callTool('add_item', {'content': 'PC 写回一'}, repo);
    final r2 = await callTool('add_item', {'content': 'PC 写回二'}, repo);
    expect(r1, isNotEmpty);
    expect(r2, isNotEmpty);
    expect(await repo.count(), 3, reason: 'add_item 两条互不合并，也不并入手机链');
  });
}
