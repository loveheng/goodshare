import 'package:flutter/services.dart';

import 'package:flutter/foundation.dart';

/// 附件 URI 平台桥：摄入时对 content:// 尝试持久化读权限。
///
/// takePersistableUriPermission 要求源 app 分享时授予
/// FLAG_GRANT_PERSISTABLE_URI_PERMISSION——多数分享方（系统相册/文件管理器）
/// 会授，未授时返回 false（SecurityException / IllegalArgumentException 均吞为
/// 失败留痕），条目仍为 ref，由迁移清单页兜底转 owned。
/// 非.content:// 路径（file:// 绝对路径、iOS 等无此机制）无需持久化，返回 true。
class AttachUriChannel {
  static const _channel = MethodChannel('goodshare/attach');

  /// 尝试持久化 URI 读权限。返回是否生效（或本就无需持久化）。
  Future<bool> persistUri(String uriOrPath) async {
    if (!uriOrPath.startsWith('content://')) return true;
    try {
      return await _channel.invokeMethod<bool>('persistUri', uriOrPath) ?? false;
    } on PlatformException catch (e) {
      debugPrint('[DEGRADE] attach_persist_uri_failed uri=$uriOrPath error=${e.code}');
      return false;
    } on MissingPluginException {
      debugPrint('[DEGRADE] attach_channel_missing uri=$uriOrPath');
      return false;
    }
  }
}
