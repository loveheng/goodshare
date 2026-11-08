import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goodshare/service/mcp_bridge_channel.dart';
import 'package:goodshare/service/on_device_service.dart';

/// 假桥：可编程响应 + 调用留痕（返回 null = 宿主未连入，环境态）。
class FakeOnDeviceBridge extends McpBridgeChannel {
  FakeOnDeviceBridge({this.responder, this.returnsNull = false});

  final List<String> calls = [];
  final Object? Function(String method, Map<String, Object?> params)?
      responder;
  final bool returnsNull;

  @override
  Future<Object?> onDeviceCall(
      String method, Map<String, Object?> params) async {
    calls.add(method);
    if (returnsNull) return null;
    if (responder != null) return responder!(method, params);
    return null;
  }
}

/// W6-a 端侧异步消费单测（SSOT = ai-app-split.md §3.11.2 /
/// goodhub on-device-residency 第七节）：联合态解析纪律 / 持久化续拉 /
/// Pull 状态机（交付、stale、毒丸、过期、not_found、在途保持）/ 宿主不可用降级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 宿主 result 信封（content.text 承载联合态/投影）。
  Map<String, Object?> env(String text) => {
        'role': 'assistant',
        'model': 'goodhub-on-device',
        'content': {'type': 'text', 'text': text},
      };

  String proj({required String status, String? result, String? failReason}) {
    final map = <String, Object?>{
      'taskId': 't-1',
      'status': status,
      'retries': 0,
      'createdAtMs': 0,
      'expiryAtMs': 0,
    };
    if (result != null) map['result'] = result;
    if (failReason != null) map['failReason'] = failReason;
    return jsonEncode(map);
  }

  group('OnDeviceOutcome.parse', () {
    test('纯文本 → Immediate（不嗅探）', () {
      final out = OnDeviceOutcome.parse('这是摘要正文');
      expect(out, isA<OnDeviceImmediate>());
      expect((out as OnDeviceImmediate).text, '这是摘要正文');
    });

    test('无 execution_mode 的 JSON → Immediate（模型产出 JSON 不误判）', () {
      final out = OnDeviceOutcome.parse('{"foo":"bar"}');
      expect(out, isA<OnDeviceImmediate>());
    });

    test('deferred 回执 → Deferred（taskId/status/expiry）', () {
      final out = OnDeviceOutcome.parse(
          '{"execution_mode":"deferred","task_id":"t-9","status":"queued","expiry_ms":86400000}');
      expect(out, isA<OnDeviceDeferred>());
      out as OnDeviceDeferred;
      expect(out.taskId, 't-9');
      expect(out.status, 'queued');
      expect(out.expiryMs, 86400000);
    });

    test('deferred 缺 task_id → 抛错（宿主契约违约显式暴露）', () {
      expect(
          () => OnDeviceOutcome.parse(
              '{"execution_mode":"deferred","status":"queued"}'),
          throwsArgumentError);
    });
  });

  group('OnDeviceAsyncService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('complete：桥不可用 → OnDeviceHostUnavailable（环境态）', () async {
      final svc =
          OnDeviceAsyncService(bridge: FakeOnDeviceBridge(returnsNull: true));
      await svc.init();
      expect(
        svc.complete(instruction: 'i', input: 'x'),
        throwsA(isA<OnDeviceHostUnavailable>()),
      );
      await svc.dispose();
    });

    test('complete：温热态同步直出 → Immediate', () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(responder: (_, _) => env('摘要正文')));
      await svc.init();
      final out = await svc.complete(instruction: 'i', input: 'x');
      expect(out, isA<OnDeviceImmediate>());
      await svc.dispose();
    });

    test('complete：allow_deferred 透传 + 冷态入池 → Deferred', () async {
      Map<String, Object?>? seenParams;
      final svc = OnDeviceAsyncService(
        bridge: FakeOnDeviceBridge(
          responder: (method, params) {
            seenParams = params;
            return env(
                '{"execution_mode":"deferred","task_id":"t-9","status":"queued","expiry_ms":3600000}');
          },
        ),
      );
      await svc.init();
      final out = await svc.complete(
          instruction: 'i', input: 'x', allowDeferred: true);
      expect(out, isA<OnDeviceDeferred>());
      expect(seenParams,
          {'instruction': 'i', 'input': 'x', 'allow_deferred': true});
      await svc.dispose();
    });

    test('registerDeferred：持久化 + tasksForItem + 重启续拉', () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(returnsNull: true));
      await svc.init();
      await svc.registerDeferred(
          taskId: 't-1',
          itemId: 'i-1',
          bodyMd5: 'md5-a',
          instruction: '即时摘要',
          expiryMs: 86400000);
      expect(svc.tasksForItem('i-1').single.taskId, 't-1');

      // 新实例（模拟 App 重启）从 prefs 恢复同一登记。
      final svc2 = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(returnsNull: true));
      await svc2.init();
      expect(svc2.tasksForItem('i-1').single.taskId, 't-1');
      await svc.dispose();
      await svc2.dispose();
    });

    test('init：已过期任务直接收敛 failed（本地过期清账）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('on_device.deferred.v1', jsonEncode([
        {
          'taskId': 't-exp',
          'itemId': 'i-1',
          'bodyMd5': 'm',
          'instruction': 'x',
          'createdAtMs': 1,
          'expiryAtMs': 2,
        }
      ]));
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(returnsNull: true));
      final events = <OnDeviceTaskEvent>[];
      final sub = svc.events.listen(events.add);
      await svc.init();
      await Future<void>.delayed(Duration.zero); // 冲刷广播流投递微任务
      expect(events.single.isFailed, isTrue);
      expect(events.single.reason, '任务已过期');
      expect(svc.tasksForItem('i-1'), isEmpty);
      await sub.cancel();
      await svc.dispose();
    });

    test('poll：pendingDelivery + 正文未变 → result 事件 + 摘登记', () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(
              responder: (m, p) => env(proj(status: 'pendingDelivery', result: '端侧摘要'))));
      await svc.init(readBodyMd5: (_) async => 'md5-a');
      await svc.registerDeferred(
          taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
      final events = <OnDeviceTaskEvent>[];
      final sub = svc.events.listen(events.add);
      await svc.pollOnce();
      await Future<void>.delayed(Duration.zero); // 冲刷广播流投递微任务
      expect(events.single.isResult, isTrue);
      expect(events.single.result, '端侧摘要');
      expect(svc.tasksForItem('i-1'), isEmpty);
      await sub.cancel();
      await svc.dispose();
    });

    test('poll：正文已变 → stale 事件（时效收敛）', () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(
              responder: (m, p) => env(proj(status: 'delivered', result: '端侧摘要'))));
      await svc.init(readBodyMd5: (_) async => 'md5-changed');
      await svc.registerDeferred(
          taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
      final events = <OnDeviceTaskEvent>[];
      final sub = svc.events.listen(events.add);
      await svc.pollOnce();
      await Future<void>.delayed(Duration.zero); // 冲刷广播流投递微任务
      expect(events.single.isStale, isTrue);
      expect(svc.tasksForItem('i-1'), isEmpty);
      await sub.cancel();
      await svc.dispose();
    });

    test('poll：failedExhausted → failed 事件（含宿主原因，毒丸可见不可恢复）',
        () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(
              responder: (m, p) =>
                  env(proj(status: 'failedExhausted', failReason: '模型装载失败'))));
      await svc.init(readBodyMd5: (_) async => 'md5-a');
      await svc.registerDeferred(
          taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
      final events = <OnDeviceTaskEvent>[];
      final sub = svc.events.listen(events.add);
      await svc.pollOnce();
      await Future<void>.delayed(Duration.zero); // 冲刷广播流投递微任务
      expect(events.single.isFailed, isTrue);
      expect(events.single.reason, contains('模型装载失败'));
      expect(svc.tasksForItem('i-1'), isEmpty);
      await sub.cancel();
      await svc.dispose();
    });

    test('poll：not_found → failed 事件（宿主已清账）', () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(
              responder: (m, p) => env(proj(status: 'not_found'))));
      await svc.init(readBodyMd5: (_) async => 'md5-a');
      await svc.registerDeferred(
          taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
      final events = <OnDeviceTaskEvent>[];
      final sub = svc.events.listen(events.add);
      await svc.pollOnce();
      await Future<void>.delayed(Duration.zero); // 冲刷广播流投递微任务
      expect(events.single.isFailed, isTrue);
      expect(events.single.reason, contains('不存在'));
      await sub.cancel();
      await svc.dispose();
    });

    test('poll：queued/running → 保持占位（在途不摘）', () async {
      for (final status in ['queued', 'running']) {
        final svc = OnDeviceAsyncService(
            bridge: FakeOnDeviceBridge(
                responder: (m, p) => env(proj(status: status))));
        await svc.init(readBodyMd5: (_) async => 'md5-a');
        await svc.registerDeferred(
            taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
        await svc.pollOnce();
        expect(svc.tasksForItem('i-1'), isNotEmpty, reason: status);
        await svc.dispose();
      }
    });

    test('poll：宿主未连入 → 保持占位 + 下轮重试（不摘登记）', () async {
      final svc = OnDeviceAsyncService(
          bridge: FakeOnDeviceBridge(returnsNull: true));
      await svc.init(readBodyMd5: (_) async => 'md5-a');
      await svc.registerDeferred(
          taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
      await svc.pollOnce();
      expect(svc.tasksForItem('i-1'), isNotEmpty);
      await svc.dispose();
    });

    test('dropTask：用户取消 → 摘登记且不再轮询', () async {
      final bridge = FakeOnDeviceBridge(returnsNull: true);
      final svc = OnDeviceAsyncService(bridge: bridge);
      await svc.init();
      await svc.registerDeferred(
          taskId: 't-1', itemId: 'i-1', bodyMd5: 'md5-a', instruction: 'x');
      await svc.dropTask('t-1');
      expect(svc.tasksForItem('i-1'), isEmpty);
      await svc.pollOnce();
      expect(bridge.calls, isEmpty);
      await svc.dispose();
    });
  });
}
