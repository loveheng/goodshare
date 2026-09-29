import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/ai/video_clips.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/sync/backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 视频切片（关键区间）单测（2026-09-29 改版：标记 ≠ 处理，设计 docs/design/video-clips.md）：
/// 纯模型/步骤规整/编解码/合并、动作层标记与处理拆分、整片标记备份 opt-in、白名单视频排除。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    Db.overridePath(inMemoryDatabasePath);
  });

  setUp(() async {
    final repo = Repository();
    for (final it in await repo.list(vault: true, includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    for (final it in await repo.list(includeDeleted: true)) {
      await repo.softDelete(it.id!);
    }
    await repo.purgeAllDeleted();
  });

  group('ClipSegment 与 clips_json（段结构 v2）', () {
    test('JSON 往返一致（含 steps/status/clipPath）；坏段报错不静默', () {
      const c = ClipSegment(
        startMs: 1000,
        endMs: 65000,
        steps: [kClipStepExtract, kClipStepTranscribe],
        status: kClipStatusDone,
        clipPath: 'clip_segments/x.mp4',
        text: '你好',
        summary: '摘要',
        createdAt: 42,
      );
      final back = ClipSegment.fromJson(c.toJson().cast<String, Object?>());
      expect(back.steps, [kClipStepExtract, kClipStepTranscribe]);
      expect(back.status, kClipStatusDone);
      expect(back.clipPath, 'clip_segments/x.mp4');
      expect(back.text, '你好');
      expect(back.summary, '摘要');

      expect(() => ClipSegment.fromJson({'start_ms': 5, 'end_ms': 1}),
          throwsA(isA<FormatException>()));
    });

    test('normalizeClipSteps：摘要带动转写前置 + 顺序 + 去重（E2）', () {
      expect(normalizeClipSteps([kClipStepSummary]),
          [kClipStepTranscribe, kClipStepSummary]);
      expect(
          normalizeClipSteps(
              [kClipStepSummary, kClipStepExtract, kClipStepSummary, 'bogus']),
          [kClipStepExtract, kClipStepTranscribe, kClipStepSummary]);
      expect(normalizeClipSteps([kClipStepExtract]), [kClipStepExtract]);
      expect(normalizeClipSteps([]), isEmpty);
    });

    test('parseClipsJson：非 JSON / 坏段跳过不拖垮整条目', () {
      final clips = parseClipsJson('''
        [{"start_ms":1,"end_ms":2000,"status":"marked","created_at":1},
         {"start_ms":"bad","end_ms":9},
         {"nonsense":true}]
      ''');
      expect(clips.length, 1);
      expect(clips.single.status, kClipStatusMarked);
      expect(parseClipsJson(null), isEmpty);
      expect(parseClipsJson('not-json'), isEmpty);
    });

    test('isValidClipInterval 边界：[1s, 30min]', () {
      expect(isValidClipInterval(0, 1000), isTrue);
      expect(isValidClipInterval(0, 999), isFalse);
      expect(isValidClipInterval(5000, 5000), isFalse);
      expect(isValidClipInterval(0, 30 * 60 * 1000), isTrue);
      expect(isValidClipInterval(0, 30 * 60 * 1000 + 1), isFalse);
      expect(isValidClipInterval(-1, 5000), isFalse);
    });

    test('任务动作编码往返（含步骤子集）', () {
      final a = Repository.clipTaskAction(
          120000, 185000, [kClipStepExtract, kClipStepSummary]);
      expect(a, 'clip:120000-185000:ets', reason: '摘要带动转写 → e/t/s 齐全');
      final parsed = Repository.parseClipTaskAction(a);
      expect(parsed, isNotNull);
      expect(parsed!.$1, 120000);
      expect(parsed.$2, 185000);
      expect(parsed.$3, [kClipStepExtract, kClipStepTranscribe, kClipStepSummary]);
      expect(Repository.parseClipTaskAction('transcribe_audio'), isNull);
      expect(Repository.parseClipTaskAction('clip:1-2:'), isNull, reason: '空步骤无效');
      expect(Repository.parseClipTaskAction('clip:abc'), isNull);
    });

    test('ffmpeg 参数：音频 16k wav / 片段精确重编码（E1 libx264）', () {
      final audio = buildClipAudioArgs('/tmp/v.mp4', '/tmp/o.wav', 1500, 62000);
      expect(audio, containsAllInOrder(['-ss', '1.500', '-i', '/tmp/v.mp4', '-t', '60.500']));
      expect(audio, contains('pcm_s16le'));

      final cut = buildClipCutArgs('/tmp/v.mp4', '/tmp/c.mp4', 1500, 62000);
      expect(cut, containsAllInOrder(['-ss', '1.500', '-i', '/tmp/v.mp4', '-t', '60.500']));
      expect(cut, containsAllInOrder(['-c:v', 'libx264', '-crf', '23', '-c:a', 'aac']));
    });

    test('mergeClipResult：精确匹配替换，未命中追加', () {
      const a = ClipSegment(startMs: 0, endMs: 1000, createdAt: 1);
      const b = ClipSegment(startMs: 2000, endMs: 3000, createdAt: 2);
      final done = a.copyWith(status: kClipStatusDone, text: '产出');
      final merged = mergeClipResult([a, b], done);
      expect(merged.length, 2);
      expect(merged[0].status, kClipStatusDone);
      expect(merged[0].text, '产出');
      final appended = mergeClipResult([b], done);
      expect(appended.length, 2);
      expect(appended.last.startMs, 0);
    });
  });

  group('动作层：标记 ≠ 处理', () {
    test('ClipCommand 只登记时间点，不触发任何处理', () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await repo.add(InboxItem(
          itemType: InboxItem.typeVideo, rawContent: 'v', rawFilePath: '/tmp/a.mp4',
          createdAt: 1));
      final id = (await repo.list()).first.id!;

      await handler.execute(ClipCommand(id, startMs: 1000, endMs: 61000));
      final clips = parseClipsJson((await repo.byId(id))!.clipsJson);
      expect(clips, hasLength(1));
      expect(clips.single.status, kClipStatusMarked);
      expect(clips.single.text, isNull);
      expect(await repo.pendingTasks(), isEmpty, reason: '标记不自动入队（改版核心语义）');

      // 重复登记被拒
      await expectLater(
        handler.execute(ClipCommand(id, startMs: 1000, endMs: 61000)),
        throwsA(isA<ActionException>()),
      );
      // 非视频条目被拒
      await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'n', createdAt: 2));
      final noteId = (await repo.list()).firstWhere((e) => e.itemType == 'note').id!;
      await expectLater(
        handler.execute(ClipCommand(noteId, startMs: 0, endMs: 5000)),
        throwsA(isA<ActionException>()),
      );
    });

    test('ClipProcessCommand：勾选子集入队（摘要带动转写）+ 置 processing；未标记区间拒绝', () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await repo.add(InboxItem(
          itemType: InboxItem.typeVideo, rawContent: 'v', rawFilePath: '/tmp/a.mp4',
          createdAt: 1));
      final id = (await repo.list()).first.id!;
      await handler.execute(ClipCommand(id, startMs: 0, endMs: 5000));

      await handler.execute(ClipProcessCommand(id, startMs: 0, endMs: 5000,
          steps: [kClipStepExtract, kClipStepSummary]));
      final tasks = await repo.pendingTasks();
      expect(tasks, hasLength(1));
      expect(tasks.single['task_action'], 'clip:0-5000:ets', reason: 'E2：摘要带动转写');
      final seg = parseClipsJson((await repo.byId(id))!.clipsJson).single;
      expect(seg.status, kClipStatusProcessing);

      // 未标记的区间不能处理
      await expectLater(
        handler.execute(ClipProcessCommand(id, startMs: 90000, endMs: 95000,
            steps: [kClipStepExtract])),
        throwsA(isA<ActionException>()),
      );
      // 空步骤拒绝
      await expectLater(
        handler.execute(ClipProcessCommand(id, startMs: 0, endMs: 5000, steps: [])),
        throwsA(isA<ActionException>()),
      );
    });

    test('applyAiResult clip 通道 v2：回写状态/产物，不触碰条目级字段', () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await repo.add(InboxItem(
          itemType: InboxItem.typeVideo, rawContent: 'v', rawFilePath: '/tmp/a.mp4',
          createdAt: 1));
      final id = (await repo.list()).first.id!;
      await handler.execute(ClipCommand(id, startMs: 0, endMs: 5000));

      await handler.execute(
        ApplyAiResultCommand(
          id,
          ReconstructResult(
            humanMd: 'SHOULD-NOT-WRITE',
            summaryMd: 'SHOULD-NOT-WRITE-2',
            clip: const ClipSegment(
              startMs: 0, endMs: 5000,
              steps: [kClipStepExtract, kClipStepTranscribe, kClipStepSummary],
              status: kClipStatusDone,
              clipPath: 'clip_segments/x.0-5000.mp4',
              text: '区间转写文本', summary: '区间摘要', createdAt: 9,
            ),
          ),
        ),
        actor: CommandActor.pipeline,
      );

      final it = (await repo.byId(id))!;
      expect(it.humanMd, isNull, reason: '切片结果不得写条目级 human_md');
      expect(it.summaryMd, isNull, reason: '切片结果不得写条目级 summary_md');
      final seg = parseClipsJson(it.clipsJson).single;
      expect(seg.status, kClipStatusDone);
      expect(seg.clipPath, 'clip_segments/x.0-5000.mp4');
      expect(seg.text, '区间转写文本');
      expect(seg.summary, '区间摘要');
    });

    test('MarkWholeVideoCommand：整片标记开关（仅视频）', () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await repo.add(InboxItem(
          itemType: InboxItem.typeVideo, rawContent: 'v', rawFilePath: '/tmp/a.mp4',
          createdAt: 1));
      final id = (await repo.list()).first.id!;

      await handler.execute(MarkWholeVideoCommand(id, marked: true));
      expect((await repo.byId(id))!.videoWholeMarked, isTrue);
      await handler.execute(MarkWholeVideoCommand(id, marked: false));
      expect((await repo.byId(id))!.videoWholeMarked, isFalse);

      await repo.add(InboxItem(itemType: InboxItem.typeNote, rawContent: 'n', createdAt: 2));
      final noteId = (await repo.list()).firstWhere((e) => e.itemType == 'note').id!;
      await expectLater(
        handler.execute(MarkWholeVideoCommand(noteId, marked: true)),
        throwsA(isA<ActionException>()),
      );
    });
  });

  group('备份白名单：视频默认排除 + 整片标记 opt-in', () {
    test('未标记视频不进备份；整片标记的视频携带；clip_segments 产物进备份', () async {
      final dir = await Directory.systemTemp.createTemp('clip_backup_test2');
      final shares = Directory(p.join(dir.path, 'shares'))..createSync(recursive: true);
      File(p.join(shares.path, 'vid1.mp4')).writeAsStringSync('v1');
      File(p.join(shares.path, 'vid2.mp4')).writeAsStringSync('v2');
      File(p.join(shares.path, 'aud1.m4a')).writeAsStringSync('a');
      final segs = Directory(p.join(dir.path, 'clip_segments'))..createSync();
      File(p.join(segs.path, 'vid1.0-5000.mp4')).writeAsStringSync('seg');
      final subs = Directory(p.join(dir.path, 'subtitles'))..createSync();
      File(p.join(subs.path, 'vault1.srt')).writeAsStringSync('vault-srt');

      final items = [
        InboxItem(id: 'vid1', itemType: InboxItem.typeVideo, videoWholeMarked: true,
            rawFilePath: p.join(shares.path, 'vid1.mp4'), createdAt: 1),
        InboxItem(id: 'vid2', itemType: InboxItem.typeVideo,
            rawFilePath: p.join(shares.path, 'vid2.mp4'), createdAt: 2),
        InboxItem(id: 'aud1', itemType: InboxItem.typeAudio,
            rawFilePath: p.join(shares.path, 'aud1.m4a'), createdAt: 3),
      ];
      final files = await collectBackupFiles(items: items, vaultIds: {'vault1'}, docsPath: dir.path);
      final rels = files.map((f) => f.rel).toSet();

      expect(rels, contains('shares/vid1.mp4'), reason: '整片标记的视频携带（opt-in）');
      expect(rels, isNot(contains('shares/vid2.mp4')), reason: '未标记视频默认不进备份');
      expect(rels, contains('shares/aud1.m4a'), reason: '音频体积不大照常备份');
      expect(rels, contains('clip_segments/vid1.0-5000.mp4'), reason: '用户提取的片段=关键产物');
      expect(rels, isNot(contains('subtitles/vault1.srt')), reason: 'Vault 派生文件排除');

      await dir.delete(recursive: true);
    });
  });
}
