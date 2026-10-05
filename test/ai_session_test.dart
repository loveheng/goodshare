import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/ui/ai_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 状态机假件：把「库态」建模成几个普通字段，apply 按动作层语义就地改写，
/// 使「实时读库」的判定路径在测试里也真实可验（不靠 mock 库）。
class _Fake {
  _Fake({
    this.humanMd = 'AI 版',
    this.baseline = '人类原文',
    this.phase = AiSessionPhase.pending,
    this.aiRevision = 'AI 版',
  });

  String humanMd;
  String? baseline;
  AiSessionPhase phase;
  String aiRevision;
  String text = 'AI 版';

  final applied = <AiSessionCommand>[];
  int takeovers = 0;

  InboxItem get item => InboxItem(
    id: 'doc1',
    itemType: InboxItem.typeNote,
    humanMd: humanMd,
    humanMdBaseline: baseline,
    docMetaJson: jsonEncode({'ai_session_state': phase.name}),
    createdAt: 0,
  );

  Future<Object?> apply(AiSessionCommand cmd) async {
    applied.add(cmd);
    switch (cmd.phase) {
      case AiSessionPhase.restored:
        humanMd = baseline ?? humanMd;
      case AiSessionPhase.pending:
        humanMd = cmd.humanMd ?? aiRevision;
      case AiSessionPhase.idle:
        baseline = null;
        if (cmd.humanMd != null) humanMd = cmd.humanMd!;
    }
    phase = cmd.phase;
    return null;
  }

  /// settle 时长由测试注入（控制器刻意留了这个缝）；用真实时钟推进，
  /// 不引 `fake_async`——本仓不把它列为直接依赖，新依赖须显式确认。
  AiSessionController build({Duration settle = const Duration(milliseconds: 300)}) =>
      AiSessionController(
        itemId: 'doc1',
        readItem: () async => item,
        readLatestAi: () async => aiRevision,
        apply: apply,
        readText: () => text,
        settle: settle,
      )..onTakeover = () => takeovers++;
}

Future<void> _tick(Duration d) => Future<void>.delayed(d);

