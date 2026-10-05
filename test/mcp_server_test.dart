import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/mcp/mcp_server.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/share/share_intake.dart';
import 'package:goodshare/share/text_collector.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, Object?> resultOf(Map<String, Object?>? body) =>
    (body?['result'] ?? <String, Object?>{}) as Map<String, Object?>;

Map<String, Object?> errorOf(Map<String, Object?>? body) =>
    (body?['error'] ?? <String, Object?>{}) as Map<String, Object?>;

void main() {
  setUpAll(() {
    // VM 单测用 ffi 数据库工厂；内存库做 isolate 级隔离（套件并行不互踩）
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  Future<({McpServer server, HttpClient client, String base})> spinUp({String? token}) async {
    final server = McpServer(repo: Repository(), tokenProvider: () => token);
    await server.start(port: 0);
    final client = HttpClient();
    return (
      server: server,
      client: client,
      base: 'http://127.0.0.1:${server.port}',
    );
  }

  Future<({int status, Map<String, Object?>? body})> rpc(
    HttpClient client,
    String base,
    Object id,
    String method, [
    Object? params,
    Map<String, String> headers = const {},
  ]) async {
    final req = await client.postUrl(Uri.parse('$base/mcp'));
    req.headers.contentType = ContentType.json;
    headers.forEach((k, v) => req.headers.set(k, v));
    req.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params}));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return (status: res.statusCode, body: body.isEmpty ? null : jsonDecode(body) as Map<String, Object?>);
  }

  test('initialize 握手：版本回显与回退', () async {
    final env = await spinUp();
    final r = await rpc(env.client, env.base, 1, 'initialize', {'protocolVersion': '2025-03-26'});
    expect(r.status, 200);
    expect(resultOf(r.body)['protocolVersion'], '2025-03-26');
    final r2 = await rpc(env.client, env.base, 2, 'initialize', {'protocolVersion': '1999-01-01'});
    expect(resultOf(r2.body)['protocolVersion'], McpProtocol.latestVersion);
    env.client.close();
    await env.server.stop();
  });

  test('通知返回 202，GET 返回 405', () async {
    final env = await spinUp();
    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    final res = await req.close();
    expect(res.statusCode, HttpStatus.accepted);
    final get = await env.client.getUrl(Uri.parse('${env.base}/mcp'));
    final res2 = await get.close();
    expect(res2.statusCode, HttpStatus.methodNotAllowed);
    env.client.close();
    await env.server.stop();
  });

  test('坏 JSON → 400/-32700，未知方法 → -32601', () async {
    final env = await spinUp();
    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write('{oops');
    final res = await req.close();
    expect(res.statusCode, 400);
    final bad = await rpc(env.client, env.base, 3, 'no/such/method');
    expect(errorOf(bad.body)['code'], errMethodNotFound);
    env.client.close();
    await env.server.stop();
  });

  test('工具闭环：add_item → list_items → get_item', () async {
    final env = await spinUp();
    final add = await rpc(env.client, env.base, 10, 'tools/call', {
      'name': 'add_item',
      'arguments': {'content': 'https://example.com/cool', 'tags': ['测试']},
    });
    expect(errorOf(add.body), isEmpty);
    final list = await rpc(env.client, env.base, 11, 'tools/call', {
      'name': 'list_items',
      'arguments': {'query': 'cool'},
    });
    final listText = ((resultOf(list.body)['content'] as List).first) as Map;
    final payload = jsonDecode(listText['text'] as String) as Map<String, Object?>;
    final items = payload['items'] as List;
    expect(items, isNotEmpty, reason: 'list_items 应能搜到刚写入的链接');
    final id = (items.first as Map)['id'];
    final get = await rpc(env.client, env.base, 12, 'tools/call', {'name': 'get_item', 'arguments': {'id': id}});
    final text = ((resultOf(get.body)['content'] as List).first as Map)['text'] as String;
    expect(text, contains('example.com'));
    env.client.close();
    await env.server.stop();
  });

  test('块能力契约：block_transcribe_item 入队 → get_item 回 block_tasks（软引导）', () async {
    final env = await spinUp();
    const key = 'local://shares/a.m4a';
    // 种子直接经服务端 repo 写入：ai_process 是 UI 专属开关（AI 不可自行授权，§2.6）
    final it = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      humanMd: '前言\n\n[录音]($key)',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      aiEditable: true,
      aiProcess: true,
      createdAt: 1,
    ));

    final call = await rpc(env.client, env.base, 20, 'tools/call', {
      'name': 'block_transcribe_item',
      'arguments': {'id': it.id, 'block_key': key},
    });
    expect(errorOf(call.body), isEmpty);
    final queued = jsonDecode(
      ((resultOf(call.body)['content'] as List).first as Map)['text'] as String,
    ) as Map<String, Object?>;
    expect(queued['status'], 'queued');
    expect(queued['task_id'], isNotNull);

    final get = await rpc(env.client, env.base, 21, 'tools/call', {
      'name': 'get_item',
      'arguments': {'id': it.id},
    });
    final itemJson = jsonDecode(
      ((resultOf(get.body)['content'] as List).first as Map)['text'] as String,
    ) as Map<String, Object?>;
    final tasks = (itemJson['block_tasks'] as List).cast<Map<String, Object?>>();
    expect(tasks.single['action'], 'block_transcribe');
    expect(tasks.single['block_key'], key);
    expect(tasks.single['status'], 'pending');
    env.client.close();
    await env.server.stop();
  });

  test('置顶契约：set_pin on → 快照 is_pinned=true，off → false', () async {
    final env = await spinUp();
    final add = await rpc(env.client, env.base, 10, 'tools/call', {
      'name': 'add_item',
      'arguments': {'content': 'pin 契约测试条目'},
    });
    expect(errorOf(add.body), isEmpty);
    final addText = ((resultOf(add.body)['content'] as List).first as Map)['text'] as String;
    final id = (jsonDecode(addText) as Map)['item']['id'];
    final pinOn = await rpc(env.client, env.base, 11, 'tools/call', {
      'name': 'set_pin',
      'arguments': {'id': id, 'on': true},
    });
    expect(errorOf(pinOn.body), isEmpty);
    final onSnapshot = jsonDecode(
      ((resultOf(pinOn.body)['content'] as List).first as Map)['text'] as String,
    ) as Map<String, Object?>;
    expect((onSnapshot['item'] as Map)['is_pinned'], isTrue);
    final pinOff = await rpc(env.client, env.base, 12, 'tools/call', {
      'name': 'set_pin',
      'arguments': {'id': id, 'on': false},
    });
    expect(errorOf(pinOff.body), isEmpty);
    final offSnapshot = jsonDecode(
      ((resultOf(pinOff.body)['content'] as List).first as Map)['text'] as String,
    ) as Map<String, Object?>;
    expect((offSnapshot['item'] as Map)['is_pinned'], isFalse);
    env.client.close();
    await env.server.stop();
  });

  test('Origin 校验：恶意/外站 origin → 403，本机 origin 与无 origin 放行', () async {
    final env = await spinUp();
    final evil = await rpc(env.client, env.base, 1, 'ping', null, {'origin': 'http://evil.example.com'});
    expect(evil.status, HttpStatus.forbidden);
    final local = await rpc(env.client, env.base, 2, 'ping', null, {'origin': 'http://localhost:3000'});
    expect(local.status, 200);
    final none = await rpc(env.client, env.base, 3, 'ping');
    expect(none.status, 200); // 桌面客户端（stdio 桥/直连）不带 origin
    env.client.close();
    await env.server.stop();
  });

  test('token 鉴权：缺/错 401，对则放行', () async {
    final env = await spinUp(token: 's3cret');
    final noKey = await rpc(env.client, env.base, 1, 'ping');
    expect(noKey.status, 401);
    final wrongKey = await rpc(env.client, env.base, 2, 'ping', null, {'x-api-key': 'bad'});
    expect(wrongKey.status, 401);
    final ok = await rpc(env.client, env.base, 3, 'ping', null, {'x-api-key': 's3cret'});
    expect(ok.status, 200);
    expect(resultOf(ok.body), isEmpty);
    env.client.close();
    await env.server.stop();
  });

  test('文本归一：纯链接 / 标题+链接 / 纯文本', () {
    final repo = Repository();
    final handler = ItemActionHandler(repo);
    final intake = ShareIntake(handler, TextCollector(handler));
    expect(intake.parseText('https://a.b/c').type, 'url');
    final t2 = intake.parseText('一篇好文章\nhttps://a.b/c');
    expect(t2.type, 'url');
    expect(t2.title, '一篇好文章');
    expect(intake.parseText('随手记点什么').type, 'note');
  });

  test('分享分类：插件 1.9.0 文本在 path 字段（message 为 null）', () {
    // 还原插件 Android 侧真实 payload 形状：text 分享时 message=null，文本在 path
    final textShare = SharedMediaFile(path: '看看这篇 https://a.b/c', type: SharedMediaType.text);
    final urlShare = SharedMediaFile(path: 'https://x.y/z', type: SharedMediaType.url);
    final img = SharedMediaFile(path: '/tmp/a.jpg', type: SharedMediaType.image, mimeType: 'image/jpeg');
    final (texts, files) = ShareIntake.classify([textShare, urlShare, img]);
    expect(texts.length, 2, reason: '文本分享必须被收进来（回归：曾因只读 message 而丢失）');
    expect(texts.first, contains('https://a.b/c'));
    expect(files.length, 1);
  });
}
