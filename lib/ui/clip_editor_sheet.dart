import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/video_clips.dart';
import 'toast.dart';
import '../data/block_artifacts.dart' show BlockArtifactKind;
import '../doc/rich_text.dart' show MarkdownSubsetParser, VideoBlock;
import '../models/item.dart';
import '../share/attachments.dart' show resolveLocalMediaSrc;

/// 视频切片编辑（2026-09-29 改版，设计 docs/design/video-clips.md §4）：
/// **标记优先**——「设为起点 / 设为终点」捕获播放位置只登记时间点（不触发处理，
/// 标记 ≠ 完成）；既有标记支持快速跳转、勾选链路子集（提取片段 / 转写 / 摘要）
/// 后逐段「处理」。校验 / 去重 / 步骤规整都在动作层，重复与非法回可行动提示。
Future<void> showClipEditorSheet(
  BuildContext context, {
  required ItemActionHandler handler,
  required InboxItem item,
  required bool vaultContext,
  String? blockKey,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ClipEditorSheet(
      handler: handler,
      item: item,
      vaultContext: vaultContext,
      blockKey: blockKey,
    ),
  );
}

class _ClipEditorSheet extends StatefulWidget {
  const _ClipEditorSheet({
    required this.handler,
    required this.item,
    required this.vaultContext,
    this.blockKey,
  });

  final ItemActionHandler handler;
  final InboxItem item;
  final bool vaultContext;

  /// 视频块 key（块级切片 2026-10-05）：行内 `local://` = 该块切片（区间按块
  /// 隔离、源为块文件）；null / 顶级 'item' = 条目级切片（行为不变）。
  final String? blockKey;

  @override
  State<_ClipEditorSheet> createState() => _ClipEditorSheetState();
}

class _ClipEditorSheetState extends State<_ClipEditorSheet> {
  // 来源分流（2026-10-04 修空白崩溃）：rawFilePath 可能是 null（速记内嵌视频
  // 走 human_md 块，无条目级附件）或 content:// URI（引用模式，File 打不开）——
  // 原先 `File(rawFilePath!)` 在 initState 空指针，Sheet 打开即一片空白。
  // 2026-10-05 修「弹框永久转圈」：null 控制器原实现既不报错也不就绪，
  // 转圈永挂=功能不可用——回退 human_md 首个视频块，仍无源则显式错误态。
  late final VideoPlayerController? _controller = _buildController();
  String? _error;
  Timer? _initTimeout;

  VideoPlayerController? _buildController() {
    // 块级切片（2026-10-05）：行内视频块源 = blockKey 本身（blockKey 即正文
    // 媒体行的 local:// url，逐字相等）。
    final key = widget.blockKey;
    if (key != null &&
        key != BlockArtifactKind.topLevelKey &&
        key.startsWith('local://')) {
      final f = File(resolveLocalMediaSrc(key));
      return f.existsSync() ? VideoPlayerController.file(f) : null;
    }
    final raw = widget.item.rawFilePath;
    if (raw != null && raw.isNotEmpty) {
      if (raw.startsWith('content://')) {
        return VideoPlayerController.contentUri(Uri.parse(raw));
      }
      return VideoPlayerController.file(File(resolveLocalMediaSrc(raw)));
    }
    return _firstVideoBlockController();
  }

  /// 条目级附件缺失时的回退源：human_md 里第一个视频块（速记内嵌视频）。
  VideoPlayerController? _firstVideoBlockController() {
    final md = widget.item.humanMd;
    if (md == null || md.isEmpty) return null;
    for (final b in const MarkdownSubsetParser().parse(md)) {
      if (b is VideoBlock && b.url.isNotEmpty) {
        final file = File(resolveLocalMediaSrc(b.url));
        if (file.existsSync()) return VideoPlayerController.file(file);
      }
    }
    return null;
  }

  bool _ready = false;
  int? _start;
  final List<List<int>> _newMarks = []; // 本轮新打的标记 [startMs, endMs]
  final Set<String> _steps = {kClipStepExtract, kClipStepTranscribe, kClipStepSummary};

