import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'language_codes.dart';

/// 字幕产物（2026-09-28，设计见 docs/design/asr-subtitle.md）：
/// - [AsrCue]：带时间轴的单条字幕（VAD 分段产出，时间单位秒）；
/// - 序列化：SRT / VTT **双份同出**（2026-09-28 确认，序列化成本接近零）；
/// - [SubtitleStore]：落盘 `documents/subtitles/{itemId}.srt|.vtt`。
///   纯文件 IO，与 human_md 解耦；**不新增 inbox_items 字段**——字幕是否存在
///   按文件存在性判定（[SubtitleStore.exists]），详情页据此显隐「导出字幕」。
///   字幕失败不影响 human_md（「占位不卡死」策略的字幕侧延伸）。

/// 单条字幕 cue：`start`/`duration` 均为秒（VAD `SpeechSegment.start` 除以
/// sampleRate 得到），`text` 为该段转写文本。
/// 字幕译文模式（设计 §6 三模式；2026-09-28 随翻译层落地）：
/// - [sourceOnly]：只出原文（翻译不可用时的等价行为，非静默降级）；
/// - [bilingual]：单文件，每条 cue 两行（原文在上、译文在下）；
/// - [separate]：原文与译文各一份文件（`{itemId}.srt` + `{itemId}.{lang}.srt`）。
enum SubtitleMode {
  sourceOnly,
  bilingual,
  separate,
}

class AsrCue {
  const AsrCue({
    required this.start,
    required this.duration,
    required this.text,
    this.translation,
  });

  /// 段起始时间（秒）。
  final double start;

  /// 段时长（秒）。
  final double duration;

  /// 该段转写文本。
  final String text;

  /// 该段译文（翻译层产出；null = 未翻译 / 失败保留原文）。
  final String? translation;

  /// 指定模式下该条实际显示的文本行（bilingual 时为「原文\n译文」）。
  String line(SubtitleMode mode) {
    final src = text.trim();
    final tr = translation?.trim();
    if (mode == SubtitleMode.bilingual && tr != null && tr.isNotEmpty) {
      return '$src\n$tr';
    }
    if (mode == SubtitleMode.separate && tr != null && tr.isNotEmpty) return tr;
    return src;
  }

  Map<String, Object?> toJson() => {
        'start': start,
        'duration': duration,
        'text': text,
        if (translation != null) 'translation': translation,
      };

  static AsrCue fromJson(Map<Object?, Object?> j) => AsrCue(
        start: (j['start'] as num).toDouble(),
        duration: (j['duration'] as num).toDouble(),
        text: j['text'] as String,
        translation: j['translation'] as String?,
      );

  AsrCue copyWith({double? start, double? duration, String? text, String? translation}) =>
      AsrCue(
        start: start ?? this.start,
        duration: duration ?? this.duration,
        text: text ?? this.text,
        translation: translation ?? this.translation,
      );
}

/// 秒 → `HH:MM:SS,mmm`（SRT，毫秒分隔逗号）或 `HH:MM:SS.mmm`（VTT，用点）。
/// [decimal] 传 ',' 生成 SRT 时间戳、'.' 生成 VTT 时间戳。
String formatTimestamp(double seconds, {required String decimal}) {
  final totalMs = (seconds < 0 ? 0 : seconds) * 1000;
  final ms = totalMs.round();
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final mmm = ms % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}$decimal${mmm.toString().padLeft(3, '0')}';
}

/// 过滤无信息 cue 后的有序列表（trim 空的丢弃；官方脚本还丢弃 `.` 一类
/// 纯符号产物，本实现同样按「trim 后为空」口径跳过）。
List<AsrCue> usableCues(List<AsrCue> cues) =>
    cues.where((c) => c.text.trim().isNotEmpty).toList();

/// cue 列表 → SRT 全文（序号从 1 起，条目间空行）。
/// [mode] 决定是否带译文：bilingual 时每 cue 两行，separate 时取译文（缺则原文）。
String serializeSrt(List<AsrCue> cues, {SubtitleMode mode = SubtitleMode.sourceOnly}) {
  final b = StringBuffer();
  var i = 1;
  for (final c in usableCues(cues)) {
    b
      ..writeln(i++)
      ..writeln('${formatTimestamp(c.start, decimal: ',')} --> '
          '${formatTimestamp(c.start + c.duration, decimal: ',')}')
      ..writeln(c.line(mode))
      ..writeln();
  }
  return b.toString();
}

