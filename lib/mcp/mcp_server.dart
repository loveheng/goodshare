import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/repository.dart';
import 'jsonrpc.dart';
import 'tools.dart';

/// 内嵌 MCP 服务：Streamable HTTP（POST /mcp，application/json 单响应）。
/// v1 不做服务端主动推送：GET/DELETE 返回 405；也不签发会话 id（规范允许 MAY，
/// 无状态更简单，桌面桥与直连客户端都不依赖会话）。
class McpServer {
  McpServer({required this.repo, required this.tokenProvider});

  final Repository repo;

  /// 返回当前生效 token；为空表示关闭鉴权。
  final String? Function() tokenProvider;

  HttpServer? _server;
  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  Future<void> start({int port = 8765}) async {
    if (running) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(
      (req) async {
        try {
          await _onRequest(req);
        } catch (e) {
          await _safeJson(req, HttpStatus.internalServerError, _rpcError(null, errInternal, '内部错误: $e'));
        }
      },
      onError: (Object _) {/* 客户端异常断开等，忽略 */},
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _onRequest(HttpRequest req) async {
    final token = tokenProvider();
    if (token != null && token.isNotEmpty && req.headers.value('x-api-key') != token) {
      await _safeJson(req, HttpStatus.unauthorized, _rpcError(null, -32001, 'X-Api-Key 校验失败（app「MCP 服务」页可查看 token）'));
      return;
    }
    if (req.uri.path != '/mcp') {
      await _safeJson(req, HttpStatus.notFound, _rpcError(null, errInvalidRequest, '未知路径，MCP 端点为 /mcp'));
      return;
    }
    if (req.method != 'POST') {
      await _safeJson(req, HttpStatus.methodNotAllowed, _rpcError(null, errInvalidRequest, '仅支持 POST /mcp（本服务不提供 SSE 长连接）'));
      return;
    }

    final body = await utf8.decoder.bind(req).join();
    Object? msg;
    try {
      msg = jsonDecode(body);
    } catch (_) {
      await _safeJson(req, HttpStatus.badRequest, _rpcError(null, errParse, 'JSON 解析失败'));
      return;
    }
    // 2025-06-18 已移除 batch；收到数组一律按无效请求处理。
    if (msg is! Map<String, Object?>) {
      await _safeJson(req, HttpStatus.badRequest, _rpcError(null, errInvalidRequest, '仅支持单条 JSON-RPC 消息'));
      return;
    }

    final method = msg['method'];
    final id = msg['id'];
    if (id == null) {
      // 通知（如 notifications/initialized）：无需应答
      req.response.statusCode = HttpStatus.accepted;
      await req.response.close();
      return;
    }
    if (method is! String) {
      await _json(req, HttpStatus.ok, _rpcError(id, errInvalidRequest, '缺少 method'));
      return;
    }

    try {
      final result = await _dispatch(method, msg['params']);
      await _json(req, HttpStatus.ok, {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      });
    } on McpRpcError catch (e) {
      await _json(req, HttpStatus.ok, {'jsonrpc': '2.0', 'id': id, 'error': e.toMap()});
    } catch (e) {
      await _json(req, HttpStatus.ok, _rpcError(id, errInternal, '工具执行失败: $e'));
    }
  }

  Future<Object?> _dispatch(String method, Object? params) async {
    switch (method) {
      case 'initialize':
        final p = params is Map<String, Object?> ? params : const {};
        return {
          'protocolVersion': McpProtocol.negotiate(p['protocolVersion']),
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'goodshare', 'version': '1.0.0'},
          'instructions':
              '「拾贝」是用户的日常分享收集器。用 list_items 检索/浏览收集内容（支持关键词与类型过滤），'
                  'get_item 读取全文与图片，add_item 可代用户写入文本或链接。',
        };
      case 'ping':
        return <String, Object?>{};
      case 'tools/list':
        return {'tools': toolSchemas()};
      case 'tools/call':
        final p = params is Map<String, Object?> ? params : const <String, Object?>{};
        final name = p['name'];
        if (name is! String) throw McpRpcError(errInvalidParams, '缺少 tool name');
        final args = p['arguments'] is Map<String, Object?>
            ? p['arguments'] as Map<String, Object?>
            : <String, Object?>{};
        final content = await callTool(name, args, repo);
        return {'content': content, 'isError': false};
      case 'resources/list':
        return {'resources': <Map<String, Object?>>[]};
      case 'prompts/list':
        return {'prompts': <Map<String, Object?>>[]};
      default:
        throw McpRpcError(errMethodNotFound, '未知方法: $method');
    }
  }

  Map<String, Object?> _rpcError(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  Future<void> _json(HttpRequest req, int status, Object? payload) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(payload == null ? '' : jsonEncode(payload));
    await req.response.close();
  }

  Future<void> _safeJson(HttpRequest req, int status, Object? payload) async {
    try {
      await _json(req, status, payload);
    } catch (_) {/* 连接已断开 */}
  }
}
