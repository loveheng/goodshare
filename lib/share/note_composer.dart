import '../models/item.dart';

/// 速记组装：把「文本段 + 语音段」混合的输入转成可入库的条目字段。
///
/// SSOT：docs/design/ui-spec.md §4.6（速记支持语音录入与文本混合）。
///
/// 设计约束：
/// - **不新增 collect_mode**——复用 `appendix_json` 段结构承载多段，避免动枚举
///   牵动合并窗口逻辑（`TextCollector` 只处理 `merge`）。混合条目即普通可编辑条目。
/// - **语音段不在录入时转写**——录音只存音频（2026-09-28 拍板：Sherpa 长任务曾
///   堵死整个 AI 队列）。转写由用户后续手动触发，结果回填到该段的 `text`。
/// - 语音段的 `text` 为空是**正常态**（待转写），不是失败。
abstract class NoteComposer {
  /// 文本段。
  AppendixEntry textSegment(String text, {int? ts});

  /// 语音段（只存音频路径，不转写）。
  AppendixEntry voiceSegment(String path, {int? ts});

  /// 拼接 `raw_content`：各段**非空**文本按段序连接。
  ///
  /// 未转写的语音段无文本，不产生占位噪声（不写「[语音待转写]」）——
  /// 否则原始层会污染检索与 AI 上下文。段本身仍保留在 appendix，UI 据此显示待转写。
  String rawContentOf(List<AppendixEntry> segments);

  /// 主附件路径：首个语音段的音频；无语音段返回 null。
  ///
  /// `rawFilePath` 只能承载一个文件，故取首个语音段；其余语音段留在 appendix。
  String? primaryPathOf(List<AppendixEntry> segments);

  /// 是否含语音段（决定详情页是否给出转写入口）。
  bool hasVoice(List<AppendixEntry> segments);
}

/// 默认实现（纯函数，可单测）。
class DefaultNoteComposer implements NoteComposer {
  const DefaultNoteComposer();

  @override
  AppendixEntry textSegment(String text, {int? ts}) => AppendixEntry(
        ts: ts ?? DateTime.now().millisecondsSinceEpoch,
        text: text,
        source: kSegmentText,
      );

  @override
  AppendixEntry voiceSegment(String path, {int? ts}) => AppendixEntry(
        ts: ts ?? DateTime.now().millisecondsSinceEpoch,
        text: '',
        source: kSegmentVoice,
        path: path,
      );

  @override
  String rawContentOf(List<AppendixEntry> segments) => segments
      .map((s) => s.text.trim())
      .where((t) => t.isNotEmpty)
      .join('\n\n');

  @override
  String? primaryPathOf(List<AppendixEntry> segments) {
    for (final s in segments) {
      if (s.isVoice && (s.path?.isNotEmpty ?? false)) return s.path;
    }
    return null;
  }

  @override
  bool hasVoice(List<AppendixEntry> segments) => segments.any((s) => s.isVoice);
}
