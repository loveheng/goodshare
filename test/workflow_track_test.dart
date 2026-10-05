import 'package:flutter_test/flutter_test.dart';
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
}
