import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/action/commands.dart';
import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/reconstructor.dart';
import 'package:goodshare/ai/subtitle.dart';
import 'package:goodshare/ai/translation.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 翻译层单测（2026-09-28）：句子切分 / 源语判定 / 逐句降级 / 字幕三模式 /
/// 命令校验与译文落库。
///
/// 引擎用假实现：翻译层的**降级口径**（失败保留原文、不抛、不重入队）必须
/// 在不依赖任何平台能力的前提下可验证——真机的 ML Kit 语言包在国内不可达，
/// 恰恰是这些分支最常走的路径。
class _FakeEngine implements TranslationEngine {
  _FakeEngine({this.lookup, this.throwOn, this.available = true});

  final String? Function(String text)? lookup;
  final String? throwOn;
  final bool available;

  @override
  String get name => 'fake';

  @override
  Future<bool> get isAvailable async => available;

  @override
  String? get unavailableReason => available ? null : '假引擎不可用';

  @override
  Future<Set<String>> supportedTargets() async => kTargetLanguages.toSet();

  @override
  Future<String?> translate(String text, {required String from, required String to}) async {
    if (throwOn != null && text == throwOn) throw StateError('engine boom');
    if (lookup == null) return '[$from→$to] $text';
    return lookup!(text);
  }
}