  @override
  void initState() {
    super.initState();
    final c = _controller;
    if (c == null) {
      _error = '未找到可切片的视频文件';
      return;
    }
    // 初始化挂死兜底（contentUri 权限/损坏文件可能永不回调）：转圈最多
    // 10s 后转可行动错误态
    _initTimeout = Timer(const Duration(seconds: 10), () {
      if (mounted && !_ready) {
        setState(() => _error = '视频加载超时，请退出重试或检查文件');
      }
    });
    c.initialize().then((_) {
      _initTimeout?.cancel();
      if (mounted) setState(() => _ready = true);
    }).catchError((Object e) {
      _initTimeout?.cancel();
      debugPrint('[ClipEditor] initialize failed: $e');
      if (mounted) setState(() => _error = '视频加载失败：$e');
    });
    c.addListener(() {
      if (mounted) setState(() {}); // 播放位置驱动按钮态与进度条
    });
  }

  @override
  void dispose() {
    _initTimeout?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  String _fmt(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _markStart() =>
      setState(() => _start = _controller?.value.position.inMilliseconds);

  void _markEnd() {
    final s = _start;
    if (s == null) {
      ToastManager.show('先点「设为起点」', kind: ToastKind.error);
      return;
    }
    final e = _controller?.value.position.inMilliseconds ?? 0;
    if (!isValidClipInterval(s, e)) {
      ToastManager.show('区间需 1 秒 ~ 30 分钟，且终点在起点之后', kind: ToastKind.error);
      return;
    }
    setState(() {
      _newMarks.add([s, e]);
      _start = null;
    });
  }

  /// 标记 ≠ 完成：保存只登记时间点，不触发任何处理。
  Future<void> _saveMarks() async {
    if (_newMarks.isEmpty) return;
    var ok = 0;
    String? failReason;
    for (final c in _newMarks) {
      try {
        await widget.handler.execute(
          ClipCommand(widget.item.id!,
              startMs: c[0], endMs: c[1], blockKey: widget.blockKey),
          vaultContext: widget.vaultContext,
        );
        ok++;
      } on ActionException catch (e) {
        failReason = e.hint == null ? e.message : '${e.message}：${e.hint}';
      }
    }
    ToastManager.show(
      ok > 0 ? '已标记 $ok 个区间（处理后才算收藏完成）' : failReason ?? '未能标记',
      kind: ok > 0 ? ToastKind.success : ToastKind.error,
    );
    if (ok > 0 && mounted) {
      setState(() => _newMarks.clear());
      Navigator.pop(context, true);
    }
  }

  /// 对既有标记执行所选链路子集（extract/transcribe/summary）。
  Future<void> _process(ClipSegment seg) async {
    try {
      await widget.handler.execute(
        ClipProcessCommand(widget.item.id!,
            startMs: seg.startMs,
            endMs: seg.endMs,
            steps: _steps.toList(),
            blockKey: widget.blockKey),
        vaultContext: widget.vaultContext,
      );
      ToastManager.show(
          '已开始处理（${_steps.map(_stepLabel).join(' / ')}），完成后在「关键区间」查看');
      if (mounted) Navigator.pop(context, true);
    } on ActionException catch (e) {
      ToastManager.show(
          e.hint == null ? e.message : '${e.message}：${e.hint}',
          kind: ToastKind.error);
    }
  }

  String _stepLabel(String s) => switch (s) {
        kClipStepExtract => '提取',
        kClipStepTranscribe => '转写',
        kClipStepSummary => '摘要',
        _ => s,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 既有区间按块过滤（块级化 2026-10-05）：行内块只看本块区间，与条目级/
    // 其他视频块互不混淆（'item' 哨兵归一化为条目级 null，与落库口径一致）。
    final inlineKey =
        widget.blockKey != null && widget.blockKey != BlockArtifactKind.topLevelKey
            ? widget.blockKey
            : null;
    final existing = parseClipsJson(widget.item.clipsJson)
        .where((c) => c.blockKey == inlineKey)
        .toList();
    final pos = _controller?.value.position.inMilliseconds ?? 0;
    final dur = _controller?.value.duration.inMilliseconds ?? 0;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text('视频切片', style: Theme.of(context).textTheme.titleMedium)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
            Text('标记仅记时间点，处理后才算收藏完成',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (_error != null)
              Container(
                height: 140,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(16),
                color: scheme.errorContainer,
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onErrorContainer)),
              )
            else if (_ready &&
                _controller != null &&
                _controller.value.isInitialized &&
                (_controller.value.size.width) > 0)
              GestureDetector(
                onTap: () => setState(() {
                  _controller.value.isPlaying
                      ? _controller.pause()
                      : _controller.play();
                }),
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                ),
              )
            else if (_ready && _controller != null && _controller.value.isInitialized)
              // 音频源（块级切片扩展 2026-10-05）：无视频轨，AspectRatio(0) 会
              // 布局溢出——给等高占位；播放 / 打点 / 进度条照常工作。
              Container(
                height: 140,
                alignment: Alignment.center,
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.graphic_eq,
                  size: 40,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              const SizedBox(
                height: 140,
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_ready && _controller != null) ...[
              Slider(
                value: dur > 0 ? pos.clamp(0, dur).toDouble() : 0,
                max: dur > 0 ? dur.toDouble() : 1,
                onChanged: (v) => _controller.seekTo(Duration(milliseconds: v.round())),
              ),
              Row(children: [
                IconButton(
                  onPressed: () => setState(() {
                    _controller.value.isPlaying
                        ? _controller.pause()
                        : _controller.play();
                  }),
                  icon: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                Text('${_fmt(pos)} / ${_fmt(dur)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ],
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _ready ? _markStart : null,
                  icon: const Icon(Icons.flag, size: 18),
                  label: Text(_start == null ? '设为起点' : '起点 ${_fmt(_start!)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _start != null ? _markEnd : null,
                  icon: const Icon(Icons.outlined_flag, size: 18),
                  label: const Text('设为终点'),
                ),
              ),
            ]),
            if (_newMarks.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final c in _newMarks)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.bookmark_add_outlined, size: 18),
                  title: Text('${_fmt(c[0])} → ${_fmt(c[1])}（时长 ${_fmt(c[1] - c[0])}）'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => setState(() => _newMarks.remove(c)),
                  ),
                ),
              FilledButton.icon(
                onPressed: _saveMarks,
                icon: const Icon(Icons.bookmark_added, size: 18),
                label: Text('保存 ${_newMarks.length} 个标记（不触发处理）'),
              ),
            ],
            if (existing.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('已标记区间', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final seg in existing)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            '${_fmt(seg.startMs)} → ${_fmt(seg.endMs)} · '
                            '${switch (seg.status) {
                                kClipStatusMarked => '已标记',
                                kClipStatusProcessing => '处理中…',
                                kClipStatusDone => '已完成',
                                _ => '失败',
                              }}',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: (_ready && _controller != null)
                              ? () => _controller
                                  .seekTo(Duration(milliseconds: seg.startMs))
                              : null,
                          icon: const Icon(Icons.skip_next, size: 16),
                          label: const Text('跳转'),
                        ),
                      ]),
                      if (seg.note != null)
                        Text(seg.note!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: seg.status == kClipStatusFailed
                                        ? scheme.error
                                        : scheme.onSurfaceVariant)),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final s in kClipStepOrder)
                            FilterChip(
                              label: Text(_stepLabel(s),
                                  style: Theme.of(context).textTheme.labelSmall),
                              selected: _steps.contains(s),
                              visualDensity: VisualDensity.compact,
                              onSelected: (v) => setState(() {
                                v ? _steps.add(s) : _steps.remove(s);
                              }),
                            ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          onPressed: _steps.isEmpty
                              ? null
                              : () => _process(seg),
                          icon: const Icon(Icons.play_circle_outline, size: 18),
                          label: const Text('处理'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 4),
            Text(
              '处理可勾选「提取片段 / 转写 / 摘要」任意子集：片段可止步于本身；'
              '勾摘要会自动先转写。处理进度在 AI 任务队列查看。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
