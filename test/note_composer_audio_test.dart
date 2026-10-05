import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/audio_playback_service.dart';
import 'package:goodshare/ui/media_blocks.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 作曲器音频卡手势口径回归（2026-10-04 用户拍板）。
///
/// 原行为「点音频卡 = 重录」：录完想回放确认，一点就把刚录的推倒重来——
/// 点按归**播放**，重录与图/视频统一走**长按**。本组用例钉住这两条，
/// 顺带冒烟紧凑卡布局（64dp 定高内塞下播放行 + 进度条不溢出）。
class _FakeHandle implements AudioPlayerHandle {
  final calls = <String>[];
  final _playingCtrl = StreamController<bool>.broadcast();

  @override
  Future<Duration?> load(String source) async {
    calls.add('load:$source');
    return const Duration(seconds: 3);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playingCtrl.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<Duration?> probeDuration(String source) async =>
      const Duration(seconds: 3);

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  void disposeHandle() {
    calls.add('dispose');
    unawaited(_playingCtrl.close());
  }
}

void main() {
  late Directory tmp;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('composer_audio_test');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<_Fixture> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final file = File('${tmp.path}/r.m4a')..writeAsBytesSync(<int>[0, 1, 2]);
    final handle = _FakeHandle();
    final controller = AudioPlaybackController(handle: handle);
    var replaceCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          // 宿主必给有界高度：作曲层 ListView + 音频卡 expandBody 都靠它
          height: 600,
          child: NoteComposerEditor(
            initialRows: <List<String>>[
              <String>['a', file.path, '录音'],
            ],
            audioController: controller,
            onMediaReplace: (seg) async => replaceCalls++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return _Fixture(
      handle: handle,
      controller: controller,
      replaceCalls: () => replaceCalls,
    );
  }

  testWidgets('点按音频卡 = 播放（不再重录）', (tester) async {
    final fx = await pump(tester);
    expect(find.byType(MediaAudioBar), findsOneWidget);

    await tester.tap(find.byType(MediaAudioBar));
    // 播放态有常驻进度 Ticker（逐帧刷新进度条，产品语义正确）——不能
    // pumpAndSettle（常驻帧永挂超时），用有界 pump 推进链路
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(fx.handle.calls.any((c) => c.startsWith('load:')), isTrue,
        reason: '点按必须进播放链路（加载音源）');
    expect(fx.handle.calls.contains('play'), isTrue);
    expect(fx.controller.playing, isTrue);
    expect(fx.replaceCalls(), 0, reason: '点按不得触发替换/重录钩子');
    // 播放态细进度条塞进 64dp 定高卡不溢出（紧凑档布局冒烟）
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按音频卡 = 重录（与图/视频同口径）', (tester) async {
    final fx = await pump(tester);

    await tester.longPress(find.byType(MediaAudioBar));
    await tester.pumpAndSettle();

    expect(fx.replaceCalls(), 1, reason: '长按走 onMediaReplace 钩子');
    expect(fx.handle.calls.contains('play'), isFalse,
        reason: '长按不得顺带起播');
  });
}

class _Fixture {
  _Fixture({
    required this.handle,
    required this.controller,
    required this.replaceCalls,
  });

  final _FakeHandle handle;
  final AudioPlaybackController controller;
  final int Function() replaceCalls;
}
