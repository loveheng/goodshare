import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 字幕产物（2026-09-28，设计见 docs/design/asr-subtitle.md）：
/// - [AsrCue]：带时间轴的单条字幕（VAD 分段产出，时间单位秒）；
/// - 序列化：SRT / VTT **双份同出**（2026-09-28 确认，序列化成本接近零）；
/// - [SubtitleStore]：落盘 `documents/subtitles/{itemId}.srt|.vtt`。
///   纯文件 IO，与 human_md 解耦；**不新增 inbox_items 字段**——字幕是否存在
///   按文件存在性判定（[SubtitleStore.exists]），详情页据此显隐「导出字幕」。
///   字幕失败不影响 human_md（「占位不卡死」策略的字幕侧延伸）。

/// 单条字幕 cue：`start`/`duration` 均为秒（VAD `SpeechSegment.start` 除以
/// sampleRate 得到），`text` 为该段转写文本。
class AsrCue {
  const AsrCue({
    required this.start,
    required this.duration,
    required this.text,
  });

  /// 段起始时间（秒）。
  final double start;

  /// 段时长（秒）。
  final double duration;

  /// 该段转写文本。
  final String text;

  Map<String, Object?> toJson() => {
        'start': start,
        'duration': duration,
        'text': text,
      };

  static AsrCue fromJson(Map<Object?, Object?> j) => AsrCue(
        start: (j['start'] as num).toDouble(),
        duration: (j['duration'] as num).toDouble(),
        text: j['text'] as String,
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
String serializeSrt(List<AsrCue> cues) {
  final b = StringBuffer();
  var i = 1;
  for (final c in usableCues(cues)) {
    b
      ..writeln(i++)
      ..writeln('${formatTimestamp(c.start, decimal: ',')} --> '
          '${formatTimestamp(c.start + c.duration, decimal: ',')}')
      ..writeln(c.text.trim())
      ..writeln();
  }
  return b.toString();
}

/// cue 列表 → VTT 全文（首行 WEBVTT，时间戳用点，无序号）。
String serializeVtt(List<AsrCue> cues) {
  final b = StringBuffer('WEBVTT\n');
  for (final c in usableCues(cues)) {
    b
      ..writeln()
      ..writeln('${formatTimestamp(c.start, decimal: '.')} --> '
          '${formatTimestamp(c.start + c.duration, decimal: '.')}')
      ..writeln(c.text.trim());
  }
  return b.toString();
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

  /// 双份同出：写 SRT 与 VTT。返回 SRT 路径（导出/分享默认入口）。
  /// 单份失败不吞另一份——两个文件各自独立写入，失败抛出由调用方按
  /// 「字幕失败不影响 human_md」处理。
  static Future<String> save(String itemId, List<AsrCue> cues) async {
    final srt = await fileFor(itemId, 'srt');
    final vtt = await fileFor(itemId, 'vtt');
    await srt.writeAsString(serializeSrt(cues), flush: true);
    await vtt.writeAsString(serializeVtt(cues), flush: true);
    debugPrint('[Subtitle] saved ${cues.length} cues -> ${srt.path}');
    return srt.path;
  }
}
