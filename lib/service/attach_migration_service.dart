import 'package:flutter/foundation.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../doc/attach.dart';
import '../models/item.dart';
import '../share/attachments.dart';

/// 引用附件迁移服务（content-pipeline §7 引用模式兜底）。
///
/// 编排「锁外大文件复制 + 锁内持有态交换」两段：
/// 1. [migrateOne]：把 ref 原件复制进私有目录（documents/shares/，耗时 IO
///    不进 Repository.synchronized 写锁），成功后发 [MigrateAttachCommand]
///    完成防呆校验（ref 态 / 副本存在 / 乐观锁）与 DB 交换；
/// 2. [migrateAll]：逐条迁移并回调进度，单条失败不中断其余（结果逐条上报）。
///
/// UI 只调本服务，不接触文件 IO 与命令组装细节（分层：UI 禁内联业务）。
class AttachMigrationService {
  AttachMigrationService(this._handler);

  final ItemActionHandler _handler;

  /// 单条迁移结果。
  ({bool ok, String message}) lastResult = (ok: false, message: '');

  /// 迁移单条：ref → owned。返回是否成功与提示文案。
  Future<({bool ok, String message})> migrateOne(InboxItem item) async {
    if (!item.isRef) {
      return (ok: false, message: '条目非引用态，无需迁移');
    }
    final src = item.rawFilePath;
    if (src == null || src.isEmpty) {
      return (ok: false, message: '条目缺少附件引用');
    }
    // 原件已不可达：不复制、不假成功，如实告知（失效态由渲染层 reachable() 实时呈现）
    if (!await Attach.reachable(item)) {
      return (ok: false, message: '原件已不可访问（可能已删除或授权过期）');
    }
    try {
      final saved = await copyToAppDir(src);
      if (saved == null) {
        return (ok: false, message: '复制失败：源文件不可读');
      }
      await _handler.execute(MigrateAttachCommand(id: item.id!, ownedPath: saved));
      return (ok: true, message: '已迁移为本地持有');
    } on ActionException catch (e) {
      return (ok: false, message: e.message);
    } catch (e) {
      debugPrint('[DEGRADE] attach_migrate_failed id=${item.id} error=$e');
      return (ok: false, message: '迁移失败：$e');
    }
  }

  /// 批量迁移（一键全部）：逐条执行，单条失败不中断。
  /// [onProgress] 回调 (done, total, 当前条目标题, 当前条结果)。
  Future<int> migrateAll(
    List<InboxItem> items, {
    void Function(int done, int total, String title, bool ok)? onProgress,
  }) async {
    var succeeded = 0;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final r = await migrateOne(it);
      if (r.ok) succeeded++;
      onProgress?.call(i + 1, items.length, it.humanTitle ?? it.rawFilePath ?? it.id ?? '', r.ok);
    }
    return succeeded;
  }
}
