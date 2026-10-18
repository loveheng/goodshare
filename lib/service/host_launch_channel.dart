import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// goodhub 宿主包名（跨仓常量族，ai-app-split.md §3.12.3：与 Binder 服务发现
/// action、`MCP_SERVER` 签名权限同源，包名变更时两端同轮改）。
const String kGoodhubPackage = 'com.zzh.goodhub';

/// 一键唤醒 goodhub（§3.12.3 形态 B·一键唤醒）。
///
/// Flutter 侧无 PackageManager 访问能力，故经 MethodChannel 由原生侧执行
/// `getLaunchIntentForPackage` + `FLAG_ACTIVITY_NEW_TASK` 直达拉起。
///
/// **包可见性前置（易漏）**：Android 11+ 仅有 `<queries><intent>` 不足以让该
/// 包名可见——必须在 Manifest `<queries>` 补 `<package android:name="..."/>`，
/// 否则 `getLaunchIntentForPackage` 恒返回 null（已装也误判「未安装」）。
///
/// 返回是否已拉起；false = 未安装或拉起失败，由上层给「未检测到 Goodhub 安装包」
/// 兜底提示。平台缺失 / 异常按 DEGRADE 记日志并返回 **false**——宁可不给出出口，
/// 也不误报成功（正确性始终由宿主侧 catch-up 兜底，§3.12.4）。
class HostLaunchChannel {
  static const _channel = MethodChannel('goodshare/host_launch');

  Future<bool> launchGoodhub() async {
    try {
      return await _channel.invokeMethod<bool>('launchGoodhub') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[DEGRADE] host_launch_failed code=${e.code}');
      return false;
    } on MissingPluginException {
      debugPrint('[DEGRADE] host_launch_channel_missing（非 Android / 未注册通道）');
      return false;
    }
  }
}
