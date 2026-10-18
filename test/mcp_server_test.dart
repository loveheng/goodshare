import 'dart:async';
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

  /// M3：裸 JSON-RPC 帧 POST（响应回程用——response 帧无 method，rpc() 不适用）。
  Future<({int status, Map<String, Object?>? body})> rawPost(
    HttpClient client,
    String base,
    Map<String, Object?> frame,
  ) async {
    final req = await client.postUrl(Uri.parse('$base/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(frame));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return (status: res.statusCode, body: body.isEmpty ? null : jsonDecode(body) as Map<String, Object?>);
  }

  /// M3：打开 GET /mcp SSE 下行长连接，返回响应与逐行迭代器。
  Future<(HttpClientResponse, StreamIterator<String>)> openSse(
    HttpClient client,
    String base, [
    Map<String, String> headers = const {},
  ]) async {
    final req = await client.getUrl(Uri.parse('$base/mcp'));
    headers.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close();
    final it = StreamIterator(
        res.transform(utf8.decoder).transform(const LineSplitter()));
    return (res, it);
  }

  /// 读下一个 SSE data 帧（`: keep-alive` 心跳与空行自动跳过）；超时抛 TimeoutException。
  Future<Map<String, Object?>?> nextFrame(
    StreamIterator<String> it, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final buf = StringBuffer();
    while (true) {
      final has = await it.moveNext().timeout(timeout);
      if (!has) return null;
      final line = it.current;
      if (line.startsWith('data:')) {
        buf..write(line.substring(5).trim())..write('\n');
        continue;
      }
      if (buf.isNotEmpty && line.isEmpty) {
        return jsonDecode(buf.toString().trim()) as Map<String, Object?>;
      }
    }
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

  test('通知返回 202；GET 开 SSE 下行通道；DELETE 405', () async {
    final env = await spinUp();
    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    final res = await req.close();
    expect(res.statusCode, HttpStatus.accepted);
    final (sse, it) = await openSse(env.client, env.base);
    expect(sse.statusCode, HttpStatus.ok);
    expect(sse.headers.contentType?.mimeType, 'text/event-stream');
    final del = await env.client.deleteUrl(Uri.parse('${env.base}/mcp'));
    final delRes = await del.close();
    expect(delRes.statusCode, HttpStatus.methodNotAllowed);
    it.cancel();
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

  test('M2.5/M3 接缝：initialize capabilities 声明 prompts + resources + sampling + subscribe', () async {
    final env = await spinUp();
    final r = await rpc(env.client, env.base, 1, 'initialize', {'protocolVersion': '2025-06-18'});
    final caps = resultOf(r.body)['capabilities'] as Map;
    expect(caps.containsKey('prompts'), isTrue, reason: 'Tier 1 声明 prompts（ai-app-split.md §3.6）');
    expect(caps.containsKey('resources'), isTrue, reason: 'Tier 1 声明 resources');
    expect((caps['resources'] as Map)['subscribe'], isTrue, reason: 'M3 声明订阅（§3.10）');
    expect(caps.containsKey('sampling'), isTrue, reason: 'M3 声明 sampling 反向推理（§3.11）');
    env.client.close();
    await env.server.stop();
  });

  test('prompts：list 带 CoW 版本元数据，get 渲染占位符，缺参/未知 -32602', () async {
    final env = await spinUp();
    final list = await rpc(env.client, env.base, 1, 'prompts/list');
    final prompts = (resultOf(list.body)['prompts'] as List).cast<Map>();
    expect(prompts.map((p) => p['name']), contains('item_digest'));
    expect(prompts.first['_meta']['template_version'], isNotNull);
    expect(prompts.first['_meta']['min_hub_version'], isNotNull);

    final get = await rpc(env.client, env.base, 2, 'prompts/get', {
      'name': 'item_digest',
      'arguments': {'id': 'abc-123'},
    });
    final messages = (resultOf(get.body)['messages'] as List).cast<Map>();
    final text = (messages.first['content'] as Map)['text'] as String;
    expect(text, contains('abc-123'));
    expect(text.contains('{id}'), isFalse, reason: '占位符必须被替换');

    final missing = await rpc(env.client, env.base, 3, 'prompts/get',
        {'name': 'item_digest', 'arguments': {}});
    expect(errorOf(missing.body)['code'], errInvalidParams);
    final unknown = await rpc(env.client, env.base, 4, 'prompts/get', {'name': 'nope'});
    expect(errorOf(unknown.body)['code'], errInvalidParams);

    // M2.5-T6 CoW 原文通道：arguments 整体缺省 → 未渲染原文（占位符保留）
    final raw = await rpc(env.client, env.base, 5, 'prompts/get', {'name': 'item_digest'});
    final rawText = (((resultOf(raw.body)['messages'] as List).first as Map)['content'] as Map)['text'] as String;
    expect(rawText, contains('{id}'), reason: '无参渲染原文，占位符保留（CoW 同步用）');
    env.client.close();
    await env.server.stop();
  });

  test('resources：list 暴露 ai_visible 条目，read 返回正文；不可见/未知/非法 URI 拒绝', () async {
    final env = await spinUp();
    final visible = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: 'resources 契约测试正文',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: 'AI 不可见条目',
      collectMode: InboxItem.modeScatter,
      aiVisible: false,
      createdAt: 2,
    ));

    final list = await rpc(env.client, env.base, 1, 'resources/list');
    final resources = (resultOf(list.body)['resources'] as List).cast<Map>();
    final uris = resources.map((r) => r['uri'] as String).toList();
    expect(uris, contains('goodshare://items/${visible.id}'));
    expect(uris.where((u) => u.contains('不可见')), isEmpty);

    final read = await rpc(env.client, env.base, 2, 'resources/read', {
      'uri': 'goodshare://items/${visible.id}',
    });
    final contents = (resultOf(read.body)['contents'] as List).cast<Map>();
    expect(contents.first['mimeType'], 'text/plain');
    expect(contents.first['text'], contains('resources 契约测试正文'));

    final badScheme = await rpc(env.client, env.base, 3, 'resources/read', {'uri': 'other://x'});
    expect(errorOf(badScheme.body)['code'], errInvalidParams);
    final notFound = await rpc(env.client, env.base, 4, 'resources/read', {'uri': 'goodshare://items/nope'});
    expect(errorOf(notFound.body)['code'], errInvalidParams);
    env.client.close();
    await env.server.stop();
  });

  test('SSE 帧流：带 progressToken 的 tools/call 走 text/event-stream（progress 帧 + 终帧 result）', () async {
    final env = await spinUp();
    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 40,
      'method': 'tools/call',
      'params': {
        'name': 'list_items',
        'arguments': {'limit': 1},
        '_meta': {'progressToken': 'tok-1'},
      },
    }));
    final res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'text/event-stream');
    expect(res.headers.value('cache-control'), 'no-cache');
    final body = await utf8.decoder.bind(res).join();
    expect(body, contains('notifications/progress'), reason: '起始 progress 通知帧（ai-app-split.md §3.9）');
    expect(body, contains('tok-1'));
    // 心跳帧仅 >5s 无业务帧时出现——快工具单测窗口内通常不触发，时序保活由真机联调覆盖
    final frames = body.split('\n\n').where((f) => f.startsWith('data:')).toList();
    final last = jsonDecode(frames.last.substring('data:'.length)) as Map;
    expect(last['id'], 40);
    expect(last['result'], isNotNull, reason: '终帧必须含 result');

    // 无 token → 单 JSON 回归（桌面桥/既有客户端零破坏口径）
    final plain = await rpc(env.client, env.base, 41, 'tools/call', {
      'name': 'list_items',
      'arguments': {'limit': 1},
    });
    expect(errorOf(plain.body), isEmpty);
    env.client.close();
    await env.server.stop();
  });

  test('SSE 帧流错误分层：SSE 起始后工具报错走终帧 error（HTTP 已 200）', () async {
    final env = await spinUp();
    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 50,
      'method': 'tools/call',
      'params': {
        'name': 'no_such_tool',
        'arguments': {},
        '_meta': {'progressToken': 7},
      },
    }));
    final res = await req.close();
    expect(res.statusCode, 200, reason: 'SSE 已建立，错误只能走终帧');
    final body = await utf8.decoder.bind(res).join();
    final frames = body.split('\n\n').where((f) => f.startsWith('data:')).toList();
    final last = jsonDecode(frames.last.substring('data:'.length)) as Map;
    expect(last['id'], 50);
    expect((last['error'] as Map)['code'], errInvalidParams);
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

  test('M3 订阅：subscribe 后条目变更推送 updated；退订即停；非法 URI 拒绝', () async {
    final env = await spinUp();
    final (sse, it) = await openSse(env.client, env.base);
    expect(sse.statusCode, HttpStatus.ok);

    final sub = await rpc(env.client, env.base, 1, 'resources/subscribe', {'uri': 'goodshare://items'});
    expect(errorOf(sub.body), isEmpty, reason: '集合级订阅合法');
    expect(env.server.subscriptions.hasSubscription('goodshare://items'), isTrue);

    await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '订阅推送测试条目',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    final frame = await nextFrame(it);
    expect(frame?['jsonrpc'], '2.0');
    expect(frame?['method'], 'notifications/resources/updated');
    expect((frame?['params'] as Map)['uri'], startsWith('goodshare://items/'),
        reason: '通知 params 恒为具体条目 URI（集合级订阅也收具体 uri）');

    await rpc(env.client, env.base, 2, 'resources/unsubscribe', {'uri': 'goodshare://items'});
    expect(env.server.subscriptions.hasSubscription('goodshare://items'), isFalse);
    await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '退订后不应推送',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 2,
    ));
    await expectLater(
      nextFrame(it, timeout: const Duration(milliseconds: 500)),
      throwsA(isA<TimeoutException>()),
      reason: '退订后无推送',
    );

    final bad = await rpc(env.client, env.base, 3, 'resources/subscribe', {'uri': 'goodshare://other/1'});
    expect(errorOf(bad.body)['code'], errInvalidParams);
    it.cancel();
    env.client.close();
    await env.server.stop();
  });

  test('M3 sampling：ai_suggest_tags 流内反向请求 → 宿主回程 → 同步回标签', () async {
    final env = await spinUp();
    final added = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '今天在深圳湾跑步十公里，配速五分半，感觉状态不错',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));

    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 100,
      'method': 'tools/call',
      'params': {
        'name': 'ai_suggest_tags',
        'arguments': {'id': added.id},
        '_meta': {'progressToken': 1},
      },
    }));
    final res = await req.close();
    expect(res.headers.contentType?.mimeType, 'text/event-stream',
        reason: 'sampling 依赖流式通道，progressToken 触发 SSE');
    final it = StreamIterator(
        res.transform(utf8.decoder).transform(const LineSplitter()));

    final start = await nextFrame(it);
    expect(start?['method'], 'notifications/progress', reason: '起始 progress 帧');

    final mid = await nextFrame(it);
    expect(mid?['method'], 'notifications/progress', reason: 'M3-T2：sampling 前的中途帧（真实进度点）');
    expect(((mid?['params'] as Map)['message'] as String), contains('宿主推理'));

    final ask = await nextFrame(it);
    expect(ask?['method'], 'sampling/createMessage', reason: '反向请求帧夹带在响应流内');
    final askId = ask?['id'];
    expect(askId, isA<String>());
    expect((askId as String).startsWith('srv_'), isTrue, reason: 'srv_ 前缀防与客户端请求 id 相撞');
    final askParams = ask?['params'] as Map;
    final askText = (((askParams['messages'] as List).first as Map)['content'] as Map)['text'] as String;
    expect(askText, contains('深圳湾'), reason: '载荷须含条目正文');

    final ack = await rawPost(env.client, env.base, {
      'jsonrpc': '2.0',
      'id': askId,
      'result': {
        'role': 'assistant',
        'model': 'test-host',
        'content': {'type': 'text', 'text': '好标签如下：\n```json\n["跑步", "运动", "户外"]\n```'},
      },
    });
    expect(ack.body, isNull, reason: '回程响应 202 无 body');

    final finalFrame = await nextFrame(it);
    expect(finalFrame?['id'], 100, reason: '终帧 tools/call result');
    final content = ((finalFrame?['result'] as Map)['content'] as List).first as Map;
    final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
    expect(payload['status'], 'ok');
    expect(payload['tags'], ['跑步', '运动', '户外'], reason: '围栏包裹的 JSON 数组应被宽松提取');
    it.cancel();
    env.client.close();
    await env.server.stop();
  });

  test('M3 sampling：非流式调用返回 sampling_unavailable（结构化 status 不 isError）', () async {
    final env = await spinUp();
    final added = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '非流式路径的条目',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    final r = await rpc(env.client, env.base, 1, 'tools/call',
        {'name': 'ai_suggest_tags', 'arguments': {'id': added.id}});
    expect(errorOf(r.body), isEmpty);
    final content = (resultOf(r.body)['content'] as List).first as Map;
    final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
    expect(payload['status'], 'sampling_unavailable');
    expect(resultOf(r.body)['isError'], isNot(true), reason: '环境态不 isError，防宿主熔断误计数');
    env.client.close();
    await env.server.stop();
  });

  test('instant：ai_summarize_now 流内反向请求 → 宿主回程 → 同步回摘要 + version', () async {
    final env = await spinUp();
    final added = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '今天在深圳湾跑步十公里，配速五分半，感觉状态不错',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));

    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 100,
      'method': 'tools/call',
      'params': {
        'name': 'ai_summarize_now',
        'arguments': {'id': added.id},
        '_meta': {'progressToken': 1},
      },
    }));
    final res = await req.close();
    expect(res.headers.contentType?.mimeType, 'text/event-stream',
        reason: 'sampling 依赖流式通道，progressToken 触发 SSE');
    final it = StreamIterator(
        res.transform(utf8.decoder).transform(const LineSplitter()));

    final start = await nextFrame(it);
    expect(start?['method'], 'notifications/progress', reason: '起始 progress 帧');

    final mid = await nextFrame(it);
    expect(mid?['method'], 'notifications/progress', reason: 'M3-T2：sampling 前的中途帧（真实进度点）');
    expect(((mid?['params'] as Map)['message'] as String), contains('宿主推理'));

    final ask = await nextFrame(it);
    expect(ask?['method'], 'sampling/createMessage', reason: '反向请求帧夹带在响应流内');
    final askId = ask?['id'];
    expect((askId as String).startsWith('srv_'), isTrue, reason: 'srv_ 前缀防与客户端请求 id 相撞');
    final askParams = ask?['params'] as Map;
    final askText = (((askParams['messages'] as List).first as Map)['content'] as Map)['text'] as String;
    expect(askText, contains('深圳湾'), reason: '载荷须含条目正文');

    final ack = await rawPost(env.client, env.base, {
      'jsonrpc': '2.0',
      'id': askId,
      'result': {
        'role': 'assistant',
        'model': 'test-host',
        'content': {'type': 'text', 'text': '今天在深圳湾完成十公里跑步，配速约五分半，状态良好。'},
      },
    });
    expect(ack.body, isNull, reason: '回程响应 202 无 body');

    final finalFrame = await nextFrame(it);
    expect(finalFrame?['id'], 100, reason: '终帧 tools/call result');
    final content = ((finalFrame?['result'] as Map)['content'] as List).first as Map;
    final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
    expect(payload['status'], 'ok');
    expect(payload['item_id'], added.id);
    expect(payload['summary_md'], contains('深圳湾'));
    expect(payload['version'], added.version, reason: '读取时乐观锁版本随预览回传');
    it.cancel();
    env.client.close();
    await env.server.stop();
  });

  test('instant：非流式调用返回 sampling_unavailable（结构化 status 不 isError）', () async {
    final env = await spinUp();
    final added = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '非流式路径的条目',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    final r = await rpc(env.client, env.base, 1, 'tools/call',
        {'name': 'ai_summarize_now', 'arguments': {'id': added.id}});
    expect(errorOf(r.body), isEmpty);
    final content = (resultOf(r.body)['content'] as List).first as Map;
    final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
    expect(payload['status'], 'sampling_unavailable');
    expect(resultOf(r.body)['isError'], isNot(true));
    env.client.close();
    await env.server.stop();
  });

  test('instant：空正文返回 no_content（不发射采样）', () async {
    final env = await spinUp();
    final added = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '', // 无正文
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    final r = await rpc(env.client, env.base, 1, 'tools/call',
        {'name': 'ai_summarize_now', 'arguments': {'id': added.id}});
    final content = (resultOf(r.body)['content'] as List).first as Map;
    final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
    expect(payload['status'], 'no_content');
    env.client.close();
    await env.server.stop();
  });

  test('instant：只读不变——调用前后 get_item 的 summary 字段保持稳定为空', () async {
    final env = await spinUp();
    final added = await env.server.repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: '即时摘要只读不落库的正文内容',
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    String? summaryBefore() => added.summaryMd;
    expect(summaryBefore(), isNull, reason: '初始无摘要');

    final req = await env.client.postUrl(Uri.parse('${env.base}/mcp'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 100,
      'method': 'tools/call',
      'params': {
        'name': 'ai_summarize_now',
        'arguments': {'id': added.id},
        '_meta': {'progressToken': 1},
      },
    }));
    final res = await req.close();
    final it = StreamIterator(
        res.transform(utf8.decoder).transform(const LineSplitter()));
    await nextFrame(it); // progress
    await nextFrame(it); // progress (M3-T2 中途帧)
    final ask = await nextFrame(it);
    final askId = ask?['id'];
    await rawPost(env.client, env.base, {
      'jsonrpc': '2.0',
      'id': askId,
      'result': {
        'role': 'assistant',
        'model': 'test-host',
        'content': {'type': 'text', 'text': '一段摘要'},
      },
    });
    final finalFrame = await nextFrame(it);
    final content = ((finalFrame?['result'] as Map)['content'] as List).first as Map;
    final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
    expect(payload['status'], 'ok', reason: '即时预览成功返回');

    final fresh = await env.server.repo.byId(added.id!);
    expect(fresh?.summaryMd, isNull, reason: '工具只读，摘要不落库');
    it.cancel();
    env.client.close();
    await env.server.stop();
  });

  test('§3.12 task_queued 帧形：Binder onEvent 发出，无 id、params 为空', () async {
    final env = await spinUp();
    final frames = <String>[];
    env.server.onEventEmitter = frames.add;

    env.server.notifyTaskQueued();

    expect(frames.length, 1, reason: 'Binder 在线则走 IMcpCallback.onEvent');
    final frame = jsonDecode(frames.single) as Map<String, Object?>;
    expect(frame['jsonrpc'], '2.0');
    expect(frame['method'], 'notifications/x-goodshare/task_queued');
    expect(frame.containsKey('id'), isFalse,
        reason: '带 id 会被 goodhub BinderTransport 按「含 id」路由成反向请求响应（§1.2.2）');
    expect(frame['params'], isEmpty,
        reason: 'params 恒空：仅提示「可能有任务」，宿主不得据帧数推断任务数（§3.12.1）');

    env.client.close();
    await env.server.stop();
  });
}
