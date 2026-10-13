import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/repository.dart';
import 'jsonrpc.dart';
import 'prompts_resources.dart';
import 'subscriptions.dart';
import 'tools.dart';

/// 内嵌 MCP 服务：Streamable HTTP（POST /mcp，application/json 单响应）。
/// M2.5 接缝扩展（ai-app-split.md §3.6~§3.9）：capabilities 增 prompts/resources；
/// tools/call 带 `_meta.progressToken` 时该请求响应升级 SSE 帧流（progress 通知 +
/// keep-alive 心跳夹带帧间 + 终帧 result）——opt-in 协商，无 token 维持单 JSON，
/// 桌面桥与既有客户端零破坏。
/// M3 接缝扩展（ai-app-split.md §3.10~§3.11）：① GET /mcp 开 SSE 下行长连接，
/// 承载 server 主动帧（notifications/resources/updated 订阅推送）；② sampling
/// 反向请求——请求帧夹带在带 progressToken 的 tools/call 响应流内（id 前缀
/// srv_），宿主按 id POST 回响应；两能力均可协商，Tier 2 客户端不受影响。
class McpServer {
  McpServer({required this.repo, required this.tokenProvider, this.instructionsProvider});

  final Repository repo;

  /// 返回当前生效 token；为空表示关闭鉴权。
  final String? Function() tokenProvider;

  /// initialize 返回的 instructions；非空时覆盖内置文案（配置热更入口）。
  final String? Function()? instructionsProvider;

  /// 订阅注册表 + GET SSE 下行通道（§3.10）；公有供测试与 app 侧复用。
  final ResourceSubscriptionHub subscriptions = ResourceSubscriptionHub();

  /// 等待宿主回程响应的反向请求（§3.11）：id → completer。
  final Map<String, Completer<Object?>> _pendingServerRequests = {};
  int _serverReqSeq = 0;

  StreamSubscription<String>? _changesSub;

  static const _builtinInstructions =
      '「拾贝」是用户的日常分享收集器。用 list_items 检索/浏览收集内容（支持关键词与类型过滤），'
      'get_item 读取全文与图片，add_item 可代用户写入文本或链接。';

  HttpServer? _server;
  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  Future<void> start({int port = 8765}) async {
    if (running) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    // 条目变更 → 订阅推送（§3.10）：Repository 唯一写入口的变更事件流，
    // UI 写与 MCP 工具写统一覆盖。
    _changesSub = repo.itemChanges.listen(subscriptions.onItemChanged);
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
    subscriptions.dispose();
    await _changesSub?.cancel();
    _changesSub = null;
    for (final c in _pendingServerRequests.values) {
      if (!c.isCompleted) c.completeError(McpRpcError(errInternal, 'server 正在停止'));
    }
    _pendingServerRequests.clear();
    await server?.close(force: true);
  }

