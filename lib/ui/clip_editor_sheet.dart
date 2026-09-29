import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/video_clips.dart';
import '../models/item.dart';

/// 视频切片编辑（2026-09-29 改版，设计 docs/design/video-clips.md §4）：
/// **标记优先**——「设为起点 / 设为终点」捕获播放位置只登记时间点（不触发处理，
/// 标记 ≠ 完成）；既有标记支持快速跳转、勾选链路子集（提取片段 / 转写 / 摘要）
/// 后逐段「处理」。校验 / 去重 / 步骤规整都在动作层，重复与非法回可行动提示。
Future<void> showClipEditorSheet(
  BuildContext context, {
  required ItemActionHandler handler,
  required InboxItem item,
  required bool vaultContext,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ClipEditorSheet(handler: handler, item: item, vaultContext: vaultContext),
  );
}

class _ClipEditorSheet extends StatefulWidget {
  const _ClipEditorSheet({required this.handler, required this.item, required this.vaultContext});

  final ItemActionHandler handler;
  final InboxItem item;
  final bool vaultContext;

  @override
  State<_ClipEditorSheet> createState() => _ClipEditorSheetState();
}

class _ClipEditorSheetState extends State<_ClipEditorSheet> {
  late final VideoPlayerController _controller =
      VideoPlayerController.file(File(widget.item.rawFilePath!));
  bool _ready = false;
  int? _start;
  final List<List<int>> _newMarks = []; // 本轮新打的标记 [startMs, endMs]
  final Set<String> _steps = {kClipStepExtract, kClipStepTranscribe, kClipStepSummary};

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (mounted) setState(() => _ready = true);
    }).catchError((Object e) {
      debugPrint('[ClipEditor] initialize failed: $e');
    });
    _controller.addListener(() {
      if (mounted) setState(() {}); // 播放位置驱动按钮态与进度条
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _fmt(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _markStart() => setState(() => _start = _controller.value.position.inMilliseconds);

  void _markEnd() {
    final messenger = ScaffoldMessenger.of(context);
    final s = _start;
    if (s == null) {
      messenger.showSnackBar(const SnackBar(content: Text('先点「设为起点」')));
      return;
    }
    final e = _controller.value.position.inMilliseconds;
    if (!isValidClipInterval(s, e)) {
      messenger.showSnackBar(const SnackBar(content: Text('区间需 1 秒 ~ 30 分钟，且终点在起点之后')));
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
    final messenger = ScaffoldMessenger.of(context);
    var ok = 0;
    String? failReason;
    for (final c in _newMarks) {
      try {
        await widget.handler.execute(
          ClipCommand(widget.item.id!, startMs: c[0], endMs: c[1]),
          vaultContext: widget.vaultContext,
        );
        ok++;
      } on ActionException catch (e) {
        failReason = e.hint == null ? e.message : '${e.message}：${e.hint}';
      }
    }
    messenger.showSnackBar(SnackBar(
      content: Text(ok > 0 ? '已标记 $ok 个区间（处理后才算收藏完成）' : failReason ?? '未能标记'),
    ));
    if (ok > 0 && mounted) {
      setState(() => _newMarks.clear());
      Navigator.pop(context, true);
    }
  }

  /// 对既有标记执行所选链路子集（extract/transcribe/summary）。
  Future<void> _process(ClipSegment seg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.handler.execute(
        ClipProcessCommand(widget.item.id!,
            startMs: seg.startMs, endMs: seg.endMs, steps: _steps.toList()),
        vaultContext: widget.vaultContext,
      );
      messenger.showSnackBar(SnackBar(
        content: Text('已开始处理（${_steps.map(_stepLabel).join(' / ')}），完成后在「关键区间」查看'),
      ));
      if (mounted) Navigator.pop(context, true);
    } on ActionException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.hint == null ? e.message : '${e.message}：${e.hint}')));
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
    final existing = parseClipsJson(widget.item.clipsJson);
    final pos = _controller.value.position.inMilliseconds;
    final dur = _controller.value.duration.inMilliseconds;
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
            if (_ready && _controller.value.isInitialized)
              GestureDetector(
                onTap: () => setState(() {
                  _controller.value.isPlaying ? _controller.pause() : _controller.play();
                }),
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                ),
              )
            else
              const SizedBox(
                height: 140,
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_ready) ...[
              Slider(
                value: dur > 0 ? pos.clamp(0, dur).toDouble() : 0,
                max: dur > 0 ? dur.toDouble() : 1,
                onChanged: (v) => _controller.seekTo(Duration(milliseconds: v.round())),
              ),
              Row(children: [
                IconButton(
                  onPressed: () => setState(() {
                    _controller.value.isPlaying ? _controller.pause() : _controller.play();
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
                          onPressed: _ready
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
