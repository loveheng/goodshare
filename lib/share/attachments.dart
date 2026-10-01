import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// app 私有附件目录（documents/shares/），不存在则创建。
Future<Directory> appShareDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/shares');
  await dir.create(recursive: true);
  return dir;
}

/// 附件落盘：把外来源文件复制进 app 私有目录（documents/shares/），
/// 不依赖源 app 的 content URI（防撤销/失效）。分享摄入与 FAB 速记共用。
Future<String?> copyToAppDir(String sourcePath) async {
  try {
    final src = File(sourcePath);
    if (!await src.exists()) return null;
    final dir = await appShareDir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = sourcePath.contains('.') ? sourcePath.split('.').last : null;
    final name = ext == null || ext.length > 8 ? '$ts' : '$ts.$ext';
    final dest = File('${dir.path}/$name');
    await src.copy(dest.path);
    return dest.path;
  } catch (e) {
    debugPrint('[Attachments] copy failed: $e');
    return null;
  }
}

// ---------- 行内本地媒体 url（local:// 口径）----------
//
// SSOT：docs/design/rich-text-media.md §2（2026-09-30 拍板①）。
// human_md 里写 `local://<documents 内相对路径>`（如 local://shares/x.jpg），
// **绝不写绝对路径**——iOS 沙盒容器的 UUID 段在 App 升级/恢复后会变，
// 绝对路径硬编码进内容等于下次打开全裂。渲染/播放层经 [resolveLocalMediaSrc]
// 动态拼接当前 documents 目录；迁移多端同步时只需把 local:// 整体替换为云端 url。

String? _documentsPath;

Future<void> _ensureDocumentsPath() async {
  if (_documentsPath != null) return;
  _documentsPath = (await getApplicationDocumentsDirectory()).path;
}

/// 启动时预热 documents 路径缓存（main() 调用）——渲染层是同步解析，
/// 缓存未就绪的窗口会把 local:// 原样透传导致加载失败，必须先于 runApp 完成。
Future<void> warmDocumentsPath() => _ensureDocumentsPath();

/// 行内媒体 url → 渲染/IO 可用的源：local:// 解析为当前 documents 绝对路径；
/// http(s) / 历史绝对路径（本口径启用前的存量块）原样透传。
String resolveLocalMediaSrc(String url) {
  if (!url.startsWith('local://')) return url;
  final rel = url.substring('local://'.length);
  final base = _documentsPath;
  if (base == null || base.isEmpty) {
    // 理论不可达（main 预热）；真发生则透传并留痕，渲染层走失败三态不丢内容
    unawaited(_ensureDocumentsPath());
    debugPrint('[DEGRADE] local_media_base_not_ready url=$url');
    return url;
  }
  return '$base/$rel';
}

/// app 内绝对路径 → 行内媒体 url（local:// 相对标记）。
/// 路径不在 documents 内（理论不可达：作曲器文件均由 copyToAppDir 落盘）返回原路径，
/// 渲染层按历史绝对路径口径兼容。
Future<String> toLocalMediaUrl(String absPath) async {
  await _ensureDocumentsPath();
  final base = _documentsPath!;
  return absPath.startsWith('$base/') ? 'local://${absPath.substring(base.length + 1)}' : absPath;
}
