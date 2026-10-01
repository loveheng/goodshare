/// 速记便签组装：把「文本段 + 行内媒体段」混合的输入转成可入库的 human_md。
///
/// SSOT：docs/design/rich-text-media.md §2 写入口径（2026-09-30 拍板①：本地行内媒体
/// 随便签作曲器开放，url = `local://<documents 内相对路径>` 相对标记——**绝不写绝对路径**
/// （iOS 沙盒容器 UUID 段随升级/恢复变动），渲染/IO 层经 resolveLocalMediaSrc 动态解析）
/// + ui-spec §4.6。
///
/// 设计约束：
/// - **媒体段序列化为标准 Markdown 媒体行**（`![alt](local://…)` / `[label](local://…)`），
///   三出口护栏全部继承：parse 进得来、serialize 出得去、blockToPlain 降级可读；
///   MCP `get_item` 契约零改动（桌面端看到的是文件路径，与条目 `file` 字段同语义）。
/// - **alt/label 保持原话**（rich-text-media.md §2）：规则层禁止类型前缀注入，
///   默认 label 也走构造方（录音段默认「录音」），保证 parse→serialize→parse 往返幂等。
/// - **含媒体便签豁免合并窗口**（2026-09-30 用户拍板）：合并链只对纯文本成立，
///   序列化产物由调用方路由——纯文本走 `TextCollector.collectText`（合并逻辑不变），
///   含媒体直发 `CollectCommand`（itemType=note，mode=scatter，永不并链）。
/// - 媒体段不做 AI 处理（行内媒体是用户领地）；note 类型摄入不入队（taskActionFor=null），
///   AI 回写无冲刷路径。
library;

/// 便签段模型：文本与行内媒体按序混排，保存时整体序列化为一个条目。
sealed class NoteSegment {
  const NoteSegment();
}

/// 文本段（可多行；待办模式在序列化时逐行转 `- [ ]`）。
final class NoteTextSegment extends NoteSegment {
  const NoteTextSegment(this.text);

  final String text;
}

/// 图片段（拍照 / 相册选图，已复制进 app 私有目录的绝对路径）。
final class NoteImageSegment extends NoteSegment {
  const NoteImageSegment(this.path, {this.alt = ''});

  final String path;

  /// 图片说明（默认空；详情页块编辑器可改）。
  final String alt;
}

/// 录音段（仅存音频，转写由详情页手动触发——2026-09-28 拍板口径）。
final class NoteAudioSegment extends NoteSegment {
  const NoteAudioSegment(this.path, {this.label = '录音'});

  final String path;

  /// 音频说明（默认「录音」，呈现在播放条上）。
  final String label;
}

/// 视频段（便签内嵌视频附件态，2026-10-01 拍板：mp4/mov 白名单直入库，
/// 门槛常量见 note_video_policy.dart；SSOT：note-video.md §2）。
final class NoteVideoSegment extends NoteSegment {
  const NoteVideoSegment(this.path, {this.label = '视频'});

  final String path;

  /// 视频说明（默认「视频」，呈现在封面占位卡上）。
  final String label;
}

/// 是否含媒体段（决定保存路由：豁免合并窗口）。
bool noteHasMedia(List<NoteSegment> segments) =>
    segments.any((s) => s is! NoteTextSegment);

/// 条目标题：首个非空文本行（折叠空白、截 30 字符）；全媒体无文字返回 null，
/// 由调用方决定兜底（如「图文便签」）。
String? noteTitleOf(List<NoteSegment> segments) {
  for (final s in segments) {
    if (s is! NoteTextSegment) continue;
    final lines = [
      for (final line in s.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) continue;
    final oneLine = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 30 ? '${oneLine.substring(0, 30)}…' : oneLine;
  }
  return null;
}

/// 序列化为 human_md：段与段以空行分隔（媒体行必须整行独立，rich-text-media.md §2）。
///
/// [todoMode]：开 = 文本段逐行转 `- [ ]` 待办（便利贴待办模式既有语义，
/// 空行跳过）；媒体段不参与转换。全空返回空串，调用方按「内容为空」处理。
String serializeNoteMd(List<NoteSegment> segments, {bool todoMode = false}) {
  final parts = <String>[];
  for (final s in segments) {
    switch (s) {
      case NoteTextSegment(:final text):
        if (todoMode) {
          final todos = [
            for (final line in text.split('\n'))
              if (line.trim().isNotEmpty) '- [ ] ${line.trim()}',
          ];
          if (todos.isNotEmpty) parts.add(todos.join('\n'));
        } else if (text.trim().isNotEmpty) {
          parts.add(text.trim());
        }
      case NoteImageSegment(:final path, :final alt):
        if (path.isNotEmpty) parts.add('![${_escapeAlt(alt)}]($path)');
      case NoteAudioSegment(:final path, :final label):
        if (path.isNotEmpty) parts.add('[${_escapeAlt(label)}]($path)');
      case NoteVideoSegment(:final path, :final label):
        if (path.isNotEmpty) parts.add('[${_escapeAlt(label)}]($path)');
    }
  }
  return parts.join('\n\n');
}

/// alt/label 走行内字面转义（与规则层 serializeInline 的 `\X` 口径一致），
/// 防 `]`/`\` 破坏媒体行结构；url 为绝对路径不含括号，原样透传。
String _escapeAlt(String raw) =>
    raw.replaceAllMapped(RegExp(r'[\[\]\\]'), (m) => '\\${m.group(0)}');
