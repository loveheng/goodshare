import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/mcp/mcp_server.dart';
import 'package:goodshare/share/share_intake.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, Object?> resultOf(Map<String, Object?>? body) =>
    (body?['result'] ?? <String, Object?>{}) as Map<String, Object?>;

Map<String, Object?> errorOf(Map<String, Object?>? body) =>
    (body?['error'] ?? <String, Object?>{}) as Map<String, Object?>;

void main() {
  setUpAll(() {
    // VM 单测用 ffi 数据库工厂
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    final intake = ShareIntake(Repository());
    expect(intake.parseText('https://a.b/c').type, 'LINK');
    final t2 = intake.parseText('一篇好文章\nhttps://a.b/c');
    expect(t2.type, 'LINK');
    expect(t2.title, '一篇好文章');
    expect(intake.parseText('随手记点什么').type, 'TEXT');
  });
}
