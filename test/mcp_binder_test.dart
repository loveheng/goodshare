import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/mcp/mcp_server.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, Object?> resultOf(Map<String, Object?>? body) =>
    (body?['result'] ?? <String, Object?>{}) as Map<String, Object?>;

Map<String, Object?> errorOf(Map<String, Object?>? body) =>
    (body?['error'] ?? <String, Object?>{}) as Map<String, Object?>;

/// onEvent 帧捕获 + 可等待筛选（backlog 消费式，规避 broadcast 不重放丢失）。
///
/// 模拟 [McpBinderService] 经 MethodChannel `pushEvent` 收 `IMcpCallback.onEvent` 的行为：
/// goodshare Binder 侧 [_emitAsyncResult] / [_binderSampling] 经 [McpServer.onEventEmitter]
/// 推 `progress` / 反向请求（含 method）/ `_async` 终帧（不含 method，按 id 关联）三类帧。
class _EventTap {
  final List<Map<String, Object?>> _buf = [];
  final StreamController<Map<String, Object?>> _stream =
      StreamController<Map<String, Object?>>.broadcast();

  void onEvent(String payload) {
    final m = jsonDecode(payload) as Map<String, Object?>;
    _buf.add(m);
    if (!_stream.isClosed) _stream.add(m);
  }

  /// 取首个匹配帧并从 backlog 移除；不在 backlog 则等待后续流（带超时防挂死）。
  Future<Map<String, Object?>> where(
    bool Function(Map<String, Object?>) pred, {
    Duration timeout = const Duration(seconds: 10),
    String? reason,
  }) async {
    for (var i = 0; i < _buf.length; i++) {
      if (pred(_buf[i])) return _buf.removeAt(i);
    }
    final sub = _stream.stream.listen(null);
    final completer = Completer<Map<String, Object?>>();
    sub.onData((m) {
      if (pred(m) && !completer.isCompleted) completer.complete(m);
    });
    try {
      return await completer.future.timeout(timeout,
          onTimeout: () => throw TimeoutException(reason ?? 'onEvent 等待帧超时'));
    } finally {
      await sub.cancel();
    }
  }

  List<Map<String, Object?>> get buffer => List.unmodifiable(_buf);
}