void main() {
  group('相位归一与接管判定（纯函数）', () {
    test('基线为空时即使 meta 写了 pending 也归一为 idle（§3.1）', () {
      final it = InboxItem(
        itemType: InboxItem.typeNote,
        humanMd: 'x',
        humanMdBaseline: null,
        docMetaJson: jsonEncode({'ai_session_state': 'pending'}),
        createdAt: 0,
      );
      expect(aiSessionPhaseOf(it), AiSessionPhase.idle);
    });

    test('基线非空时按 meta 取相位', () {
      InboxItem mk(String state) => InboxItem(
        itemType: InboxItem.typeNote,
        humanMd: 'x',
        humanMdBaseline: 'base',
        docMetaJson: jsonEncode({'ai_session_state': state}),
        createdAt: 0,
      );
      expect(aiSessionPhaseOf(mk('pending')), AiSessionPhase.pending);
      expect(aiSessionPhaseOf(mk('restored')), AiSessionPhase.restored);
      expect(aiSessionPhaseOf(mk('乱值')), AiSessionPhase.idle);
    });

    test('trim 比较：首尾空白不算接管，真改内容才算', () {
      expect(isAiTakeover('原文', '原文'), isFalse);
      expect(isAiTakeover('  原文\n', '原文'), isFalse);
      expect(isAiTakeover('原文改了', '原文'), isTrue);
    });
  });

  group('AiSessionController 状态机', () {
    test('settle 窗口内不落库，到期才闭环（§5/§8.2）', () async {
      final f = _Fake();
      final ctl = f.build()..sync(f.item);
      expect(ctl.isOpen, isTrue);

      f.text = 'AI 版我改了';
      ctl.noteUserEdit();
      await _tick(const Duration(milliseconds: 100));
      expect(f.applied, isEmpty, reason: '窗口内手滑改字不得落库');

      await _tick(const Duration(milliseconds: 400));
      expect(f.applied.single.phase, AiSessionPhase.idle);
      expect(f.applied.single.humanMd, 'AI 版我改了');
      expect(ctl.isOpen, isFalse);
      expect(ctl.baseline, isNull);
      expect(f.takeovers, 1, reason: '接管要给一次非阻断提示');
      ctl.dispose();
    });

    test('手滑删回原样 → 判定未接管，会话完整保留', () async {
      final f = _Fake();
      final ctl = f.build()..sync(f.item);
      f.text = 'AI 版多打的';
      ctl.noteUserEdit();
      await _tick(const Duration(milliseconds: 100));
      f.text = 'AI 版'; // 删回原样
      ctl.noteUserEdit(); // 重新起窗
      await _tick(const Duration(milliseconds: 450));
      expect(f.applied, isEmpty);
      expect(ctl.isOpen, isTrue);
      expect(f.takeovers, 0);
      ctl.dispose();
    });

    test('§8.7 竞态：点还原即取消 pending 计时器，到期不得误判接管', () async {
      final f = _Fake();
      final ctl = f.build()..sync(f.item);
      f.text = 'AI 版改了';
      ctl.noteUserEdit(); // 起倒计时
      await _tick(const Duration(milliseconds: 100));

      await ctl.restore(); // 窗口内点【还原】
      await _tick(const Duration(milliseconds: 450)); // 原计时器到期时刻已过

      expect(
        f.applied.map((c) => c.phase),
        [AiSessionPhase.restored],
        reason: '到期回调必须作废，不能再补一条 idle',
      );
      expect(ctl.phase, AiSessionPhase.restored);
      expect(f.takeovers, 0);
      ctl.dispose();
    });

    test('flush 强制落定：不等窗口也立即闭环（§8.3 生命周期）', () async {
      final f = _Fake();
      final ctl = f.build()..sync(f.item);
      f.text = '手改版';
      ctl.noteUserEdit();
      await _tick(const Duration(milliseconds: 50));
      await ctl.flush();
      expect(f.applied.single.phase, AiSessionPhase.idle);
      expect(f.applied.single.humanMd, '手改版');
      ctl.dispose();
    });

    test('PENDING 态判定基准 = ai_revisions 最新条（非当前 humanMd）', () async {
      final f = _Fake(
        baseline: '人类原文',
        humanMd: '屏幕上的旧 AI 版',
        aiRevision: '最新 AI 版',
      );
      final ctl = f.build()..sync(f.item);
      // 文本等于 ai_revisions 最新条 → 未改，不接管
      f.text = '最新 AI 版';
      ctl.noteUserEdit();
      await _tick(const Duration(milliseconds: 450));
      expect(f.applied, isEmpty);

      f.text = '最新 AI 版改了';
      ctl.noteUserEdit();
      await _tick(const Duration(milliseconds: 450));
      expect(f.applied.single.phase, AiSessionPhase.idle);
      ctl.dispose();
    });

    test('RESTORED 态以基线为判定基准', () async {
      final f = _Fake(phase: AiSessionPhase.restored, humanMd: '人类原文');
      final ctl = f.build()..sync(f.item);
      expect(ctl.phase, AiSessionPhase.restored);

      f.text = '人类原文我又写了';
      ctl.noteUserEdit();
      await _tick(const Duration(milliseconds: 450));
      expect(f.applied.single.phase, AiSessionPhase.idle);
      expect(f.applied.single.humanMd, '人类原文我又写了');
      ctl.dispose();
    });

    test('还原 / 恢复 AI 改动返回待灌回编辑器的正文', () async {
      final f = _Fake();
      final ctl = f.build()..sync(f.item);

      expect(await ctl.restore(), '人类原文');
      expect(ctl.phase, AiSessionPhase.restored);

      expect(await ctl.reapplyAi(), 'AI 版');
      expect(ctl.phase, AiSessionPhase.pending);
      ctl.dispose();
    });
  });

  // ───────── 动作层不变量（真库，防呆下沉） ─────────

  group('AiSessionCommand 动作层不变量', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      Db.overridePath(inMemoryDatabasePath);
    });

    late Repository repo;
    late ItemActionHandler handler;

    setUp(() async {
      repo = Repository();
      handler = ItemActionHandler(repo);
      for (final it in await repo.list(includeDeleted: true)) {
        await repo.softDelete(it.id!);
      }
      await repo.purgeDeleted(retention: Duration.zero);
    });

    Future<InboxItem> seeded({String? baseline = '人类原文'}) async {
      final it = await repo.add(
        InboxItem(
          itemType: InboxItem.typeNote,
          humanMd: 'AI 版',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await repo.update(it.id!, {
        'human_md_baseline': baseline,
        'doc_meta_json': jsonEncode({'ai_session_state': 'pending'}),
      });
      await repo.insertAiRevision(it.id!, 'AI 版');
      return (await repo.byId(it.id!))!;
    }

    test('还原：human_md ← 基线，态转 restored，基线保留（可再换回 AI 版）', () async {
      final it = await seeded();
      await handler.execute(AiSessionCommand(it.id!, phase: AiSessionPhase.restored));
      final after = (await repo.byId(it.id!))!;
      expect(after.humanMd, '人类原文');
      expect(after.humanMdBaseline, '人类原文');
      expect(after.aiSessionState, 'restored');
    });

    test('恢复 AI 改动：human_md ← ai_revisions 最新条（§3.2 恢复源不在 Meta）', () async {
      final it = await seeded();
      await handler.execute(AiSessionCommand(it.id!, phase: AiSessionPhase.restored));
      await handler.execute(AiSessionCommand(it.id!, phase: AiSessionPhase.pending));
      final after = (await repo.byId(it.id!))!;
      expect(after.humanMd, 'AI 版');
      expect(after.aiSessionState, 'pending');
    });

    test('接管闭环：基线置 null + 当前文本落库 + 态转 idle', () async {
      final it = await seeded();
      await handler.execute(
        AiSessionCommand(it.id!, phase: AiSessionPhase.idle, humanMd: '手改版'),
      );
      final after = (await repo.byId(it.id!))!;
      expect(after.humanMd, '手改版');
      expect(after.humanMdBaseline, isNull, reason: '闭环必须清空基线，否则下次 auto首捕不触发');
      expect(after.aiSessionState, 'idle');
    });

    test('无基线时还原 / 恢复一律拒绝（§3.1 不变量下沉到动作层）', () async {
      final it = await seeded(baseline: null);
      expect(
        () => handler.execute(AiSessionCommand(it.id!, phase: AiSessionPhase.restored)),
        throwsA(isA<ActionException>()),
      );
      expect(
        () => handler.execute(AiSessionCommand(it.id!, phase: AiSessionPhase.pending)),
        throwsA(isA<ActionException>()),
      );
    });

    test('AI 主体不得操作会话态（越权在动作层拦截）', () async {
      final it = await seeded();
      expect(
        () => handler.execute(
          AiSessionCommand(it.id!, phase: AiSessionPhase.idle),
          actor: CommandActor.ai,
        ),
        throwsA(isA<ActionException>()),
      );
    });
  });
}
