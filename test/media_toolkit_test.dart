import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/audio_extract.dart';
import 'package:goodshare/media/media_toolkit.dart';

void main() {
  group('audioCodecNameFromMime', () {
    test('已知 MIME 归一为 ffmpeg 风格 codec 名', () {
      expect(audioCodecNameFromMime('audio/mp4a-latm'), 'aac');
      expect(audioCodecNameFromMime('audio/mpeg'), 'mp3');
      expect(audioCodecNameFromMime('audio/opus'), 'opus');
      expect(audioCodecNameFromMime('audio/vorbis'), 'vorbis');
      expect(audioCodecNameFromMime('audio/flac'), 'flac');
      expect(audioCodecNameFromMime('audio/alac'), 'alac');
      expect(audioCodecNameFromMime('audio/raw'), 'pcm_s16le');
    });

    test('大小写不敏感', () {
      expect(audioCodecNameFromMime('AUDIO/MPEG'), 'mp3');
    });

    test('未知 MIME 原样透传（保持「音轨存在」语义，容器选择走默认分支）', () {
      expect(audioCodecNameFromMime('audio/amr-nb'), 'audio/amr-nb');
      expect(audioCodecNameFromMime('audio/ac3'), 'audio/ac3');
    });

    test('归一结果与 extensionForCodec 配套（aac/mp3/opus/vorbis/flac/wav 有专容器）', () {
      // 媥译性回归：extensionForCodec 的入参域由本函数供给，两个 SSOT 不能漂移
      expect(extensionForCodec(audioCodecNameFromMime('audio/mp4a-latm')), 'm4a');
      expect(extensionForCodec(audioCodecNameFromMime('audio/mpeg')), 'mp3');
      expect(extensionForCodec(audioCodecNameFromMime('audio/opus')), 'ogg');
      expect(extensionForCodec(audioCodecNameFromMime('audio/flac')), 'flac');
    });
  });

  group('MethodChannelMediaToolkit', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('无平台实现（iOS 未适配/测试环境）→ null 降级', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('goodshare/media'),
            null,
          );
      final tk = MethodChannelMediaToolkit();
      expect(await tk.videoDurationMs('/x/a.mp4'), isNull);
      expect(await tk.audioCodec('/x/a.mp4'), isNull);
    });

    test('正常回传：时长 int / 编码 String', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('goodshare/media'),
            (call) async => switch (call.method) {
              'videoDurationMs' => 61234,
              'audioCodec' => 'audio/mp4a-latm',
              _ => null,
            },
          );
      final tk = MethodChannelMediaToolkit();
      expect(await tk.videoDurationMs('/x/a.mp4'), 61234);
      expect(await tk.audioCodec('/x/a.mp4'), 'audio/mp4a-latm');
    });

    test('videoCover：JPEG 字节透传 / 异常与无实现 → null（封面非阻断契约）', () async {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('goodshare/media'),
            (call) async => switch (call.method) {
              'videoCover' => jpeg,
              _ => null,
            },
          );
      final tk = MethodChannelMediaToolkit();
      expect(await tk.videoCover('/x/a.mp4'), jpeg);
      // 无实现 → null（MissingPluginException 同径）
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('goodshare/media'),
            null,
          );
      expect(await tk.videoCover('/x/a.mp4'), isNull);
    });

    test('PlatformException → null（契约：探测失败非阻断）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('goodshare/media'),
            (call) async => throw PlatformException(code: 'boom'),
          );
      final tk = MethodChannelMediaToolkit();
      expect(await tk.videoDurationMs('/x/a.mp4'), isNull);
      expect(await tk.audioCodec('/x/a.mp4'), isNull);
    });

    test('trimVideo：正常回传 bytes / 非法回包与异常 → null（P3）', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final tk = MethodChannelMediaToolkit();

      messenger.setMockMethodCallHandler(
        const MethodChannel('goodshare/media'),
        (call) async {
          expect(call.method, 'trimVideo');
          expect((call.arguments as Map)['startMs'], 1500);
          expect((call.arguments as Map)['endMs'], 62000);
          return {'bytes': 1048576};
        },
      );
      final r =
          await tk.trimVideo('/x/v.mp4', '/x/clip.mp4', startMs: 1500, endMs: 62000);
      expect(r!.bytes, 1048576);

      messenger.setMockMethodCallHandler(
          const MethodChannel('goodshare/media'), (call) async => 'garbage');
      expect(
        await tk.trimVideo('/x/v.mp4', '/x/clip.mp4', startMs: 0, endMs: 1000),
        isNull,
      );

      messenger.setMockMethodCallHandler(
        const MethodChannel('goodshare/media'),
        (call) async => throw PlatformException(code: 'boom'),
      );
      expect(
        await tk.trimVideo('/x/v.mp4', '/x/clip.mp4', startMs: 0, endMs: 1000),
        isNull,
      );
    });
  });
}