/// cue 列表 → VTT 全文（首行 WEBVTT，时间戳用点，无序号）。
String serializeVtt(List<AsrCue> cues, {SubtitleMode mode = SubtitleMode.sourceOnly}) {
  final b = StringBuffer('WEBVTT\n');
  for (final c in usableCues(cues)) {
    b
      ..writeln()
      ..writeln('${formatTimestamp(c.start, decimal: '.')} --> '
          '${formatTimestamp(c.start + c.duration, decimal: '.')}')
      ..writeln(c.line(mode));
  }
  return b.toString();
}

/// 一条字幕产物文件：[lang] 为 null 表示主文件（仅原文 / 双语），否则为目标语言码。
class SubtitleFile {
  const SubtitleFile({required this.path, required this.ext, this.lang});

  final String path;
  final String ext; // 'srt' / 'vtt'
  final String? lang;

  /// 按钮文案后缀：`SRT` / `SRT·中译`。
  String get label => '${ext.toUpperCase()}${lang == null ? '' : '·${languageLabel(lang!)}译'}';
}

/// 文件名 → 译文语言码：`{itemId}.{lang}.srt|.vtt` 命中则返回 lang，否则 null。
/// 纯函数（不碰文件系统），便于单测文件名契约——译文文件全靠这个名字规则被列出来。
String? translationLangOf(String itemId, String fileName) {
  final m = RegExp('^${RegExp.escape(itemId)}\\.([a-zA-Z-]+)\\.(srt|vtt)\$')
      .firstMatch(fileName);
  return m?.group(1);
}

/// 字幕文件存取：`documents/subtitles/{itemId}.srt|.vtt`（与附件 documents/shares、
/// 标注 documents/annotations 同层的 app 私有目录）。
class SubtitleStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'subtitles'));
    await d.create(recursive: true);
    return d;
  }

  /// 指定条目与扩展名（'srt' / 'vtt'）的字幕文件。
  static Future<File> fileFor(String itemId, String ext) async =>
      File(p.join((await _dir()).path, '$itemId.$ext'));

  /// 该条目是否已有字幕产物（详情页「导出字幕」入口的显隐依据）。
  static Future<bool> exists(String itemId) async =>
      (await fileFor(itemId, 'srt')).existsSync();

  /// 该条目的**全部字幕文件**（主文件 + 各语言译文文件），详情页据此逐个列出。
  ///
  /// 译文文件是 `separate` 模式产物（`{itemId}.{lang}.srt|.vtt`），此前只落盘、
  /// UI 不展示，等于用户拿不到——翻译产出必须可见才有用。
  static Future<List<SubtitleFile>> listFiles(String itemId) async {
    final dir = await _dir();
    final out = <SubtitleFile>[];
    for (final ext in const ['srt', 'vtt']) {
      final main = File(p.join(dir.path, '$itemId.$ext'));
      if (main.existsSync()) out.add(SubtitleFile(path: main.path, ext: ext));
    }
    if (dir.existsSync()) {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        final lang = translationLangOf(itemId, name);
        if (lang == null) continue;
        out.add(SubtitleFile(path: e.path, ext: name.split('.').last, lang: lang));
      }
    }
    return out;
  }

  /// 双份同出：写 SRT 与 VTT。返回 SRT 路径（导出/分享默认入口）。
  /// 单份失败不吞另一份——两个文件各自独立写入，失败抛出由调用方按
  /// 「字幕失败不影响 human_md」处理。
  ///
  /// [mode] = [SubtitleMode.separate] 时主文件仍只写原文，另出一份
  /// `{itemId}.{targetLang}.srt|.vtt` 译文文件（缺译文的 cue 回退原文）；
  /// [targetLang] 为空则退化为主文件行为（不静默造半个产物）。
  static Future<String> save(
    String itemId,
    List<AsrCue> cues, {
    SubtitleMode mode = SubtitleMode.sourceOnly,
    String? targetLang,
  }) async {
    final srt = await fileFor(itemId, 'srt');
    final vtt = await fileFor(itemId, 'vtt');
    final mainMode = mode == SubtitleMode.separate ? SubtitleMode.sourceOnly : mode;
    await srt.writeAsString(serializeSrt(cues, mode: mainMode), flush: true);
    await vtt.writeAsString(serializeVtt(cues, mode: mainMode), flush: true);
    final lang = targetLang?.trim() ?? '';
    if (mode == SubtitleMode.separate && lang.isNotEmpty) {
      final trSrt = await fileFor('$itemId.$lang', 'srt');
      final trVtt = await fileFor('$itemId.$lang', 'vtt');
      await trSrt.writeAsString(serializeSrt(cues, mode: SubtitleMode.separate), flush: true);
      await trVtt.writeAsString(serializeVtt(cues, mode: SubtitleMode.separate), flush: true);
    }
    debugPrint('[Subtitle] saved ${cues.length} cues -> ${srt.path} (mode=${mode.name})');
    return srt.path;
  }
}
