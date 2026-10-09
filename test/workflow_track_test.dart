import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/capability.dart' show BlockKind;
import 'package:goodshare/ai/workflow.dart' show workflowFor;
import 'package:goodshare/data/block_artifacts.dart' show BlockArtifactKind;
import 'package:goodshare/ui/workflow_track.dart';

/// 工作流轨纯函数护栏（§4 三段式卡头）：耗时文案分档与视图模型默认值。
/// 纯 Dart，不碰 sqlite / 插件通道（dev-loop R5：widget 测试才受 FakeAsync 约束）。
void main() {
  group('formatElapsed（§4 卡头耗时）', () {
    test('未记录 → null：卡头整段缺席，不编造「0s」', () {
      expect(formatElapsed(null), isNull);
      expect(formatElapsed(-1), isNull);
    });

    test('分档：ms / 一位小数秒 / 整秒 / m:ss', () {
      expect(formatElapsed(0), '0ms');
      expect(formatElapsed(942), '942ms');
      expect(formatElapsed(1000), '1.0s');
      expect(formatElapsed(9400), '9.4s');
      expect(formatElapsed(12500), '13s');
      expect(formatElapsed(185000), '3:05');
    });
  });

  test('BlockArtifactsView.empty 全空（未装载产物时不给默认耗时）', () {
    expect(BlockArtifactsView.empty.kinds, isEmpty);
    expect(BlockArtifactsView.empty.text, isEmpty);
    expect(BlockArtifactsView.empty.meta, isEmpty);
    expect(BlockArtifactsView.empty.filePath, isEmpty);
    expect(BlockArtifactsView.empty.elapsedMs, isEmpty);
  });

  group('无产出原因展示（R1 同一份状态，2026-10-08）', () {
    Widget trackReturning((bool, String?) result,
        {Set<String> existingKinds = const {BlockArtifactKind.audioFile}}) {
      final stepIds = <String>[];
      return MaterialApp(
        home: Scaffold(
          body: WorkflowTrack(
            spec: workflowFor(BlockKind.video),
            existingKinds: existingKinds,
            sourceKind: null,
            onSourceKindChanged: (_) {},
            onRunStep: (step, _) async {
              stepIds.add(step.id);
              return result;
            },
          ),
        ),
      );
    }

    testWidgets('completed 无产物：note 红字展示 + 重试入口', (tester) async {
      const note = '未识别出任何语音内容：音频可能无语音、音量过低';
      await tester.pumpWidget(trackReturning((false, note)));
      // 视频 spec：extract_audio 已有产物（done），仅 transcribe 行出「开始」
      await tester.tap(find.text('开始'));
      await tester.pump(); // 执行中
      await tester.pump(const Duration(milliseconds: 50)); // onRunStep 落定
      expect(find.text(note), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('开始'), findsNothing); // 失败后该行为「重试」
    });

    testWidgets('note 为空：回退通用文案「未产出结果，可重试」', (tester) async {
      await tester.pumpWidget(trackReturning((false, null)));
      await tester.tap(find.text('开始'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('未产出结果，可重试'), findsOneWidget);
    });
  });
}
