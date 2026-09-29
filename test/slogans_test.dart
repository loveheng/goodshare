import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/slogans.dart';
import 'package:goodshare/update/remote_config_store.dart';
import 'package:goodshare/update/update_manifest.dart';

void main() {
  group('slogans', () {
    test('本地默认值按 key 命中', () {
      expect(sloganFor(SloganKeys.splash), contains('收下微小的喜欢'));
      expect(sloganFor(SloganKeys.empty), contains('口袋'));
      expect(sloganFor(SloganKeys.about), contains('安放'));
      expect(sloganFor(SloganKeys.detailFooter), contains('等回应'));
    });

    test('远端覆盖优先，且可部分覆盖（其余 key 回退本地默认）', () {
      RemoteConfigStore.instance.current = const RemoteConfig(
        slogans: {'splash': '远端闪屏句'},
      );
      expect(sloganFor(SloganKeys.splash), '远端闪屏句');
      expect(sloganFor(SloganKeys.about), contains('安放'));

      RemoteConfigStore.instance.current = RemoteConfig.empty;
      expect(sloganFor(SloganKeys.splash), contains('收下微小的喜欢'));
    });
  });

  group('RemoteConfig.slogans', () {
    test('fromJson 解析 slogans map', () {
      final c = RemoteConfig.fromJson({
        'slogans': {'splash': 'x', 'about': 'y'},
      });
      expect(c.slogans, {'splash': 'x', 'about': 'y'});
    });

    test('缺省 slogans 为 null', () {
      expect(RemoteConfig.fromJson(const {}).slogans, isNull);
    });

    test('RemoteConfigStore 持久化 slogans（save → load 往返）', () async {
      final dir = await Directory.systemTemp.createTemp('goodshare-slogan-test');
      final store = RemoteConfigStore.instance;
      await store.save(const RemoteConfig(slogans: {'about': '远端关于句'}), dir: dir);
      await store.load(dir: dir);
      expect(store.current.slogans, {'about': '远端关于句'});
      await dir.delete(recursive: true);
    });
  });
}
