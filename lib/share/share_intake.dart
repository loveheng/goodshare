import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../data/repository.dart';
import '../models/item.dart';

/// 系统分享入口：把 receive_sharing_intent 的事件归一成 InboxItem 落库。
/// 附件会复制到 app 私有目录（documents/shares/），不依赖源 app 的 content URI。
/// 分层约定：文本/链接写 raw_content，附件写 raw_file_path（每附件一条）；
/// human_* 由 AI 队列占位管线填充，此处只入原始层。
class ShareIntake {
  ShareIntake(this._repo);

  final Repository _repo;
  bool _busy = false;

  Future<void> init() async {
    // 冷启动（app 未运行时通过分享拉起）
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isNotEmpty) {
      await _handle(initial);
      await ReceiveSharingIntent.instance.reset();
    }
    // app 存活期间收到的新分享
    ReceiveSharingIntent.instance.getMediaStream().listen(
      (list) async {
        if (list.isNotEmpty) {
          await _handle(list);
          await ReceiveSharingIntent.instance.reset();
        }
      },
      onError: (Object e) => debugPrint('[ShareIntake] stream error: $e'),
    );
  }

  Future<void> _handle(List<SharedMediaFile> medias) async {
    if (_busy) return; // 事件流可能重放，防重复入库
    _busy = true;
    try {
      final (texts, files) = classify(medias);
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final f in files) {
        final saved = await _copyToAppDir(f.path, f.mimeType);
        if (saved == null) continue; // 源文件失效，丢弃该附件
        final t = _typeOfMedia(f);
        await _repo.add(InboxItem(
          itemType: t,
          sourceType: t,
          humanTitle: _baseName(f.path),
          rawFilePath: saved,
          createdAt: now,
        ));
      }

      for (final t in texts) {
        final parsed = parseText(t);
        await _repo.add(InboxItem(
          itemType: parsed.type,
          sourceType: parsed.type,
          humanTitle: parsed.title,
          rawContent: parsed.text,
          createdAt: now,
        ));
      }
    } catch (e) {
      debugPrint('[ShareIntake] handle error: $e');
    } finally {
      _busy = false;
    }
  }

  /// 事件分类：文本进 texts、附件进 files。
  /// 插件 1.9.0 Android 侧（ReceiveSharingIntentPlugin.toJsonObject）把分享文本
  /// 放进 path（`path ?: text`），message 恒为 null——文本类型必须以 path 为准，
  /// message 仅作未来版本兜底，字段以 pub 缓存插件源码为准。
  @visibleForTesting
  static (List<String>, List<SharedMediaFile>) classify(List<SharedMediaFile> medias) {
    final texts = <String>[];
    final files = <SharedMediaFile>[];
    for (final m in medias) {
      switch (m.type) {
        case SharedMediaType.text:
          final t = (m.message?.trim().isNotEmpty ?? false) ? m.message!.trim() : m.path.trim();
          if (t.isNotEmpty) texts.add(t);
        case SharedMediaType.url:
          if (m.path.trim().isNotEmpty) texts.add(m.path.trim());
        case SharedMediaType.image:
        case SharedMediaType.video:
        case SharedMediaType.file:
          files.add(m);
      }
    }
    return (texts, files);
  }

  /// 文本/链接归一：
  /// - 纯 URL → url
  /// - 「标题\nURL」→ url，首行作标题
  /// - 其余 → note
  ({String type, String? title, String text}) parseText(String raw) {
    final urlRe = RegExp(r'https?://\S+', caseSensitive: false);
    final match = urlRe.firstMatch(raw);
    if (match == null) {
      return (type: InboxItem.typeNote, title: _firstLine(raw), text: raw);
    }
    final url = match.group(0)!;
    final around = raw.replaceFirst(url, '').trim();
    final isPureUrl = around.isEmpty && raw.trim() == url;
    return (
      type: InboxItem.typeUrl,
      title: isPureUrl ? null : (around.isEmpty ? null : around.split('\n').first.trim()),
      text: raw,
    );
  }

  String? _firstLine(String s) {
    final line = s.trim().split('\n').first.trim();
    return line.isEmpty ? null : (line.length > 80 ? '${line.substring(0, 80)}…' : line);
  }

  String _typeOfMedia(SharedMediaFile m) => switch (m.type) {
        SharedMediaType.image => InboxItem.typeImage,
        SharedMediaType.video => InboxItem.typeVideo,
        SharedMediaType.file => InboxItem.typeDocument,
        SharedMediaType.url => InboxItem.typeUrl,
        SharedMediaType.text => InboxItem.typeNote,
      };

  /// 复制到 app 私有目录；返回落盘路径，失败返回 null（源文件失效时不让整条分享丢失）。
  Future<String?> _copyToAppDir(String sourcePath, String? mime) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return null;
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/shares');
      await dir.create(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ext = sourcePath.contains('.') ? sourcePath.split('.').last : null;
      final name = ext == null || ext.length > 8 ? '$ts' : '$ts.$ext';
      final dest = File('${dir.path}/$name');
      await src.copy(dest.path);
      return dest.path;
    } catch (e) {
      debugPrint('[ShareIntake] copy failed: $e');
      return null;
    }
  }

  String _baseName(String path) {
    final base = path.split('/').last;
    return base.length > 60 ? '${base.substring(0, 60)}…' : base;
  }
}
