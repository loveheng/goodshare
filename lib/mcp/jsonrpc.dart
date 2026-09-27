/// JSON-RPC 2.0 / MCP 协议常量与小工具。
/// 参考：MCP 规范 2025-06-18（Streamable HTTP），兼容 2025-03-26。
class McpProtocol {
  static const latestVersion = '2025-06-18';
  static const supportedVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

  /// 客户端请求版本在支持列表内则原样回显，否则回我们最新版（规范要求的行为）。
  static String negotiate(Object? requested) {
    final v = requested is String ? requested : null;
    return (v != null && supportedVersions.contains(v)) ? v : latestVersion;
  }
}

class McpRpcError implements Exception {
  McpRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  Map<String, Object?> toMap() => {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      };
}

/// JSON-RPC 错误码
const errParse = -32700;
const errInvalidRequest = -32600;
const errMethodNotFound = -32601;
const errInvalidParams = -32602;
const errInternal = -32603;

bool isNotification(Map<String, Object?> m) =>
    m['id'] == null && m['method'] is String;
