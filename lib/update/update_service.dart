import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_manifest.dart';

/// 自更新 + 配置热更服务：一个可配置的静态源（gitee/github raw、任意静态托管）
/// 放一份 goodshare-update.json，app 检查/下载/校验全在这里完成。
/// 编译期注入的默认更新源（构建时 --dart-define=UPDATE_SOURCE_URL=...）。
/// 非空时，用户未手动配置即自动采用，实现「装上即可检查更新」。
const String kDefaultUpdateSourceUrl =
    String.fromEnvironment('UPDATE_SOURCE_URL', defaultValue: '');

class UpdateService {
  UpdateService(
    this._prefs, {
    this.defaultSourceUrl = kDefaultUpdateSourceUrl,
    this.applicationId,
  });

  final SharedPreferences _prefs;
  final String defaultSourceUrl;

  /// 当前应用的 applicationId（包名，来自 PackageInfo.packageName）。
  /// 非空时启用「串包防线」：清单声明的 applicationId 与之不一致，
  /// 直接拒检 / 拒下 / 拒装——防的是源地址指错到别的 app 时，
  /// 下载安装来路不明的包、或把别人的公告/MCP 指令当自己的配置应用。
  final String? applicationId;

  static const _prefSourceUrl = 'update_source_url';
  static const manifestFileName = 'goodshare-update.json';

  /// 当前更新源：优先用户手动保存值，否则回退编译期内置默认源。
  Future<String?> sourceUrl() async {
    final saved = _prefs.getString(_prefSourceUrl);
    if (saved != null && saved.isNotEmpty) return saved;
    return defaultSourceUrl.isEmpty ? null : defaultSourceUrl;
  }

  Future<void> setSourceUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      await _prefs.remove(_prefSourceUrl);
      return;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
      throw const UpdateException('更新源必须是合法的 http(s) URL');
    }
    await _prefs.setString(_prefSourceUrl, trimmed);
  }

  Uri manifestUri(String sourceUrl) {
    final base = sourceUrl.endsWith('/') ? sourceUrl : '$sourceUrl/';
    return Uri.parse('$base$manifestFileName');
  }

  /// 拉取最新清单；源未配置或网络异常抛 UpdateException。
  Future<UpdateManifest> check() async {
    final source = await sourceUrl();
    if (source == null || source.isEmpty) {
      throw const UpdateException('尚未配置更新源');
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(manifestUri(source));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw UpdateException('清单拉取失败：HTTP ${res.statusCode}');
      }
      final body = await utf8.decoder.bind(res).join();
      final manifest = UpdateManifest.parse(body);
      _ensureSameApplication(manifest.applicationId);
      return manifest;
    } on FormatException catch (e) {
      throw UpdateException('清单格式错误：${e.message}');
    } on UpdateException {
      rethrow;
    } catch (e) {
      throw UpdateException('网络异常：$e');
    } finally {
      client.close();
    }
  }

  /// 串包防线：清单声明身份（[declaredApplicationId]）与当前应用包名不一致时拒绝。
  /// 任一侧缺失（旧清单未声明 / 未注入当前身份）时放行——向后兼容，
  /// 由 sha256 完整性校验继续兜底。
  void _ensureSameApplication(String? declaredApplicationId) {
    final current = applicationId;
    if (declaredApplicationId == null || declaredApplicationId.isEmpty) return;
    if (current == null || current.isEmpty) return;
    if (declaredApplicationId != current) {
      throw UpdateException(
        '更新源指向其他应用（$declaredApplicationId），与当前应用（$current）不一致，已拒绝；请检查更新源地址',
      );
    }
  }

  /// 流式下载 APK，边下边算 sha256；[manifest.sha256] 非空时下载完成即校验。
  /// 返回落盘文件；[to] 主要供测试注入临时目录。
  Future<File> downloadApk(
    String url, {
    String? expectedSha256,
    String? expectedApplicationId,
    void Function(int received, int? total)? onProgress,
    Directory? to,
  }) async {
    _ensureSameApplication(expectedApplicationId);
    final dir = to ?? Directory('${(await getApplicationDocumentsDirectory()).path}/updates');
    await dir.create(recursive: true);
    final dest = File('${dir.path}/update.apk.part');
    final client = HttpClient();
    final digestSink = _DigestSink();
    final hasher = crypto.sha256.startChunkedConversion(digestSink);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw UpdateException('APK 下载失败：HTTP ${res.statusCode}');
      }
      final total = res.contentLength > 0 ? res.contentLength : null;
      var received = 0;
      final sink = dest.openWrite();
      try {
        await for (final chunk in res) {
          hasher.add(chunk);
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      hasher.close();
      final digest = digestSink.digest!.toString();
      if (expectedSha256 != null && expectedSha256.toLowerCase() != digest) {
        await dest.delete();
        throw const UpdateException('SHA-256 校验失败，安装包可能被篡改或下载不完整');
      }

      final finalPath = '${dir.path}/update-${DateTime.now().millisecondsSinceEpoch}.apk';
      return await dest.rename(finalPath);
    } on UpdateException {
      rethrow;
    } catch (e) {
      throw UpdateException('下载异常：$e');
    } finally {
      client.close();
    }
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest d) => digest = d;

  @override
  void close() {}
}
