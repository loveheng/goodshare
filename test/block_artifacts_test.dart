import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/capability.dart' show BlockKind;
import 'package:goodshare/ai/workflow.dart';
import 'package:goodshare/data/block_artifacts.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 块附件通道测试护栏（block-artifact-workflow.md 收尾批次 3）：
/// 数据层删盘/级联、WorkflowSpec 纯函数（可用性判定）、块产物路径解析。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  group('BlockArtifactStore 数据层', () {
    late Repository repo;
    late String itemId;
    late Directory tmp;

    setUp(() async {
      repo = Repository();
      tmp = await Directory.systemTemp.createTemp('block_art_test');
      final item = await repo.add(InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: '看这个 local://v1.mp4',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      itemId = item.id!;
    });

    tearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    BlockArtifactInput textArt(String kind, String text) =>
        BlockArtifactInput(kind, text: text, metaJson: '{"cues":2}');

    test('upsertAll 落库 + get/listForItem 读回（一步双产物）', () async {
      await repo.blockArtifacts.upsertAll(itemId, 'local://v1.mp4', [
        textArt(BlockArtifactKind.transcript, '第一句\n第二句'),
        BlockArtifactInput(BlockArtifactKind.subtitle,
            text: '第一句', filePath: '${tmp.path}/v1.srt'),
      ]);
      final tr = await repo.blockArtifacts.get(
          itemId, 'local://v1.mp4', BlockArtifactKind.transcript);
      expect(tr?.text, '第一句\n第二句');
      final arts =
          await repo.blockArtifacts.listForItem(itemId, blockKey: 'local://v1.mp4');
      expect(arts.map((a) => a.kind),
          containsAll([BlockArtifactKind.transcript, BlockArtifactKind.subtitle]));
    });

    test('upsertAll 覆盖语义（重跑重算）：同 key 同 kind 顶替不重复', () async {
      final key = 'local://v1.mp4';
      await repo.blockArtifacts.upsertAll(
          itemId, key, [textArt(BlockArtifactKind.transcript, '旧文本')]);
      await repo.blockArtifacts.upsertAll(
          itemId, key, [textArt(BlockArtifactKind.transcript, '新文本')]);
      final arts = await repo.blockArtifacts.listForItem(itemId, blockKey: key);
      expect(arts.where((a) => a.kind == BlockArtifactKind.transcript).length, 1);
      expect(arts.first.text, '新文本');
    });

    test('deleteBlock 删行 + 文件产物删盘（删行必删盘，纪律 7）', () async {
      final key = 'local://v1.mp4';
      final f = File('${tmp.path}/v1.srt')..writeAsStringSync('WEBVTT');
      await repo.blockArtifacts.upsertAll(itemId, key, [
        textArt(BlockArtifactKind.transcript, '文本'),
        BlockArtifactInput(BlockArtifactKind.subtitle,
            text: '字幕', filePath: f.path),
      ]);
      expect(f.existsSync(), isTrue);
      await repo.blockArtifacts.deleteBlock(itemId, key);
      // 表行清零
      expect(await repo.blockArtifacts.listForItem(itemId, blockKey: key), isEmpty);
      // fileBacked 物理文件联动删除；text 产物无文件不受影响
      expect(f.existsSync(), isFalse);
    });

    test('重复媒体引用共享产物：删 A 块不动 B 块（路径寻址红利）', () async {
      final key = 'local://v1.mp4';
      final f = File('${tmp.path}/shared.srt')..writeAsStringSync('WEBVTT');
      // 两行正文引用同一 url → 同一 blockKey 合法共享（拍板：不搞 #1 序号）
      await repo.blockArtifacts.upsertAll(
          itemId, key, [textArt(BlockArtifactKind.transcript, '共享文本')]);
      // B 块挂文件产物；删 A 块时 B 块的表行与物理文件都必须完好
      await repo.blockArtifacts.upsertAll(itemId, '$key#2', [
        BlockArtifactInput(BlockArtifactKind.subtitle,
            text: '另一块', filePath: f.path),
      ]);
      await repo.blockArtifacts.deleteBlock(itemId, key);
      final rest = await repo.blockArtifacts.listForItem(itemId);
      expect(rest.map((a) => a.blockKey), contains('$key#2'));
      expect(f.existsSync(), isTrue,
          reason: '删 A 块不得误删 B 块正在引用的物理文件');
    });

    test('clearForItem 级联清零（恢复即清口径）', () async {
      await repo.blockArtifacts.upsertAll(
          itemId, 'local://v1.mp4', [textArt(BlockArtifactKind.transcript, 't')]);
      await repo.blockArtifacts.clearForItem(itemId);
      expect(await repo.blockArtifacts.listForItem(itemId), isEmpty);
    });

    test('多块互相隔离：删 A 块不误删 B 块物理文件（碰撞修复回归）', () async {
      final fa = File('${tmp.path}/a.srt')..writeAsStringSync('WEBVTT');
      final fb = File('${tmp.path}/b.srt')..writeAsStringSync('WEBVTT');
      await repo.blockArtifacts.upsertAll(itemId, 'local://a.mp4', [
        BlockArtifactInput(BlockArtifactKind.subtitle,
            text: 'A', filePath: fa.path),
      ]);
      await repo.blockArtifacts.upsertAll(itemId, 'local://b.mp4', [
        BlockArtifactInput(BlockArtifactKind.subtitle,
            text: 'B', filePath: fb.path),
      ]);
      await repo.blockArtifacts.deleteBlock(itemId, 'local://a.mp4');
      expect(fa.existsSync(), isFalse);
      expect(fb.existsSync(), isTrue, reason: 'B 块音轨/字幕文件必须完好');
    });
  });

  group('WorkflowSpec 纯函数（§3.3 可用性判定）', () {
    test('视频 spec：四步（提取音频升回首步骤，2026-10-05 草图）', () {
      final s = workflowFor(BlockKind.video);
      // 提取音频恢复为显式用户步骤，排在转写之前
      expect(s.steps.map((e) => e.id).toList(),
          ['extract_audio', 'transcribe', 'translate', 'summarize']);
      // 提取音频产 audio_file；转写仍一步双产物：转写文本 + 字幕
      expect(s.steps.first.produces, {BlockArtifactKind.audioFile});
      expect(s.steps[1].produces,
          {BlockArtifactKind.transcript, BlockArtifactKind.subtitle});
    });

    test('视频转写不再顺带产音轨（audio_file 由提取音频步骤独占）', () {
      final s = workflowFor(BlockKind.video);
      final transcribe = s.steps[1];
      // 转写 extraKinds 已摘除 audio_file：不再孤儿产物、锚点不误判
      expect(transcribe.extraKinds, isEmpty);
      expect(transcribe.produces,
          {BlockArtifactKind.transcript, BlockArtifactKind.subtitle});
      // 音频块无提取音频步骤（本即音频）
      expect(workflowFor(BlockKind.audio).steps.map((e) => e.id),
          isNot(contains('extract_audio')));
    });

    test('availabilityOf：空产物 → 链首 ready、翻译 locked', () {
      final s = workflowFor(BlockKind.image);
      expect(availabilityOf(s.steps[0], <String>{}),
          WorkflowStepAvailability.ready);
      expect(availabilityOf(s.steps[1], <String>{}), // translate 消费 ocr_text
          WorkflowStepAvailability.locked);
    });

    test('availabilityOf：消费源任一满足即 ready（翻译可选 transcript 或 subtitle）', () {
      final s = workflowFor(BlockKind.audio);
      final translate = s.steps[1];
      expect(availabilityOf(translate, {BlockArtifactKind.subtitle}),
          WorkflowStepAvailability.ready);
      expect(availabilityOf(translate, {BlockArtifactKind.transcript}),
          WorkflowStepAvailability.ready);
      expect(
          availabilityOf(translate, {BlockArtifactKind.ocrText}),
          WorkflowStepAvailability.locked,
          reason: '备选源集合外的产物不满足');
    });

    test('availabilityOf：produces 全存在 → done（可重跑覆盖）', () {
      final s = workflowFor(BlockKind.audio);
      final transcribe = s.steps[0];
      expect(
          availabilityOf(transcribe,
              {BlockArtifactKind.transcript, BlockArtifactKind.subtitle}),
          WorkflowStepAvailability.done);
      expect(
          availabilityOf(transcribe, {BlockArtifactKind.transcript}),
          WorkflowStepAvailability.ready,
          reason: '双产物缺一 = 未完成（一步双产物原子性）');
    });

    test('availableSources：返回备选源 ∩ 已有产物（segmented 选项集）', () {
      final s = workflowFor(BlockKind.audio);
      final translate = s.steps[1];
      expect(
          availableSources(translate, {BlockArtifactKind.transcript}),
          [BlockArtifactKind.transcript]);
      expect(
          availableSources(translate, {BlockArtifactKind.transcript, BlockArtifactKind.subtitle}).length,
          2);
      expect(availableSources(translate, <String>{}), isEmpty);
    });

    test('textSpec：条目级步骤 produces 空 → 恒 ready', () {
      final s = workflowFor(BlockKind.text);
      for (final step in s.steps) {
        expect(step.produces, isEmpty);
        expect(availabilityOf(step, <String>{}), WorkflowStepAvailability.ready);
      }
    });
  });
}
