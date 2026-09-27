import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../data/repository.dart';
import '../models/item.dart';

/// 系统分享入口：把 receive_sharing_intent 的事件归一成 CollectItem 落库。
/// 附件会复制到 app 私有目录（documents/shares/），不依赖源 app 的 content URI。
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
      final texts = <String>[];
      final files = <SharedMediaFile>[];
      for (final m in medias) {
        switch (m.type) {
          case SharedMediaType.text:
            if (m.message?.trim().isNotEmpty ?? false) texts.add(m.message!.trim());
          case SharedMediaType.url:
            texts.add(m.path.trim());
          case SharedMediaType.image:
          case SharedMediaType.video:
          case SharedMediaType.file:
            files.add(m);
        }
      }

      if (files.isNotEmpty) {
        final local = <String>[];
        String? mime;
        bool allImage = true;
        for (final f in files) {
          final saved = await _copyToAppDir(f.path, f.mimeType);
          if (saved != null) local.add(saved);
          mime ??= f.mimeType;
          if (f.type != SharedMediaType.image) allImage = false;
        }
        if (local.isNotEmpty) {
          await _repo.add(CollectItem(
            type: allImage ? CollectItem.typeImage : (files.length == 1 ? _typeOfMedia(files.first) : CollectItem.typeFile),
            title: _baseName(files.first.path),
            text: texts.isNotEmpty ? texts.join('\n') : null,
            mime: mime,
            tags: const [],
            files: local,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ));
        }
      }

      for (final t in texts) {
        final parsed = parseText(t);
        await _repo.add(CollectItem(
          type: parsed.type,
          title: parsed.title,
          text: parsed.text,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } catch (e) {
      debugPrint('[ShareIntake] handle error: $e');
    } finally {
      _busy = false;
    }
  }

  /// 文本/链接归一：
  /// - 纯 URL → LINK
  /// - 「标题\nURL」→ LINK，首行作标题
  /// - 其余 → TEXT
  ({String type, String? title, String text}) parseText(String raw) {
    final urlRe = RegExp(r'https?://\S+', caseSensitive: false);
    final match = urlRe.firstMatch(raw);
    if (match == null) {
      return (type: CollectItem.typeText, title: _firstLine(raw), text: raw);
    }
    final url = match.group(0)!;
    final around = raw.replaceFirst(url, '').trim();
    final isPureUrl = around.isEmpty && raw.trim() == url;
    return (
      type: CollectItem.typeLink,
      title: isPureUrl ? null : (around.isEmpty ? null : around.split('\n').first.trim()),
      text: raw,
    );
  }

  String? _firstLine(String s) {
    final line = s.trim().split('\n').first.trim();
    return line.isEmpty ? null : (line.length > 80 ? '${line.substring(0, 80)}…' : line);
  }

  String _typeOfMedia(SharedMediaFile m) => switch (m.type) {
        SharedMediaType.image => CollectItem.typeImage,
        SharedMediaType.video => CollectItem.typeVideo,
        SharedMediaType.file => CollectItem.typeFile,
        SharedMediaType.url => CollectItem.typeLink,
        SharedMediaType.text => CollectItem.typeText,
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
