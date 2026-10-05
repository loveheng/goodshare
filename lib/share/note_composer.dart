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

import '../doc/rich_text.dart' show MediaSuffix, classifyMediaUrl;

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

/// 条目标题（2026-10-03 拍板「标题独立，与 md 无关」）：取用户写的**第一个
/// 一级标题行**（`# 标题`，跨段按序扫描；`## ` 二级不算）；**保留行内标记**
/// （如 `<u>` 下划线）——标题文本是一级标题行原文，不在此处剥壳。
///
/// 剥壳/样式由**渲染层**按需决定（口径不同源）：
/// - 详情页顶栏标题（`item_detail_page._buildTitle`）与列表/搜索预览
///   （`InboxItem.preview`）都是纯文本展示，对标题做行内剥壳，
///   避免顶栏/卡片出现 `<u>` 残壳；
/// - 下划线等行内格式只在详情页**正文阅读态**（`ContentBody` / `RichTextView`）
///   呈现，与正文同源。
///
/// 没有一级标题返回 null，由调用方兜底（速记保存不写 human_title，详情页
/// 落「笔记时间」时间标题 _timeTitle 口径）。
String? noteTitleOf(List<NoteSegment> segments) {
  for (final s in segments) {
    if (s is! NoteTextSegment) continue;
    for (final line in s.text.split('\n')) {
      final m = RegExp(r'^#\s+(.+)$').firstMatch(line.trim());
      if (m != null) {
        final title = m.group(1)!.trim();
        if (title.isNotEmpty) return title;
      }
    }
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

/// [_escapeAlt] 的逆：`\X` → `X`（X ∈ [ ] \）。
String _unescapeAlt(String raw) =>
    raw.replaceAllMapped(RegExp(r'\\([\[\]\\])'), (m) => m.group(1)!);

/// human_md → 作曲器草稿行（编辑器统一 2026-10-03：详情已有条目 → 段序列）。
///
/// 已知结构处置（用户拍板「字面文本保留」）：
/// - `local://` 媒体行 → 媒体段行（`['i'/'a'/'v', url, label?]`，alt/label 反转义随行）；
/// - 文本块（含 `# ` 标题、行内样式）→ `['t', 原文]`——编辑器 seedQuickNote
///   恢复所见即所得（标题转行级档位、行内标记转 runs），序列化时逆变换回写；
/// - 其余结构（列表/引用/代码块/外链图片行等，段模型不认识）→ 整块**字面保留**
///   为文本段，保存原样回写，查看态渲染不受影响。
List<List<String>> noteMdToDraftRows(String md) {
  final rows = <List<String>>[];
  for (var chunk in md.split(RegExp(r'\n[ \t]*\n'))) {
    chunk = chunk.trim();
    if (chunk.isEmpty) continue;
    rows.add(_mediaLineRow(chunk) ?? ['t', chunk]);
  }
  return rows;
}

/// 单行且整体是 `local://` 媒体行 → 媒体段行；否则 null（文本段）。
/// 非本地 url（http 图片/链接行等）不认——字面保留，防误吞用户文本。
List<String>? _mediaLineRow(String chunk) {
  if (chunk.contains('\n')) return null; // 媒体行必须整行独立（单行块）
  final m = _localMediaLine.firstMatch(chunk);
  if (m == null) return null;
  final isImage = m.group(1) == '!';
  final url = m.group(3)!;
  final text = _unescapeAlt(m.group(2)!);
  if (isImage) {
    // 图片行 ![alt](local://…)
    return ['i', url, if (text.isNotEmpty) text];
  }
  // 音/视频行 [label](local://…)，按后缀分类（不可读后缀归视频占位卡）
  final suffix = classifyMediaUrl(url);
  final kind =
      suffix == MediaSuffix.audioPlayable || suffix == MediaSuffix.audioDegrade
      ? 'a'
      : 'v';
  return [kind, url, if (text.isNotEmpty) text];
}

/// `![alt](local://…)` 或 `[label](local://…)` 整行匹配（alt/label 允许
/// `\X` 转义的 `]`；url 无空白——本地相对标记不含空格）。
final RegExp _localMediaLine = RegExp(
  r'^(!?)\[((?:[^\\\]]|\\.)*)\]\((local://\S+)\)$',
);
