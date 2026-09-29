/// 视频切片（关键区间）纯模型与工具（2026-09-29，设计 docs/design/video-clips.md）。
///
/// **标记 ≠ 处理**（2026-09-29 用户拍板改版）：标记只记时间点（播放时快速跳转），
/// 处理由用户显式触发且可勾选链路子集——①提取视频片段（精确重编码剪辑）
/// ②转写文本 ③摘要（E2：摘要自动带动转写前置）。止步于片段本身合法。
/// 切片结果为**原条目附属记录**（schema v10 `clips_json`，JSON 列吸收结构演进）；
/// 向量按区间序号写 item_embeddings（引擎二期）。
library;

import 'dart:convert';

/// 处理步骤标识（编码进队列动作串：e/t/s）。
const kClipStepExtract = 'extract';
const kClipStepTranscribe = 'transcribe';
const kClipStepSummary = 'summary';

/// 步骤固定顺序（链路语义：提取 → 转写 → 摘要）。
const kClipStepOrder = [kClipStepExtract, kClipStepTranscribe, kClipStepSummary];

/// 切段状态：标记 ≠ 完成，只有链路处理完才算完成（用户拍板，UI 必须明示）。
const kClipStatusMarked = 'marked';
const kClipStatusProcessing = 'processing';
const kClipStatusDone = 'done';
const kClipStatusFailed = 'failed';

/// 规整用户勾选的步骤子集：未知步骤剔除、按链路顺序排列、去重；
/// **E2 拍板：勾「摘要」自动带动「转写」前置**（摘要依赖转写文本）。
List<String> normalizeClipSteps(List<String> steps) {
  final set = steps.toSet();
  if (set.contains(kClipStepSummary)) set.add(kClipStepTranscribe);
  return [
    for (final s in kClipStepOrder)
      if (set.contains(s)) s,
  ];
}

/// 单个切片标记及其产出（段结构 v2，2026-09-29）。
///
/// - `status == marked`：仅时间点，未处理（用户可跳转，不算收藏完成）；
/// - `status == processing`：已入队待跑；
/// - `status == done / failed`：链路跑完 / 失败（note 说明哪一步失败，人与 AI 同读一份）。
/// - 各步骤产物按需出现：clipPath（提取的片段文件，相对 documents）、text（转写）、
///   summary（摘要）——止步于片段本身时只有 clipPath。
class ClipSegment {
  const ClipSegment({
    required this.startMs,
    required this.endMs,
    this.steps = const [],
    this.status = kClipStatusMarked,
    this.clipPath,
    this.text,
    this.summary,
    this.note,
    required this.createdAt,
  });

  final int startMs;
  final int endMs;

  /// 用户勾选的处理范围（规整后；空 = 纯标记待选步骤）。
  final List<String> steps;
  final String status;

  /// 提取的片段文件（相对 app documents，如 clip_segments/xxx.mp4）。
  final String? clipPath;
  final String? text;
  final String? summary;

  /// 失败 / 空产出 / 部分失败原因。
  final String? note;
  final int createdAt;

  int get durationMs => endMs - startMs;

  Map<String, Object?> toJson() => {
        'start_ms': startMs,
        'end_ms': endMs,
        'steps': steps,
        'status': status,
        if (clipPath != null) 'clip_path': clipPath,
        if (text != null) 'text': text,
        if (summary != null) 'summary': summary,
        if (note != null) 'note': note,
        'created_at': createdAt,
      };

  factory ClipSegment.fromJson(Map<String, Object?> j) {
    final s = j['start_ms'];
    final e = j['end_ms'];
    if (s is! int || e is! int || e <= s) {
      throw const FormatException('切片区间非法（start_ms/end_ms）');
    }
    return ClipSegment(
      startMs: s,
      endMs: e,
      steps: j['steps'] is List
          ? normalizeClipSteps([for (final x in (j['steps'] as List)) if (x is String) x])
          : const [],
      status: j['status'] is String ? j['status'] as String : kClipStatusMarked,
      clipPath: j['clip_path'] is String ? j['clip_path'] as String : null,
      text: j['text'] is String ? j['text'] as String : null,
      summary: j['summary'] is String ? j['summary'] as String : null,
      note: j['note'] is String ? j['note'] as String : null,
      createdAt: j['created_at'] is int ? j['created_at'] as int : 0,
    );
  }

  ClipSegment copyWith({
    List<String>? steps,
    String? status,
    String? clipPath,
    String? text,
    String? summary,
    String? note,
  }) =>
      ClipSegment(
        startMs: startMs,
        endMs: endMs,
        steps: steps ?? this.steps,
        status: status ?? this.status,
        clipPath: clipPath ?? this.clipPath,
        text: text ?? this.text,
        summary: summary ?? this.summary,
        note: note ?? this.note,
        createdAt: createdAt,
      );
}

/// 解析条目的 clips_json（防御：非 JSON / 坏段跳过，不拖垮整条目）。
List<ClipSegment> parseClipsJson(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final Object? obj;
  try {
    obj = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (obj is! List) return const [];
  final out = <ClipSegment>[];
  for (final e in obj) {
    if (e is! Map) continue;
    try {
      out.add(ClipSegment.fromJson(e.cast<String, Object?>()));
    } on FormatException {
      continue;
    }
  }
  return out;
}

String encodeClipsJson(List<ClipSegment> clips) =>
    jsonEncode([for (final c in clips) c.toJson()]);

/// 区间合法性（动作层与 UI 共用）：0 ≤ start < end，时长 [1s, 30min]。
bool isValidClipInterval(int startMs, int endMs) =>
    startMs >= 0 &&
    endMs > startMs &&
    (endMs - startMs) >= 1000 &&
    (endMs - startMs) <= 30 * 60 * 1000;

/// 把队列产出合并进既有切片列表（按 startMs/endMs 精确匹配；未找到则追加自愈）。
List<ClipSegment> mergeClipResult(List<ClipSegment> clips, ClipSegment result) {
  final idx =
      clips.indexWhere((c) => c.startMs == result.startMs && c.endMs == result.endMs);
  if (idx == -1) return [...clips, result];
  return [...clips]..[idx] = result;
}

/// ASR 用：从源视频提取区间音轨参数（16k 单声道 wav，pcm_s16le 内置编码器）。
List<String> buildClipAudioArgs(String input, String output, int startMs, int endMs) => [
      '-y',
      '-ss',
      (startMs / 1000).toStringAsFixed(3),
      '-i',
      input,
      '-t',
      ((endMs - startMs) / 1000).toStringAsFixed(3),
      '-vn',
      '-map',
      '0:a:0',
      '-c:a',
      'pcm_s16le',
      output,
    ];

/// 提取视频片段参数（E1 拍板：**精确重编码**）。
/// - min → min_gpl 变体引入 libx264（APK 增重换逐帧准确剪辑）；
/// - `-ss` 输入侧快 seek + `-t` 时长，重编码后切点帧级准确；
/// - crf 23 + veryfast：体积/速度平衡；faststart 便于播放器秒开。
List<String> buildClipCutArgs(String input, String output, int startMs, int endMs) => [
      '-y',
      '-ss',
      (startMs / 1000).toStringAsFixed(3),
      '-i',
      input,
      '-t',
      ((endMs - startMs) / 1000).toStringAsFixed(3),
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '23',
      '-c:a',
      'aac',
      '-movflags',
      '+faststart',
      output,
    ];