void main() {
  group('splitSentences', () {
    test('按中英标点切句并保留终结符', () {
      final r = splitSentences('First one. Second one! 第三句。第四句？');
      expect(r.length, 4);
      expect(r.first.trim(), 'First one.');
      expect(r.last.trim(), '第四句？');
    });

    test('换行即断句', () {
      final r = splitSentences('a\nb');
      expect(r.length, 2);
    });

    test('无标点超长串按 maxChars 硬切（防整段直灌）', () {
      final long = 'x' * 1200;
      final r = splitSentences(long, maxChars: 500);
      expect(r.length, greaterThan(1));
      expect(r.every((s) => s.length <= 500), isTrue);
    });
  });

  group('detectSourceLanguage', () {
    test('中英日韩俄判定', () {
      expect(detectSourceLanguage('Hello world, this is English.'), 'en');
      expect(detectSourceLanguage('这是一段中文文本'), 'zh');
      expect(detectSourceLanguage('こんにちは世界'), 'ja');
      expect(detectSourceLanguage('안녕하세요 세계'), 'ko');
      expect(detectSourceLanguage('Привет мир'), 'ru');
    });

    test('空文本回落 en（不抛、不返回未知码）', () {
      expect(detectSourceLanguage(''), 'en');
    });
  });

  group('translateParagraph 降级', () {
    test('逐句翻译并按序回填', () async {
      final r = await translateParagraph(
        _FakeEngine(),
        'One. Two.',
        from: 'en',
        to: 'zh',
      );
      expect(r, contains('[en→zh] One.'));
      expect(r, contains('[en→zh] Two.'));
    });

    test('单句失败保留该句原文，不拖垮整篇', () async {
      final r = await translateParagraph(
        _FakeEngine(throwOn: 'bad'),
        'good one. bad. good two.',
        from: 'en',
        to: 'zh',
      );
      expect(r, contains('[en→zh] good one.'));
      expect(r, contains('bad.')); // 失败句原样保留
      expect(r, contains('[en→zh] good two.'));
    });

    test('引擎返回 null 视为无译文，保留原文', () async {
      final r = await translateParagraph(
        _FakeEngine(lookup: (_) => null),
        'keep me. And me.',
        from: 'en',
        to: 'zh',
      );
      expect(r, 'keep me.\nAnd me.');
    });
  });

  group('TranslationService 门控', () {
    test('关闭开关 → 无译文', () async {
      final svc = TranslationService(
        router: TranslationRouter([_FakeEngine()]),
        isEnabled: () => false,
        targetLang: () => 'zh',
      );
      expect(await svc.translateText('hello'), isNull);
    });

    test('源语 == 目标语 → 不跑引擎', () async {
      final svc = TranslationService(
        router: TranslationRouter([_FakeEngine()]),
        isEnabled: () => true,
        targetLang: () => 'zh',
      );
      expect(await svc.translateText('这是一段中文'), isNull);
    });

    test('目标语言不在白名单 → 无译文', () async {
      final svc = TranslationService(
        router: TranslationRouter([_FakeEngine()]),
        isEnabled: () => true,
        targetLang: () => 'zz',
      );
      expect(await svc.translateText('hello'), isNull);
    });

    test('任务级 target 覆盖设置项', () async {
      final svc = TranslationService(
        router: TranslationRouter([_FakeEngine()]),
        isEnabled: () => true,
        targetLang: () => 'zh',
      );
      expect(await svc.translateText('hello', target: 'ja'), contains('[en→ja]'));
    });

    test('cue 翻译：整体不可用时返回原文（translation 恒 null）', () async {
      final svc = TranslationService(
        router: TranslationRouter([_FakeEngine(available: false)]),
        isEnabled: () => true,
        targetLang: () => 'zh',
      );
      final out = await svc.translateCues([
        const AsrCue(start: 0, duration: 1, text: 'hello'),
      ]);
      expect(out.single.translation, isNull);
      expect(out.single.text, 'hello');
    });

    test('cue 翻译：可用时逐条补译文', () async {
      final svc = TranslationService(
        router: TranslationRouter([_FakeEngine()]),
        isEnabled: () => true,
        targetLang: () => 'zh',
      );
      final out = await svc.translateCues([
        const AsrCue(start: 0, duration: 1, text: 'hello'),
        const AsrCue(start: 2, duration: 1, text: '  '),
      ]);
      expect(out.first.translation, '[en→zh] hello');
      expect(out.last.translation, isNull); // 空白 cue 不送引擎
    });
  });

  group('字幕三模式', () {
    final cues = [
      const AsrCue(start: 0, duration: 2, text: 'hello', translation: '你好'),
      const AsrCue(start: 3, duration: 2, text: 'bye'),
    ];

    test('sourceOnly 只出原文', () {
      final srt = serializeSrt(cues, mode: SubtitleMode.sourceOnly);
      expect(srt, contains('hello'));
      expect(srt, isNot(contains('你好')));
    });

    test('bilingual 每 cue 两行', () {
      final srt = serializeSrt(cues, mode: SubtitleMode.bilingual);
      expect(srt, contains('hello\n你好'));
    });

    test('separate 取译文，缺译文回退原文', () {
      final srt = serializeSrt(cues, mode: SubtitleMode.separate);
      expect(srt, contains('你好'));
      expect(srt, contains('bye')); // 无译文的 cue 保留原文
    });
  });

  group('翻译任务动作串', () {
    test('默认无后缀 / 带语言可解析', () {
      expect(Repository.translateTaskAction(), 'translate');
      expect(Repository.translateTaskAction('ja'), 'translate:ja');
      expect(Repository.isTranslateAction('translate'), isTrue);
      expect(Repository.isTranslateAction('translate:ja'), isTrue);
      expect(Repository.isTranslateAction('transcribe_audio'), isFalse);
      expect(Repository.translateTargetOf('translate'), isNull);
      expect(Repository.translateTargetOf('translate:ja'), 'ja');
    });
  });

  // ─────────────────── 动作层（落库 / 校验） ───────────────────

  group('TranslateCommand 动作层', () {
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

    test('无正文拒绝翻译（图片/音视频须先出文本）', () async {
      final it = await repo.add(InboxItem(
        itemType: InboxItem.typeImage,
        rawContent: '',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      expect(
        () => handler.execute(TranslateCommand(it.id!)),
        throwsA(isA<ActionException>().having((e) => e.code, 'code', ActionErrorCode.invalidRequest)),
      );
    });

    test('非法目标语言被动作层拦下（防呆不下放到传输层）', () async {
      final it = await repo.add(InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: 'hello world',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      expect(
        () => handler.execute(TranslateCommand(it.id!, targetLang: 'zz')),
        throwsA(isA<ActionException>()),
      );
    });

    test('翻译入队 translate 任务（含语言后缀）', () async {
      final it = await repo.add(InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: 'hello world',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final r = await handler.execute(TranslateCommand(it.id!, targetLang: 'ja'));
      expect(r.op, 'translate');
      final tasks = await repo.pendingTasks(limit: 10);
      final actions = tasks.map((t) => t['task_action'] as String?).toList();
      expect(actions.any(Repository.isTranslateAction), isTrue);
      expect(actions.any((a) => Repository.translateTargetOf(a) == 'ja'), isTrue);
    });

    test('译文与原文并列落库：不覆盖 human_md', () async {
      final it = await repo.add(InboxItem(
        itemType: InboxItem.typeNote,
        humanMd: '# 原文',
        rawContent: 'raw',
        aiProcess: true, // 授权管线处理（默认关闭，测试显式开启）
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final r = await handler.execute(
        ApplyAiResultCommand(
          it.id!,
          const ReconstructResult(humanMd: '# 原文', translatedMd: '# 译文', translateLang: 'zh'),
        ),
        actor: CommandActor.pipeline,
      );
      expect(r.item!.humanMd, '# 原文');
      expect(r.item!.translatedMd, '# 译文');
      expect(r.item!.translateLang, 'zh');
      expect(r.item!.hasTranslation, isTrue);
    });

    test('快照回传含 translation 字段（AI 与详情页同口径）', () async {
      final it = await repo.add(InboxItem(
        itemType: InboxItem.typeNote,
        humanMd: 'body',
        translateLang: 'zh',
        translatedMd: '正文',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final r = await handler.execute(UpdateItemCommand(id: it.id!, title: 't'));
      final json = r.toJson();
      final item = (json['item'] as Map).cast<String, Object?>();
      final tr = (item['translation'] as Map).cast<String, Object?>();
      expect(tr['lang'], 'zh');
      expect(tr['text'], '正文');
    });
  });
}
