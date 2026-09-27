import 'dart:convert';

import '../data/repository.dart';
import '../models/item.dart';
import 'machine_json_validator.dart';

/// UI 与 MCP 共用的唯一写/改动作层（PRD §7 关键约束）。
/// 大模型经 MCP 发的指令与用户在手机上点的操作走同一套校验与实现，杜绝双份逻辑。
///
/// 约束来源：
/// - 编辑锁：合并条目 edit_locked=1 时拒绝写入，须先 unlockEdit（设计 §4.9）；
/// - 重分类白名单：仅 source_type='image' 的条目可 image→chatlog/document（F7 决策）；
/// - machine_json：落库前须过领域 Schema 强校验（D4 决策）；
/// - 默认不可见 Vault/已删条目；vaultContext=true 供 UI 保险箱页调用（MCP 永远 false）。
class ItemActionHandler {
  ItemActionHandler(this._repo);

  final Repository _repo;

  /// 编辑（= MCP update_item patch：title/tldr/tags/human_md/machine_json/item_type）。
  Future<InboxItem> edit(
    String id, {
    String? title,
    String? tldr,
    List<String>? tags,
    String? humanMd,
    String? machineJson,
    String? itemType,
    bool vaultContext = false,
  }) async {
    final item = await _require(id, vaultContext: vaultContext);
    if (item.editLocked) {
      throw ActionException('合并条目已锁定，请先「解除编辑」');
    }
    final values = <String, Object?>{};
    if (title != null) values['human_title'] = title;
    if (tldr != null) values['human_tldr'] = tldr;
    if (tags != null) values['tags'] = jsonEncode(tags);
    if (humanMd != null) values['human_md'] = humanMd;
    if (machineJson != null) {
      final err = validateMachineJson(machineJson);
      if (err != null) throw ActionException(err);
      values['machine_json'] = machineJson;
    }
    if (itemType != null && itemType != item.itemType) {
      final err = _reclassifyError(item, itemType);
      if (err != null) throw ActionException(err);
      values['item_type'] = itemType;
    }
    if (values.isEmpty) throw ActionException('没有可更新的字段');
    await _repo.update(id, values);
    return (await _repo.byId(id, includeDeleted: false, includeVault: true))!;
  }

  /// 软删除（= MCP delete_item）：置 is_deleted 并取消关联队列任务，30 天内可恢复。
  Future<void> delete(String id, {bool vaultContext = false}) async {
    await _require(id, vaultContext: vaultContext);
    await _repo.softDelete(id);
  }

  /// 重分类（= 详情 BottomSheet「重分类」/ update_item 的 item_type）。
  Future<InboxItem> reclassify(String id, String to, {bool vaultContext = false}) async {
    final item = await _require(id, vaultContext: vaultContext);
    final err = _reclassifyError(item, to);
    if (err != null) throw ActionException(err);
    await _repo.update(id, {'item_type': to});
    return (await _repo.byId(id, includeDeleted: false, includeVault: true))!;
  }

  /// 移入 / 移出保险箱（= MCP set_vault）：仅改标记，真实加密为 V3。
  Future<void> setVault(String id, bool on, {bool vaultContext = false}) async {
    await _require(id, vaultContext: vaultContext);
    await _repo.update(id, {'is_vault': on ? 1 : 0});
  }

  /// 重新处理（= UI「重新处理」/ MCP reprocess_item）：重置处理态并入队。
  /// task_action 按类型映射（Repository.taskActionFor）；note/document 无专属动作时置 null，
  /// 由队列消费者按 item_type 通用重构。
  Future<void> reprocess(String id, {bool vaultContext = false}) async {
    final item = await _require(id, vaultContext: vaultContext);
    await _repo.update(id, {'is_processed': 0});
    await _repo.enqueueTask(id, Repository.taskActionFor(item.itemType));
  }

  /// 解除合并项编辑锁（= MCP unlock_edit）：edit_locked→0，随后 edit 方可写入。单向，不重锁。
  Future<void> unlockEdit(String id, {bool vaultContext = false}) async {
    await _require(id, vaultContext: vaultContext);
    await _repo.update(id, {'edit_locked': 0});
  }

  /// 重分类白名单校验。返回 null 表示允许，否则为拒绝原因。
  String? _reclassifyError(InboxItem item, String to) {
    if (!InboxItem.allTypes.contains(to)) return '未知类型：$to';
    if (item.sourceType != InboxItem.typeImage || item.itemType != InboxItem.typeImage) {
      return '仅图片入库（source_type=image）的条目可重分类';
    }
    if (to != InboxItem.typeChatlog && to != InboxItem.typeDocument) {
      return '仅允许 image→chatlog / document';
    }
    return null;
  }

  Future<InboxItem> _require(String id, {required bool vaultContext}) async {
    final item = await _repo.byId(id, includeVault: vaultContext);
    if (item == null) throw ActionException('条目不存在或不可见：id=$id');
    return item;
  }
}

/// 动作被拒绝（校验不过/条目不可见）。MCP 层转 McpRpcError，UI 层转 SnackBar。
class ActionException implements Exception {
  ActionException(this.message);

  final String message;

  @override
  String toString() => message;
}
