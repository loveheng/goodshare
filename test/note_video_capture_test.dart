import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_video_capture_page.dart';

/// 便签视频直拍页回归（2026-10-01 自建拍摄页＋进度环拍板）：
/// ①无平台实现时错误态可渲染、可重试（权限拒绝同路径）
/// ②录制中进度环 + 60s 到点自动停 + 文件路径 pop 回调用方。
class _FakeCameraPlatform extends CameraPlatform {
  final stoppedCalls = ValueNotifier<int>(0);

  final _orientation = StreamController<DeviceOrientationChangedEvent>.broadcast();
  final _initialized = StreamController<CameraInitializedEvent>.broadcast();
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
        CameraDescription(
            name: '0',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 0),
      ];

  @override
  Future<int> createCameraWithSettings(
          CameraDescription description, MediaSettings mediaSettings) async =>
      1;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      _orientation.stream;

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream;

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    // controller.initialize 等 onCameraInitialized 首个事件完成，补发之
    scheduleMicrotask(() => _initialized.add(CameraInitializedEvent(
        cameraId, 1920, 1080, ExposureMode.auto, true, FocusMode.auto, true)));
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {}

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stoppedCalls.value++;
    return XFile('/tmp/fake_capture.mp4');
  }

  @override
  Future<void> dispose(int cameraId) async {}

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand();
}

void main() {
  /// 相机平台通道的响应在 FakeAsync 区推不完（与 sqflite_ffi 同类问题），
  /// 统一走「runAsync 放行真实时钟 → pump 推进微任务」交替直至条件满足。
  Future<void> driveUntil(WidgetTester tester, bool Function() ready,
      {int maxRounds = 40}) async {
    for (var i = 0; i < maxRounds && !ready(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('无平台实现：渲染错误态 + 重试按钮，不崩溃', (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => FilledButton(
          onPressed: () async {
            result = await NoteVideoCapturePage.push(ctx,
                maxDuration: const Duration(seconds: 60));
          },
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await driveUntil(tester, () =>
        find.textContaining('相机启动失败').evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('相机启动失败'), findsOneWidget,
        reason: '启动失败要给用户可感知文案（R1）');
    expect(find.text('重试'), findsOneWidget);
    // 错误态关掉不带回路径
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('直拍闭环：快门启动 → 进度环 → 60s 到点自动停 → 回传文件路径',
      (tester) async {
    final fake = _FakeCameraPlatform();
    final original = CameraPlatform.instance;
    CameraPlatform.instance = fake;
    addTearDown(() => CameraPlatform.instance = original);

    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => FilledButton(
          onPressed: () async {
            result = await NoteVideoCapturePage.push(ctx,
                maxDuration: const Duration(seconds: 60));
          },
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await driveUntil(tester, () =>
        find.byKey(const ValueKey('note_video_shutter')).evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.stop), findsNothing, reason: '未录时快门不是停止态');

    await tester.tap(find.byKey(const ValueKey('note_video_shutter')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.stop), findsOneWidget, reason: '录制中快门变停止方块');
    // 倒计时文案按用户拍板移除（2026-10-01）：进度环是时间的唯一表达
    expect(find.textContaining('剩余'), findsNothing,
        reason: '录制中不显示倒计时文案');

    // 假时钟推进 60s：100ms ticker 触发到点自动停
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(fake.stoppedCalls.value, 1, reason: '到点自动停只调一次 stopVideoRecording');
    expect(result, '/tmp/fake_capture.mp4', reason: '文件路径回传作曲器走门槛链');
  });
}
