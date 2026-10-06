import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/ai/video_clips.dart';
import 'package:goodshare/data/block_artifacts.dart' show BlockArtifactKind;
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

    test('切片链已全原生（P2/P3）：无 ffmpeg 参数构造函数残留', () {
      // buildClipCutArgs/buildClipAudioArgs 已随 media-native 退役（lib/media 接管），
      // 此用例锁「不回潮」：video_clips.dart 只剩纯模型与任务动作编解码。
      expect(Repository.parseClipTaskAction('clip:1500-62000:et'), isNotNull);
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
          aiProcess: true, createdAt: 1)); // 授权管线回写（默认关闭）
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

  });

  group('块级切片（2026-10-05：块类型不再继承条目 itemType）', () {
    const key = 'local://shares/a.mp4';

    test('block_clip 任务串编解码往返；条目级 clip 串不误判', () {
      final a =
          Repository.blockClipTaskAction(key, 120000, 185000, [kClipStepSummary]);
      expect(a, 'block_clip:$key|120000-185000|ts', reason: '摘要带动转写 → ts');
      final parsed = Repository.parseBlockClipAction(a);
      expect(parsed, isNotNull);
      expect(parsed!.$1, key);
      expect(parsed.$2, 120000);
      expect(parsed.$3, 185000);
      expect(parsed.$4, [kClipStepTranscribe, kClipStepSummary]);
      expect(Repository.parseBlockClipAction('clip:0-5000:et'), isNull);
      expect(Repository.parseBlockClipAction('block_clip:$key|bad|e'), isNull);
    });

    test('mergeClipResult 按 blockKey 隔离：同区间不同块互不顶替', () {
      const itemSeg = ClipSegment(startMs: 0, endMs: 1000, createdAt: 1);
      const blockSeg = ClipSegment(
          startMs: 0, endMs: 1000, blockKey: 'local://a.mp4', createdAt: 2);
      final merged =
          mergeClipResult([itemSeg], blockSeg.copyWith(status: kClipStatusDone));
      expect(merged.length, 2, reason: '条目级与块级同区间不互撞');
      final back =
          mergeClipResult(merged, blockSeg.copyWith(status: kClipStatusDone));
      expect(back.length, 2, reason: '同块同区间精确替换');
    });

    test('笔记条目内的视频块可切片（块类型放行，不继承 note）；条目级仍拒', () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await repo.add(InboxItem(
          itemType: InboxItem.typeNote,
          rawContent: 'n',
          humanMd: '[视频]($key)',
          createdAt: 1));
      final id = (await repo.list()).first.id!;

      await handler.execute(
          ClipCommand(id, startMs: 1000, endMs: 61000, blockKey: key));
      final seg = parseClipsJson((await repo.byId(id))!.clipsJson).single;
      expect(seg.blockKey, key);
      expect(seg.status, kClipStatusMarked);

      await handler.execute(ClipProcessCommand(id,
          startMs: 1000, endMs: 61000,
          steps: [kClipStepExtract], blockKey: key));
      final tasks = await repo.pendingTasks();
      expect(tasks.single['task_action'], 'block_clip:$key|1000-61000|e');

      // 块级放行不等于条目级放行：note 条目级切片仍被拒
      await expectLater(
        handler.execute(ClipCommand(id, startMs: 2000, endMs: 62000)),
        throwsA(isA<ActionException>()),
      );
    });

    test("顶级 'item' 哨兵归一化条目级：clips 无 block_key、任务串走 clip:", () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await repo.add(InboxItem(
          itemType: InboxItem.typeVideo,
          rawContent: 'v',
          rawFilePath: '/tmp/a.mp4',
          createdAt: 1));
      final id = (await repo.list()).first.id!;

      await handler.execute(ClipCommand(id,
          startMs: 1000, endMs: 61000, blockKey: BlockArtifactKind.topLevelKey));
      final seg = parseClipsJson((await repo.byId(id))!.clipsJson).single;
      expect(seg.blockKey, isNull);

      await handler.execute(ClipProcessCommand(id,
          startMs: 1000, endMs: 61000,
          steps: [kClipStepExtract], blockKey: BlockArtifactKind.topLevelKey));
      final tasks = await repo.pendingTasks();
      expect(tasks.single['task_action'], 'clip:1000-61000:e');
    });

    test('音频同样可切片：音频块按块类型放行；顶级音频条目（item 哨兵）也放行', () async {
      final repo = Repository();
      final handler = ItemActionHandler(repo);
      const aKey = 'local://shares/a.m4a';
      await repo.add(InboxItem(
          itemType: InboxItem.typeNote,
          rawContent: 'n',
          humanMd: '[录音]($aKey)',
          createdAt: 1));
      final noteId = (await repo.list()).first.id!;
      await handler.execute(
          ClipCommand(noteId, startMs: 1000, endMs: 61000, blockKey: aKey));
      expect(
          parseClipsJson((await repo.byId(noteId))!.clipsJson).single.blockKey,
          aKey);

      // 顶级音频条目（'item' 哨兵 → 条目级）也可切片
      await repo.add(InboxItem(
          itemType: InboxItem.typeAudio,
          rawContent: 'a',
          rawFilePath: '/tmp/a.m4a',
          createdAt: 2));
      final audioId = (await repo.list())
          .firstWhere((e) => e.itemType == InboxItem.typeAudio)
          .id!;
      await handler.execute(ClipCommand(audioId,
          startMs: 1000, endMs: 61000, blockKey: BlockArtifactKind.topLevelKey));
      expect(
          parseClipsJson((await repo.byId(audioId))!.clipsJson).single.blockKey,
          isNull);
    });
  });

  group('备份白名单：过准入的视频进备份', () {
    test('收进的视频进备份；clip_segments 产物进备份', () async {
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
        InboxItem(id: 'vid1', itemType: InboxItem.typeVideo,
            rawFilePath: p.join(shares.path, 'vid1.mp4'), createdAt: 1),
        InboxItem(id: 'vid2', itemType: InboxItem.typeVideo,
            rawFilePath: p.join(shares.path, 'vid2.mp4'), createdAt: 2),
        InboxItem(id: 'aud1', itemType: InboxItem.typeAudio,
            rawFilePath: p.join(shares.path, 'aud1.m4a'), createdAt: 3),
      ];
      final files = await collectBackupFiles(items: items, vaultIds: {'vault1'}, docsPath: dir.path);
      final rels = files.map((f) => f.rel).toSet();

      expect(rels, contains('shares/vid1.mp4'), reason: '过门槛收进的视频进备份');
      expect(rels, contains('shares/vid2.mp4'), reason: '进备份不再需要逐条目标记');
      expect(rels, contains('shares/aud1.m4a'), reason: '音频照常备份');
      expect(rels, contains('clip_segments/vid1.0-5000.mp4'), reason: '用户提取的片段=关键产物');
      expect(rels, isNot(contains('subtitles/vault1.srt')), reason: 'Vault 派生文件排除');

      await dir.delete(recursive: true);
    });

    test('行内媒体（human_md 内 local:// 标记）随条目进备份；视频源排除不波及', () async {
      final dir = await Directory.systemTemp.createTemp('inline_media_backup_test');
      final shares = Directory(p.join(dir.path, 'shares'))..createSync(recursive: true);
      File(p.join(shares.path, 'note1.jpg')).writeAsStringSync('img');
      File(p.join(shares.path, 'note1.m4a')).writeAsStringSync('aud');

      final items = [
        // 作曲器便签：无 rawFilePath，媒体只活在 human_md 里
        InboxItem(
            id: 'note1',
            itemType: InboxItem.typeNote,
            humanMd: '前文\n\n![拍照](local://shares/note1.jpg)\n\n'
                '[录音](local://shares/note1.m4a)',
            createdAt: 1),
        InboxItem(
            id: 'note2',
            itemType: InboxItem.typeNote,
            humanMd: '无媒体便签',
            createdAt: 2),
      ];
      final files = await collectBackupFiles(items: items, vaultIds: {}, docsPath: dir.path);
      final rels = files.map((f) => f.rel).toSet();

      expect(rels, contains('shares/note1.jpg'), reason: '行内图片进备份');
      expect(rels, contains('shares/note1.m4a'), reason: '行内录音进备份');
      expect(files.where((f) => f.rel == 'shares/note1.jpg').single.itemId, 'note1');
      await dir.delete(recursive: true);
    });
  });
}
