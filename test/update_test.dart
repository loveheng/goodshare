import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/update/remote_config_store.dart';
import 'package:goodshare/update/update_manifest.dart';
import 'package:goodshare/update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('UpdateManifest', () {
    test('解析 / 版本比较 / config 段', () {
      final m = UpdateManifest.parse(
        '{"versionCode":3,"versionName":"1.1.0","apkUrl":"https://x/y.apk",'
        '"sha256":"ab","changelog":"修复文本分享","config":{"announcement":"欢迎","mcpInstructions":"新指令"}}',
      );
      expect(m.versionCode, 3);
      expect(m.apkUrl, 'https://x/y.apk');
      expect(m.config.announcement, '欢迎');
      expect(m.config.mcpInstructions, '新指令');
      expect(m.isNewerThan(2), isTrue);
      expect(m.isNewerThan(3), isFalse);
    });

    test('非法清单抛 FormatException', () {
      expect(() => UpdateManifest.parse('{"versionName":"x"}'), throwsFormatException);
      expect(() => UpdateManifest.parse('not json'), throwsA(isA<Object>()));
    });
  });

  test('下载 APK + sha256 校验（本地 HttpServer 流式）', () async {
    SharedPreferences.setMockInitialValues({});
    final bytes = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    final digest = crypto.sha256.convert(bytes).toString();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.contentLength = bytes.length;
      req.response.add(bytes);
      await req.response.close();
    });

    final service = UpdateService(await SharedPreferences.getInstance());
    final dir = await Directory.systemTemp.createTemp('goodshare-update-test');

    final file = await service.downloadApk(
      'http://127.0.0.1:${server.port}/app.apk',
      expectedSha256: digest,
      to: dir,
    );
    expect(await file.length(), bytes.length);
    expect(file.path.endsWith('.apk'), isTrue);

    var progressSeen = false;
    await service.downloadApk(
      'http://127.0.0.1:${server.port}/app.apk',
      expectedSha256: digest,
      to: dir,
      onProgress: (received, total) {
        if (total == bytes.length) progressSeen = true;
      },
    );
    expect(progressSeen, isTrue, reason: '应能收到带总量的进度回调');

    await expectLater(
      service.downloadApk(
        'http://127.0.0.1:${server.port}/app.apk',
        expectedSha256: 'deadbeef',
        to: dir,
      ),
      throwsA(isA<UpdateException>()),
      reason: 'sha 不匹配必须拒绝安装',
    );

    await dir.delete(recursive: true);
    await server.close(force: true);
  });

  test('RemoteConfigStore 缓存读写', () async {
    final dir = await Directory.systemTemp.createTemp('goodshare-config-test');
    final store = RemoteConfigStore.instance;
    await store.save(
      const RemoteConfig(announcement: '公告A', announcementId: 'a1', mcpInstructions: 'instr'),
      dir: dir,
    );
    expect(store.current.announcement, '公告A');

    // 新实例（模拟重启）从缓存恢复
    await store.load(dir: dir);
    expect(store.current.mcpInstructions, 'instr');
    expect(store.current.flags, isEmpty);

    await dir.delete(recursive: true);
  });
}
