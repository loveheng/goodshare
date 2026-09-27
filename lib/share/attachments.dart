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
