import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/audio_playback_service.dart';
import 'package:goodshare/ui/content_body.dart';

/// 播放服务单实例红线验收（rich-text-media.md §7）。
///
/// `AudioPlayer` 依赖收敛在 [AudioPlayerHandle] 接口后，测试注入 fake：
/// 架构上控制器只持有一个句柄，块 widget 只订阅——本组用例验证「同页两个
/// AudioBlock 先后播放互斥」与「release（滑出视野 dispose）自动暂停」。
class _FakeHandle implements AudioPlayerHandle {
  final calls = <String>[];
  bool playing = false;
  final _playingCtrl = StreamController<bool>.broadcast();

  @override
  Future<Duration?> load(String source) async {
    calls.add('load:$source');
    return const Duration(seconds: 3);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
    _playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
    _playingCtrl.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<Duration?> probeDuration(String source) async => const Duration(seconds: 3);

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

Future<AudioPlaybackController> _pumpTwoBlocks(WidgetTester tester) async {
  final handle = _FakeHandle();
  final controller = AudioPlaybackController(handle: handle);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AudioPlaybackService(
        controller: controller,
        child: SingleChildScrollView(
          child: ContentBody(
            markdown: '[甲](https://x/a.mp3)\n\n[乙](https://x/b.mp3)',
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('同页两个 AudioBlock：先后播放互斥，切换自动停前一个', (tester) async {
    await _pumpTwoBlocks(tester);

    // 初始：两条都是 play 图标
    expect(find.byIcon(Icons.play_arrow), findsNWidgets(2));

    // 点第一条 → 变 pause，另一条保持 play
    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    // 点第二条 → 互斥切换：第二条 pause，第一条回 play
    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    // 单实例：两次播放都走同一个句柄（fake 由测试注入且仅此一个），切换后仍有 active 块
    final controller = tester
        .widget<AudioPlaybackService>(find.byType(AudioPlaybackService))
        .controller;
    expect(controller.activeBlockId, isNotNull);
  });

  testWidgets('release（块滑出视野 dispose）自动暂停当前播放', (tester) async {
    final handle = _FakeHandle();
    final controller = AudioPlaybackController(handle: handle);
    controller.activeBlockId = 'blk-1';
    await controller.toggle('blk-1', 'https://x/a.mp3');
    expect(handle.playing, isTrue);

    controller.release('blk-1');
    expect(handle.calls.last, 'pause');
    expect(controller.isActive('blk-1'), isFalse);
    expect(controller.playing, isFalse);
  });

  testWidgets('加载失败不抛红屏：错误态落在 active 块上', (tester) async {
    final controller = AudioPlaybackController(handle: _ThrowingHandle());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AudioPlaybackService(
          controller: controller,
          child: const SingleChildScrollView(
            child: ContentBody(markdown: '[甲](https://x/a.mp3)'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await tester.pump();
    expect(find.text('音频加载失败'), findsOneWidget);
    // 无 uncaught exception 即通过（三态硬规则）
  });

  testWidgets('后缀降级档（.amr）：渲染静态文件卡，不出现播放按钮', (tester) async {
    final controller = AudioPlaybackController(handle: _FakeHandle());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AudioPlaybackService(
          controller: controller,
          child: const SingleChildScrollView(
            child: ContentBody(markdown: '[录音](https://x/r.amr)'),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.textContaining('暂不支持内嵌播放'), findsOneWidget);
  });
}

class _ThrowingHandle implements AudioPlayerHandle {
  @override
  Future<Duration?> load(String source) async => throw const FormatException('no net');

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<Duration?> probeDuration(String source) async => Duration.zero;

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<bool> get playingStream => const Stream.empty();

  @override
  void disposeHandle() {}
}
