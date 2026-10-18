import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/mcp/ai_proxy.dart';
import 'package:goodshare/mcp/jsonrpc.dart';
import 'package:goodshare/models/item.dart';

/// AiSamplingProxy 单元契约（instant-ai-sampling.md §4.3 / §4.4 / §8 T1）：
/// 四态降级映射 / single-flight 去重 / 4000 截断注记 / TTFT 30s 超时 abort / bodyMd5 收编等价。
void main() {
  test('ok：宿主回程映射为 status=ok + text', () async {
    final p = AiSamplingProxy(ttftTimeout: const Duration(seconds: 5));
    final r = await p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) => Future.value({'content': {'text': '摘要内容'}}),
    );
    expect(r.status, 'ok');
    expect(r.text, '摘要内容');
  });

  test('配额超限（-32000）→ sampling_quota_exceeded', () async {
    final p = AiSamplingProxy(ttftTimeout: const Duration(seconds: 5));
    final r = await p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) => Future.error(McpRpcError(-32000, '配额超限')),
    );
    expect(r.status, 'sampling_quota_exceeded');
    expect(r.code, -32000);
    expect(r.hint, '配额超限');
  });

  test('其他错误 → sampling_failed（不误判为配额）', () async {
    final p = AiSamplingProxy(ttftTimeout: const Duration(seconds: 5));
    final r = await p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) => Future.error(McpRpcError(-32099, '推理异常')),
    );
    expect(r.status, 'sampling_failed');
    expect(r.hint, '推理异常');
  });

  test('截断：正文超 4000 字符加注记且不超长', () async {
    String? captured;
    final p = AiSamplingProxy(ttftTimeout: const Duration(seconds: 5));
    final r = await p.run(
      systemPrompt: 's',
      userPrompt: 'x' * 5000,
      pool: 'instant',
      sampling: (params) {
        final p = params as Map<String, Object?>;
        captured = ((((p['messages'] as List).first as Map)['content']
                as Map)['text'] as String);
        return Future.value({'content': {'text': 'ok'}});
      },
    );
    expect(captured, startsWith('（原文超长，以下仅为前 4000 字）'));
    expect(captured!.length, lessThanOrEqualTo(4000 + 30));
    expect(r.text, 'ok');
  });

  test('single-flight：同指纹两次调用只发射一次', () async {
    var calls = 0;
    final c = Completer<Object?>();
    final p = AiSamplingProxy(ttftTimeout: const Duration(seconds: 5));
    final f1 = p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) {
        calls++;
        return c.future;
      },
    );
    final f2 = p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) {
        calls++;
        return c.future;
      },
    );
    expect(calls, 1, reason: '在途期间同指纹复用同一 Future，不二次发射');
    c.complete({'content': {'text': 'hi'}});
    final r1 = await f1;
    final r2 = await f2;
    expect(r1.text, 'hi');
    expect(r2.text, 'hi');
  });

  test('single-flight：不同指纹各自发射', () async {
    var calls = 0;
    final c1 = Completer<Object?>();
    final c2 = Completer<Object?>();
    final p = AiSamplingProxy(ttftTimeout: const Duration(seconds: 5));
    p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) {
        calls++;
        return c1.future;
      },
    );
    p.run(
      systemPrompt: 's',
      userPrompt: 'different',
      pool: 'instant',
      sampling: (_) {
        calls++;
        return c2.future;
      },
    );
    expect(calls, 2);
    c1.complete({'content': {'text': 'a'}});
    c2.complete({'content': {'text': 'b'}});
    await Future.delayed(Duration.zero);
  });

  test('TTFT：30s 内无回程 → sampling_failed（孤儿请求静默丢弃，无 unhandled）', () async {
    final p = AiSamplingProxy(ttftTimeout: const Duration(milliseconds: 80));
    // sampling 永不回（模拟宿主挂起）；底层 Future 保持 pending，由 .then(onError) 接住。
    final r = await p.run(
      systemPrompt: 's',
      userPrompt: 'u',
      pool: 'instant',
      sampling: (_) => Completer<Object?>().future,
    );
    expect(r.status, 'sampling_failed');
    expect(r.hint, contains('超时'));
  });

  test('bodyMd5 与 md5(utf8(humanMd ?? "")) 等价（收编三处复制点）', () {
    expect(bodyMd5('hello'), md5.convert(utf8.encode('hello')).toString());
    expect(bodyMd5(null), md5.convert(utf8.encode('')).toString());
    expect(bodyMd5(''), md5.convert(utf8.encode('')).toString());
  });
}
