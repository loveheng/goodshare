import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/models/annotation.dart';
import 'package:goodshare/ui/image_annotator.dart' show ImageAnnotator;

/// AnnotationStore 契约（2026-10-04 真机回归：load 返回 const [] 时首条
/// 标注 add 崩「Cannot add to an unmodifiable list」——标注在无文件条目上
/// 从未成功写入过）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsRoot;
  setUpAll(() async {
    docsRoot = await Directory.systemTemp.createTemp('anno_store_docs');
  });
  tearDownAll(() => docsRoot.deleteSync(recursive: true));

  setUp(() {
    // 测试环境无平台通道：path_provider 落固定临时目录（同一次写读须同目录）
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => docsRoot.path);
  });

  Annotation ann(String id) => Annotation(
    id: id,
    type: AnnotationType.rect,
    points: const [NormPoint(0.1, 0.1), NormPoint(0.4, 0.4)],
  );

  test('空存储 load 返回可变列表：首条 add 不崩且落盘可读回', () async {
    const itemId = 'store-t1';
    final list = await AnnotationStore.load(itemId);
    expect(list, isEmpty);
    list.add(ann('a1')); // 不可变列表会在此抛 Unsupported operation

    await AnnotationStore.add(itemId, ann('a2'));
    final reloaded = await AnnotationStore.load(itemId);
    expect(reloaded.length, 1);
    expect(reloaded.single.id, 'a2');

    await AnnotationStore.remove(itemId, 'a2');
    expect(await AnnotationStore.load(itemId), isEmpty);
  });

  test('mergeById：画布回写可见子集并回全表，隐藏项数据不丢（§6 显隐②）', () {
    final a1 = ann('a1');
    final a2 = ann('a2');
    // 画布只见 a2（a1 隐藏），拖拽回写只含 a2 的更新
    final updates = [a2.copyWith(color: '#007AFF')];
    final merged = ImageAnnotator.mergeById([a1, a2], updates);
    expect(merged.length, 2, reason: '隐藏的 a1 不能被整表回写挤掉');
    expect(merged[0].id, 'a1');
    expect(merged[1].id, 'a2');
    expect(merged[1].color, '#007AFF');
  });
}
