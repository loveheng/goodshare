import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'update_manifest.dart';

/// 远程配置的本地缓存：启动时读缓存，检查更新成功后写缓存。
/// MCP instructions 等配置热更项从这里取值。
class RemoteConfigStore {
  RemoteConfigStore._();

  static final RemoteConfigStore instance = RemoteConfigStore._();

  RemoteConfig current = RemoteConfig.empty;

  /// [dir] 供测试注入。
  Future<void> load({Directory? dir}) async {
    try {
      final file = await _cacheFile(dir);
      if (!await file.exists()) return;
      current = RemoteConfig.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, Object?>,
      );
    } catch (_) {
      // 缓存损坏时回到空配置，等下次检查更新重建
      current = RemoteConfig.empty;
    }
  }

  Future<void> save(RemoteConfig config, {Directory? dir}) async {
    current = config;
    final file = await _cacheFile(dir);
    await file.writeAsString(jsonEncode({
      if (config.announcement != null) 'announcement': config.announcement,
      if (config.announcementId != null) 'announcementId': config.announcementId,
      if (config.mcpInstructions != null) 'mcpInstructions': config.mcpInstructions,
      if (config.flags.isNotEmpty) 'flags': config.flags,
      if (config.slogans != null && config.slogans!.isNotEmpty) 'slogans': config.slogans,
    }));
  }

  Future<File> _cacheFile(Directory? dir) async {
    final base = dir?.path ?? (await getApplicationDocumentsDirectory()).path;
    return File('$base/remote_config.json');
  }
}