/// 等一个微任务/事件循环轮转，让 fire-and-forget 的 [_runAsyncTool] 推进若干 await。
Future<void> pumpLoop([Duration d = const Duration(milliseconds: 50)]) =>
    Future<void>.delayed(d);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  /// 构造 Binder 后台引擎等价体：独立 McpServer + onEventEmitter 接线（不含 HTTP/端口）。
  ({McpServer server, _EventTap tap}) binderEngine({bool wireEvents = true}) {
    final server = McpServer(repo: Repository(), tokenProvider: () => null);
    final tap = _EventTap();
    if (wireEvents) server.onEventEmitter = tap.onEvent;
    return (server: server, tap: tap);
  }

  Future<String?> addItem(Repository repo, String body) async {
    final it = await repo.add(InboxItem(
      itemType: InboxItem.typeNote,
      sourceType: InboxItem.typeNote,
      rawContent: body,
      collectMode: InboxItem.modeScatter,
      aiVisible: true,
      createdAt: 1,
    ));
    return it.id;
  }

  group('Binder _async 占位（#4）：handleJsonRpc 长任务秒回不阻塞', () {
    test('onEventEmitter 未接（非 Binder/HTTP）→ ai_suggest_tags 同步 sampling_unavailable，不 _async',
        () async {
      final env = binderEngine(wireEvents: false);
      final id = await addItem(env.server.repo, '非流式路径的条目正文');
      final resp = await env.server.handleJsonRpc(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'ai_suggest_tags',
          'arguments': {'id': id},
        },
      }));
      final body = jsonDecode(resp) as Map<String, Object?>;
      expect(errorOf(body), isEmpty, reason: '无错误帧');
      expect(resultOf(body)['_async'], isNull, reason: '非 Binder 不应出现 _async 占位');
      final content = (resultOf(body)['content'] as List).first as Map;
      final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
      expect(payload['status'], 'sampling_unavailable');
    });

    test('onEventEmitter 已接 → ai_suggest_tags 立即回 _async:true 占位帧（call 不阻塞等待采样）',
        () async {
      final env = binderEngine();
      final id = await addItem(env.server.repo, '深圳湾晨跑十公里，配速五分半，状态不错');
      final stopwatch = Stopwatch()..start();
      final resp = await env.server.handleJsonRpc(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'ai_suggest_tags',
          'arguments': {'id': id},
        },
      }));
      stopwatch.stop();
      final body = jsonDecode(resp) as Map<String, Object?>;
      // 关键契约：秒回占位，绝不同步阻塞 90s 采样窗口（§1.2.3 <5s 预算）。
      expect(stopwatch.elapsedMilliseconds, lessThan(5000),
          reason: 'Binder call 必须秒回，严禁为采样同步阻塞触发 ANR');
      expect(resultOf(body)['_async'], isTrue,
          reason: 'Binder 长任务须立即返回 {"result":{"_async":true}}');
      expect(body['id'], 2, reason: '占位帧 id 与原始 tools/call 一致');
      // 占位帧返回瞬间，真实结果（终帧）尚未算出：buffer 可能已含合法的
      // sampling 反向请求帧，但绝不可含 id=2 且不含 method 的终帧。
      await pumpLoop();
      expect(
        env.tap.buffer.where((m) => m['id'] == 2 && m['method'] == null).isEmpty,
        isTrue,
        reason: '占位帧返回时不得已推 onEvent 终帧（真实结果后台异步计算）',
      );
    });
  });

  group('Binder onEvent 帧形状（§1.2.2）：反向请求含 method / 终帧不含 method 按 id 关联', () {
    test('ai_suggest_tags e2e：反向请求帧 + 终帧闭环，标签回写', () async {
      final env = binderEngine();
      final id = await addItem(env.server.repo, '今天在深圳湾跑步十公里，配速五分半，感觉状态不错');
      final resp = await env.server.handleJsonRpc(jsonEncode({
        'jsonrpc': '2.0',
        'id': 100,
        'method': 'tools/call',
        'params': {
          'name': 'ai_suggest_tags',
          'arguments': {'id': id},
        },
      }));
      expect(resultOf(jsonDecode(resp) as Map<String, Object?>)['_async'], isTrue);

      // 1) 反向请求帧（server→client，含 method）：经 onEvent 外发，宿主按 id 经 answerReverse 回程。
      final ask = await env.tap.where(
        (m) => m['method'] == 'sampling/createMessage',
        reason: '应经 onEvent 收到 sampling/createMessage 反向请求帧',
      );
      final askId = ask['id'];
      expect(askId, isA<String>(), reason: '反向请求 id 为字符串');
      expect((askId as String).startsWith('srv_'), isTrue,
          reason: 'srv_ 前缀防与客户端请求 id 相撞（§3.11）');
      final p = ask['params'] as Map<String, Object?>;
      final askText =
          (((p['messages'] as List).first as Map)['content'] as Map)['text'] as String;
      expect(askText, contains('深圳湾'), reason: '载荷须含条目正文（与 goodhub samplingRequestHandler 字段对齐）');
      expect(p['systemPrompt'], '你是标签提取器。输出严格为 JSON 字符串数组。');
      expect(p['maxTokens'], 256);

      // 2) 宿主模拟回程（goodhub samplingRequestHandler 等价产物）→ answerReverse 唤醒 completer。
      env.server.answerReverse(jsonEncode({
        'jsonrpc': '2.0',
        'id': askId,
        'result': {
          'role': 'assistant',
          'model': 'test-host',
          'content': {'type': 'text', 'text': '好标签如下：\n```json\n["跑步", "运动", "户外"]\n```'},
        },
      }));

      // 3) 终帧（不含 method，id 同原始 call）：宿主按 id 关联完成 tools/call。
      final term = await env.tap.where(
        (m) => m['id'] == 100 && m['method'] == null,
        reason: '应经 onEvent 收到 _async 终帧（无 method，id=100）',
      );
      expect(term.containsKey('method'), isFalse,
          reason: '终帧不含 method（与反向请求帧靠「是否含 method」区分，§1.2.2）');
      expect(term.containsKey('error'), isFalse, reason: '成功终帧应为 result 非 error');
      final tResult = term['result'] as Map<String, Object?>;
      final content = (tResult['content'] as List).first as Map;
      final payload = jsonDecode(content['text'] as String) as Map<String, Object?>;
      expect(payload['status'], 'ok');
      expect(payload['tags'], ['跑步', '运动', '户外'],
          reason: '围栏包裹的 JSON 数组应被宽松提取');
    });

    test('宿主反向请求回 error（配额 -32000）→ 终帧 result.status=sampling_quota_exceeded，不 isError 帧',
        () async {
      final env = binderEngine();
      final id = await addItem(env.server.repo, '配额超限场景的条目正文内容');
      final resp = await env.server.handleJsonRpc(jsonEncode({
        'jsonrpc': '2.0',
        'id': 101,
        'method': 'tools/call',
        'params': {'name': 'ai_suggest_tags', 'arguments': {'id': id}},
      }));
      expect(resultOf(jsonDecode(resp) as Map<String, Object?>)['_async'], isTrue);

      final ask = await env.tap.where((m) => m['method'] == 'sampling/createMessage',
          reason: '应收到反向请求帧');
      // 宿主配额超限（goodhub SamplingQuota 抛 -32000，data 带 retry hint）。
      env.server.answerReverse(jsonEncode({
        'jsonrpc': '2.0',
        'id': ask['id'],
        'error': {'code': -32000, 'message': 'sampling 配额超限'},
      }));

      final term = await env.tap.where(
        (m) => m['id'] == 101 && m['method'] == null,
        reason: '应收到 _async 终帧',
      );
      expect(term.containsKey('error'), isFalse,
          reason: '宿主拒绝是环境态，走 content.status 而非 JSON-RPC error 帧（防宿主熔断误计数）');
      final payload = jsonDecode(
          (((term['result'] as Map)['content'] as List).first as Map)['text'] as String)
          as Map<String, Object?>;
      expect(payload['status'], 'sampling_quota_exceeded');
      expect(payload['code'], -32000);
    });
  });

  group('Binder _emitAsyncResult error 分支（#4）：工具异常 → 终帧走 error 帧', () {
    test('条目不存在 → 终帧为 error 帧（id 同 call，无 method，code=errInvalidParams）', () async {
      final env = binderEngine();
      final resp = await env.server.handleJsonRpc(jsonEncode({
        'jsonrpc': '2.0',
        'id': 200,
        'method': 'tools/call',
        'params': {'name': 'ai_suggest_tags', 'arguments': {'id': 'no-such-item'}},
      }));
      expect(resultOf(jsonDecode(resp) as Map<String, Object?>)['_async'], isTrue);

      // 反向请求帧不应出现（工具在读条目阶段即抛错，未发 sampling）。
      final term = await env.tap.where(
        (m) => m['id'] == 200 && m['method'] == null,
        reason: '应收到 _async error 终帧',
      );
      expect(term.containsKey('result'), isFalse, reason: '异常终帧走 error 分支');
      final err = term['error'] as Map<String, Object?>;
      expect(err['code'], errInvalidParams);
      expect(term['id'], 200);
    });
  });

  group('Binder answerReverse 容错（#5）', () {
    test('未知 id 静默忽略，不抛异常、不挂 pending', () async {
      final env = binderEngine();
      expect(() => env.server.answerReverse(jsonEncode({
            'jsonrpc': '2.0',
            'id': 'srv_unknown',
            'result': {'role': 'assistant', 'content': {'type': 'text', 'text': 'x'}},
          })),
          returnsNormally,
          reason: '无在途反向请求时 answerReverse 须静默忽略（§3.11 防御）');
    });

    test('坏 JSON 静默忽略', () async {
      final env = binderEngine();
      expect(() => env.server.answerReverse('not-json'), returnsNormally);
    });
  });
}
