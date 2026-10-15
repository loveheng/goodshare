import 'dart:convert';

/// 远程下发的功能配置（随 update.json 的 config 段）。
class RemoteConfig {
  const RemoteConfig({
    this.announcement,
    this.announcementId,
    this.mcpInstructions,
    this.flags = const {},
    this.slogans,
  });

  factory RemoteConfig.fromJson(Map<String, Object?> json) => RemoteConfig(
        announcement: json['announcement'] as String?,
        announcementId: json['announcementId'] as String?,
        mcpInstructions: json['mcpInstructions'] as String?,
        flags: (json['flags'] as Map?)?.cast<String, Object?>() ?? const {},
        slogans: (json['slogans'] as Map?)?.cast<String, String>(),
      );

  static const empty = RemoteConfig();

  final String? announcement;
  final String? announcementId;

  /// 非空时覆盖 MCP initialize 返回的 instructions（配置热更入口）
  final String? mcpInstructions;
  final Map<String, Object?> flags;

  /// 文青风口号（按落点 key 覆盖本地默认值，缺省回退本地默认；详见 lib/ui/slogans.dart）
  final Map<String, String>? slogans;
}

/// 更新清单：自更新 + 配置热更共用一份 update.json。
/// 托管格式见 docs/guide/self-update.md。
class UpdateManifest {
  const UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.sha256,
    this.changelog,
    this.applicationId,
    this.config = RemoteConfig.empty,
  });

  factory UpdateManifest.fromJson(Map<String, Object?> json) {
    final versionCode = json['versionCode'];
    final versionName = json['versionName'];
    final apkUrl = json['apkUrl'];
    if (versionCode is! int) {
      throw const FormatException('versionCode 必须是整数');
    }
    if (versionName is! String || apkUrl is! String) {
      throw const FormatException('versionName / apkUrl 缺失或类型错误');
    }
    return UpdateManifest(
      versionCode: versionCode,
      versionName: versionName,
      apkUrl: apkUrl,
      sha256: json['sha256'] as String?,
      applicationId: json['applicationId'] as String?,
      changelog: json['changelog'] as String?,
      config: json['config'] is Map<String, Object?>
          ? RemoteConfig.fromJson(json['config'] as Map<String, Object?>)
          : RemoteConfig.empty,
    );
  }

  factory UpdateManifest.parse(String raw) =>
      UpdateManifest.fromJson(jsonDecode(raw) as Map<String, Object?>);

  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String? sha256;
  final String? changelog;

  /// 清单声明归属的应用（Android applicationId）。
  /// `release-r2.sh` 发布时自动写入；旧格式清单无此字段（null）。
  /// 多 app 共用同一更新托管（如同一个 R2 桶）时，客户端据此识别「源指错了」。
  final String? applicationId;
  final RemoteConfig config;

  bool isNewerThan(int currentVersionCode) => versionCode > currentVersionCode;

  /// 身份一致性（防串包/串配置）：[currentApplicationId] 为当前应用的包名。
  /// 任一侧缺失（旧清单未声明 / 调用方未知当前身份）时放行——向后兼容；
  /// 双方都非空且不一致 → false，调用方必须拒用该清单（含其 config 段）。
  bool matchesApplication(String? currentApplicationId) {
    final declared = applicationId;
    if (declared == null || declared.isEmpty) return true;
    if (currentApplicationId == null || currentApplicationId.isEmpty) return true;
    return declared == currentApplicationId;
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