  Future<void> _onRequest(HttpRequest req) async {
    // DNS-rebinding 防护（MCP 规范要求）：浏览器发起的请求必带 Origin，
    // 恶意网页/DNS rebinding 场景借此被拒；桌面客户端（stdio 桥/直连）不带 Origin，不受影响。
    final origin = req.headers.value('origin');
    if (origin != null && !_isAllowedOrigin(origin)) {
      await _safeJson(req, HttpStatus.forbidden, _rpcError(null, errInvalidRequest, 'Origin 不被允许: $origin'));
      return;
    }
    final token = tokenProvider();
    if (token != null && token.isNotEmpty && req.headers.value('x-api-key') != token) {
      await _safeJson(req, HttpStatus.unauthorized, _rpcError(null, -32001, 'X-Api-Key 校验失败（app「MCP 服务」页可查看 token）'));
      return;
    }
    if (req.uri.path != '/mcp') {
      await _safeJson(req, HttpStatus.notFound, _rpcError(null, errInvalidRequest, '未知路径，MCP 端点为 /mcp'));
      return;
    }
    if (req.method == 'GET') {
      // §3.10：GET /mcp 开 SSE 下行长连接，承载 server 主动帧
      // （notifications/resources/updated）。DELETE 仍不支持。
      subscriptions.attach(req);
      return;
    }
    if (req.method != 'POST') {
      await _safeJson(req, HttpStatus.methodNotAllowed,
          _rpcError(null, errInvalidRequest, '仅支持 POST /mcp 与 GET /mcp（SSE 订阅通道）'));
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
    // server→client 反向请求的响应回程（§3.11）：宿主按 id POST 回
    // result/error，按注册表唤醒等待中的工具调用。
    if (method == null && id != null && _pendingServerRequests.containsKey(id)) {
      final completer = _pendingServerRequests.remove(id)!;
      final error = msg['error'];
      if (error is Map<String, Object?>) {
        completer.completeError(McpRpcError(
          (error['code'] as num?)?.toInt() ?? errInternal,
          (error['message'] as String?) ?? '宿主拒绝反向请求',
        ));
      } else {
        completer.complete(msg['result']);
      }
      req.response.statusCode = HttpStatus.accepted;
      await req.response.close();
      return;
    }
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

    // progressToken opt-in（ai-app-split.md §3.9）：带 token 的 tools/call 走
    // SSE 帧流（progress 通知 + keep-alive 心跳夹带帧间 + 终帧 result）；
    // 不带维持单 JSON——桌面桥与既有客户端零破坏。
    if (method == 'tools/call' && _progressTokenOf(msg['params']) != null) {
      await _streamingToolCall(req, id, msg['params']);
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

  /// 取 tools/call params._meta.progressToken（MCP 规范：string 或 number）。
  String? _progressTokenOf(Object? params) {
    if (params is! Map<String, Object?>) return null;
    final meta = params['_meta'];
    if (meta is! Map<String, Object?>) return null;
    final t = meta['progressToken'];
    if (t is String && t.isNotEmpty) return t;
    if (t is num) return '$t';
    return null;
  }

  /// tools/call 的 SSE 帧流响应（ai-app-split.md §3.9）：起始 progress 通知帧 →
  /// 5s keep-alive 心跳 comment 帧（移动网络空闲 TCP 老化保活；与宿主卡死判定
  /// 正交——心跳不重置卡死计时）→ 终帧 result/error。M2.5 只发起始帧这一确定
  /// 进度点，执行中途的进度点随宿主 callTool onProgress 注入通道再扩（T7）。
  /// 错误分层：SSE 起始前参数校验失败走常规 HTTP 错误；起始后工具执行抛错走终帧。
  Future<void> _streamingToolCall(HttpRequest req, Object? id, Object? params) async {
    final p = params is Map<String, Object?> ? params : const <String, Object?>{};
    final name = p['name'];
    final token = _progressTokenOf(params)!;
    if (name is! String || name.isEmpty) {
      await _json(req, HttpStatus.ok, _rpcError(id, errInvalidParams, '缺少 tool name'));
      return;
    }
    final args = p['arguments'] is Map<String, Object?>
        ? p['arguments'] as Map<String, Object?>
        : <String, Object?>{};

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.headers.set('X-Accel-Buffering', 'no');
    // 逐帧即时下发（bufferOutput 默认 true 会攒到关闭一次性发出——中途帧/
    // 心跳/反向请求全靠流内即时性，必须关缓冲）。
    req.response.bufferOutput = false;

    void sseFrame(String payload) => req.response.write('data: $payload\n\n');

    sseFrame(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'notifications/progress',
      'params': {
        'progressToken': token,
        'progress': 0,
        'total': 1,
        'message': '开始执行 $name',
      },
    }));

    final heartbeats = Timer.periodic(const Duration(seconds: 5), (_) {
      req.response.write(': keep-alive\n\n');
    });
    // §3.11：sampling 反向请求帧夹带在本响应流内（仅流式调用有承载通道——
    // 单 JSON 响应无法中途发请求，工具侧对 sampling == null 返回结构化 status）。
    // 反向请求前发一帧真实进度通告（M3-T2 联调中途帧源：宿主卡状态机在推理
    // 等待期有帧可依，卡死判定有「最近帧」可锚）。
    Future<Object?> sampling(Object? sParams) async {
      sseFrame(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': {
          'progressToken': token,
          'progress': 0,
          'total': 1,
          'message': '请求宿主推理中',
        },
      }));
      return _serverRequest('sampling/createMessage', sParams, sseFrame);
    }
    try {
      final content = await callTool(name, args, repo, sampling: sampling);
      sseFrame(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {'content': content, 'isError': false},
      }));
    } on McpRpcError catch (e) {
      sseFrame(jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': e.toMap()}));
    } catch (e) {
      sseFrame(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': McpRpcError(errInternal, '工具执行失败: $e').toMap(),
      }));
    } finally {
      heartbeats.cancel();
      await req.response.close();
    }
  }

  /// server→client 反向请求（§3.11，sampling）：请求帧夹带在当前 tools/call 的
  /// SSE 响应流内（id 前缀 srv_ 防与客户端请求 id 相撞），响应经宿主新 POST
  /// 按 id 唤醒 [completer]。超时抛错由工具侧降级为结构化 status（不 isError
  /// ——宿主不可达是环境态不是工具故障，防宿主熔断误计数）。
  Future<Object?> _serverRequest(
    String method,
    Object? params,
    void Function(String payload) sseFrame,
  ) async {
    final id = 'srv_${++_serverReqSeq}';
    final completer = Completer<Object?>();
    _pendingServerRequests[id] = completer;
    sseFrame(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    try {
      return await completer.future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw McpRpcError(-32003, 'sampling 反向请求超时（宿主未在 90s 内响应）');
    } finally {
      _pendingServerRequests.remove(id);
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
            'prompts': <String, Object?>{},
            'resources': {'subscribe': true},
            'sampling': <String, Object?>{},
          },
          'serverInfo': {'name': 'goodshare', 'version': '1.0.0'},
          'instructions': instructionsProvider?.call() ?? _builtinInstructions,
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
      case 'prompts/list':
        return {'prompts': listPrompts()};
      case 'prompts/get':
        final p = params is Map<String, Object?> ? params : const <String, Object?>{};
        final name = p['name'];
        if (name is! String || name.isEmpty) throw McpRpcError(errInvalidParams, '缺少 prompt name');
        // arguments 字段缺失 = CoW 原文通道（未渲染）；显式传（含空 map）= 渲染态
        final hasArgs = p['arguments'] is Map<String, Object?>;
        final args = hasArgs
            ? p['arguments'] as Map<String, Object?>
            : const <String, Object?>{};
        return getPrompt(name, args, renderArgs: hasArgs);
      case 'resources/list':
        return {'resources': await listResources(repo)};
      case 'resources/read':
        final p = params is Map<String, Object?> ? params : const <String, Object?>{};
        final uri = p['uri'];
        if (uri is! String || uri.isEmpty) throw McpRpcError(errInvalidParams, '缺少资源 uri');
        return {'contents': await readResource(repo, uri)};
      case 'resources/subscribe':
        final p = params is Map<String, Object?> ? params : const <String, Object?>{};
        final uri = p['uri'];
        if (uri is! String || !isValidSubscriptionUri(uri)) {
          throw McpRpcError(errInvalidParams,
              '非法订阅 URI: $uri（支持 goodshare://items 与 goodshare://items/{uuid}）');
        }
        subscriptions.subscribe(uri);
        return <String, Object?>{};
      case 'resources/unsubscribe':
        final p = params is Map<String, Object?> ? params : const <String, Object?>{};
        final uri = p['uri'];
        if (uri is! String) throw McpRpcError(errInvalidParams, '缺少资源 uri');
        subscriptions.unsubscribe(uri);
        return <String, Object?>{};
      default:
        throw McpRpcError(errMethodNotFound, '未知方法: $method');
    }
  }

  /// Binder 入口：裸 JSON-RPC 请求字符串 → 响应字符串（零 HTTP）。
  ///
  /// 供 [McpBinderService] 经 MethodChannel 调用，与 [_onRequest] 同协议语义，
  /// 但**无** Origin 校验 / `X-Api-Key` 鉴权（Binder 侧走同签名 `signature` 权限，
  /// 见 thirdconnect.md §1.2.6）/ 端口；反向请求响应经 [answerReverse] 单独通道回注。
  /// 覆盖：常规请求（initialize/tools/list/tools/call/resources/prompts）、
  /// 通知（id==null，回空 ack）、反向请求响应（method==null 且 id 在途，唤醒 completer）。
  Future<String> handleJsonRpc(String requestJson) async {
    Object? msg;
    try {
      msg = jsonDecode(requestJson);
    } catch (_) {
      return jsonEncode(_rpcError(null, errParse, 'JSON 解析失败'));
    }
    if (msg is! Map<String, Object?>) {
      return jsonEncode(_rpcError(null, errInvalidRequest, '仅支持单条 JSON-RPC 消息'));
    }
    final method = msg['method'];
    final id = msg['id'];
    // 反向请求响应回程（§3.11）：宿主按 id 经 answerReverse 回 result/error，唤醒在途 completer。
    if (method == null && id != null && _pendingServerRequests.containsKey(id)) {
      _completeReverse(id, msg);
      return jsonEncode({'jsonrpc': '2.0', 'id': null, 'result': <String, Object?>{}});
    }
    if (id == null) {
      // 通知（如 notifications/initialized）：无需应答，回空 ack（Binder call 也需返回字符串）。
      return jsonEncode({'jsonrpc': '2.0', 'id': null, 'result': <String, Object?>{}});
    }
    if (method is! String) {
      return jsonEncode(_rpcError(id, errInvalidRequest, '缺少 method'));
    }
    try {
      final result = await _dispatch(method, msg['params']);
      return jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
    } on McpRpcError catch (e) {
      return jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': e.toMap()});
    } catch (e) {
      return jsonEncode(_rpcError(id, errInternal, '工具执行失败: $e'));
    }
  }

  /// 唤醒一个反向请求 completer（[handleJsonRpc] 与 [answerReverse] 共用）。
  void _completeReverse(Object? id, Map<String, Object?> msg) {
    final completer = _pendingServerRequests.remove(id);
    if (completer == null) return;
    final error = msg['error'];
    if (error is Map<String, Object?>) {
      completer.completeError(McpRpcError(
        (error['code'] as num?)?.toInt() ?? errInternal,
        (error['message'] as String?) ?? '宿主拒绝反向请求',
      ));
    } else {
      completer.complete(msg['result']);
    }
  }

  /// Binder 反向请求响应回注（供 [McpBinderService] 'answerReverse' 调用，与 HTTP
  /// 版 `_onRequest` method==null 分支同义）。按 id 关联原请求并唤醒在途 completer。
  void answerReverse(String responseJson) {
    Object? msg;
    try {
      msg = jsonDecode(responseJson);
    } catch (_) {
      return;
    }
    if (msg is! Map<String, Object?>) return;
    final id = msg['id'];
    if (id == null) return;
    if (!_pendingServerRequests.containsKey(id)) return;
    _completeReverse(id, msg);
  }

  /// 仅放行本机来源（localhost / 127.0.0.1 / [::1]，任意端口）。
  /// app 内如出现 WebView 类浏览器客户端需直连时，在此扩展白名单。
  bool _isAllowedOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return false;
    const localHosts = {'localhost', '127.0.0.1', '[::1]', '::1'};
    return localHosts.contains(uri.host.toLowerCase());
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
