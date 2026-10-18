/// 资源订阅注册表 + GET SSE 下行通道（ai-app-split.md §3.10，M3 接缝扩展）。
/// goodshare 延续无会话 id 的无状态口径：订阅为 **server 级全局注册**，通知
/// 广播至所有在线 GET SSE 连接——单宿主场景语义等价，多宿主过度通知为已知
/// 取舍（契约节写明）。订阅在连接断开后保留（宿主重连后重放订阅，幂等）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 订阅 URI 口径：`goodshare://items`（集合级——任一条目变更均通知）或
/// `goodshare://items/{uuid}`（单条）。其余形状一律非法（dispatch 层转 -32602）。
bool isValidSubscriptionUri(String uri) {
  if (uri == 'goodshare://items') return true;
  if (!uri.startsWith('goodshare://items/')) return false;
  final id = uri.substring('goodshare://items/'.length);
  return id.isNotEmpty && !id.contains('/') && !id.contains('?');
}

class _SseClient {
  _SseClient(this._request) {
    final res = _request.response;
    res.statusCode = HttpStatus.ok;
    res.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-cache');
    res.headers.set('X-Accel-Buffering', 'no');
    res.bufferOutput = false; // 逐帧即时下发，防缓冲滞留（同 _streamingToolCall 口径）
    // 与 tools/call 帧流同一心跳口径（5s keep-alive comment 帧）。
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      _writeRaw(': keep-alive\n\n');
    });
  }

  final HttpRequest _request;
  late final Timer _heartbeat;
  bool _closed = false;

  void send(Map<String, Object?> frame) {
    _writeRaw('data: ${jsonEncode(frame)}\n\n');
  }

  void _writeRaw(String s) {
    if (_closed) return;
    try {
      _request.response.write(s);
    } catch (_) {
      close(); // 客户端断开等写失败：立即掉线（detach 由 done 回调兜底）
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _heartbeat.cancel();
    try {
      _request.response.close();
    } catch (_) {/* 连接已断开 */}
  }
}

class ResourceSubscriptionHub {
  final Set<String> _uris = <String>{};
  final List<_SseClient> _clients = <_SseClient>[];

  int get connectionCount => _clients.length;
  bool hasSubscription(String uri) => _uris.contains(uri);

  void subscribe(String uri) => _uris.add(uri);

  void unsubscribe(String uri) => _uris.remove(uri);

  /// 接管 GET 请求为 SSE 下行长连接（鉴权与 Origin 校验已由 server 层完成）。
  void attach(HttpRequest req) {
    final client = _SseClient(req);
    _clients.add(client);
    // 客户端断开（done 触发）即摘除，防死连接堆积。
    unawaited(req.response.done.whenComplete(() => _clients.remove(client)));
  }

  /// 向所有在线 SSE 下行连接广播**已成型帧**（订阅线与 §3.12 任务通知共用同一条
  /// 下行长连接，ai-app-split.md §3.12.1：HTTP 走 SSE 订阅流）。无连接时零开销。
  void broadcast(Map<String, Object?> frame) {
    if (_clients.isEmpty) return;
    for (final c in List.of(_clients)) {
      c.send(frame);
    }
  }

  /// 条目变更 → 命中订阅即向所有在线连接广播 notifications/resources/updated。
  /// 通知 params 恒为**具体条目 URI**（集合级订阅也收具体 uri——宿主自行匹配）。
  void onItemChanged(String itemId) {
    if (_uris.isEmpty || _clients.isEmpty) return;
    final uri = 'goodshare://items/$itemId';
    if (!_uris.contains('goodshare://items') && !_uris.contains(uri)) return;
    final frame = <String, Object?>{
      'jsonrpc': '2.0',
      'method': 'notifications/resources/updated',
      'params': {'uri': uri},
    };
    for (final c in List.of(_clients)) {
      c.send(frame);
    }
  }

  /// server.stop() 时关闭全部下行连接（幂等）。
  void dispose() {
    for (final c in List.of(_clients)) {
      c.close();
    }
    _clients.clear();
  }
}
