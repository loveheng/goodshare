import 'dart:convert';

import '../ai/reconstructor.dart';
import '../models/item.dart';

/// 命令协议（Command Pattern）：UI 与 AI 的唯一共同语言（Human-AI Parity 基石）。
///
/// 设计意图——把 App 变成「无头（Headless）系统」，UI 与 AI 只是两个平等客户端：
///
/// - **人类操作**：UI 把输入框文字 / 选中标签组装成 [ItemCommand] 交给动作层；
/// - **AI 操作**：MCP 把大模型输出的 JSON 经 [ItemCommand.fromJson] 反序列化成
///   **同一个**命令对象交给**同一个**动作层。
///
/// 核心逻辑不知道、也不关心这次请求是人按出来的还是 AI 算出来的。
/// 检验标准：删掉整个 Flutter UI，只写一个「解析微信消息 → 组装命令 → 调用动作层」
/// 的外壳，系统应能完整运行且不产生脏数据。

// ───────────────────────────── 主体（Actor） ─────────────────────────────

/// 命令发起主体。防呆下沉的核心维度：同一条命令，不同主体的可执行性不同。
///
/// **刻意不由命令载荷携带**——否则大模型可以在 JSON 里把自己声明成 `ui` 来越权。
/// 主体由传输层注入，不可被载荷伪造：
///
/// | 传输层 | 主体 |
/// |---|---|
/// | Flutter UI | [ui] |
/// | MCP / 大模型 / 未来聊天机器人外壳 | [ai] |
/// | 端侧 AI 管线（QueueConsumer） | [pipeline] |
enum CommandActor {
  /// 手机 UI。唯一可「移出保险箱」「彻底删除」的主体（生物识别 / 二次确认在其上）。
  ui,

  /// MCP / 大模型。Vault 只进不出，无彻底删除权。
  ai,

  /// 端侧 AI 管线。本机运行、不属于对外暴露面；独享 AI 重分类特权（V2 §3.8）。
  pipeline,
}

// ───────────────────────────── 领域拒绝码 ─────────────────────────────

/// 机器可读的拒绝码。MCP 层原样放进 JSON-RPC error.data，
/// 让大模型不只是「看到报错」，而是能读懂原因并自我纠正。
abstract final class ActionErrorCode {
  static const invalidRequest = 'invalid_request';
  static const notFound = 'not_found';
  static const forbidden = 'forbidden';
  static const editLocked = 'edit_locked';
  static const schemaInvalid = 'schema_invalid';
  static const reclassifyDenied = 'reclassify_denied';
  static const versionConflict = 'version_conflict';
}

/// 动作被拒绝（领域校验不过 / 条目不可见 / 主体越权）。
///
/// 同一份异常，两个客户端各取所需：
/// - UI：catch 后弹 SnackBar（用 [message]）；
/// - AI：MCP 转成 JSON 错误对象（用 [code] + [hint]），大模型读懂后自我纠正
///   —— 例如收到 `edit_locked` 会先调用 `unlock_edit` 再重试。
class ActionException implements Exception {
  ActionException(this.message, {this.code = ActionErrorCode.invalidRequest, this.hint});

  final String message;
  final String code;

  /// 给 AI 的下一步建议（人类可读）。UI 不消费。
  final String? hint;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        if (hint != null) 'hint': hint,
      };

  @override
  String toString() => message;
}

// ───────────────────────────── 执行结果 ─────────────────────────────

/// 命令执行结果。**写路径一律回最新条目快照**——状态可见性对称。
///
/// 人类靠 Riverpod/ChangeNotifier 订阅看到列表刷新；AI 没有眼睛，
/// 只能靠返回值对齐「短期记忆（Context）」与数据库真实状态，
/// 否则下一步就会基于旧数据胡言乱语。
class CommandResult {
  const CommandResult({required this.op, this.targetId, this.item, this.note});

  final String op;

  /// 目标 id；创建类命令为新建条目的 id。
  final String? targetId;

  /// 落库后的最新快照。物理删除 / 移出可见域时为 null。
  final InboxItem? item;

  /// 人类可读的结果说明（UI 提示 / AI 阅读共用）。
  final String? note;

  Map<String, Object?> toJson() => {
        'ok': true,
        'op': op,
        if (targetId != null) 'id': targetId,
        if (note != null) 'note': note,
        if (item != null) 'item': itemToJson(item!),
      };
}

/// 条目快照 JSON：**MCP 与命令结果的唯一序列化口径**。
/// 保证 AI 拿到的 item 形状与 `get_item` 完全一致，避免上下文里出现两种 item 形状。
Map<String, Object?> itemToJson(InboxItem it) => {
      'id': it.id,
      'type': it.itemType,
      'title': it.humanTitle,
      'tldr': it.humanTldr,
      'text': it.bodyText,
      'tags': it.tags,
      'edit_locked': it.editLocked,
      'is_processed': it.isProcessed,
      'is_vault': it.isVault,
      'is_deleted': it.isDeleted,
      'version': it.version,
      'machine_json': _tryDecode(it.machineJson),
      // 译文与原文并列回传：AI 读到什么，人在详情页看到的就是什么（状态可见性对称）
      if (it.hasTranslation)
        'translation': {'lang': it.translateLang, 'text': it.translatedMd},
      'source': {'app': it.sourceApp, 'type': it.sourceType},
      'created_at': DateTime.fromMillisecondsSinceEpoch(it.createdAt).toIso8601String(),
      'file': it.rawFilePath,
    };

// ───────────────────────────── 命令本体 ─────────────────────────────

/// 命令基类（sealed：新增命令必须在本文件登记并同步到动作层 switch）。
sealed class ItemCommand {
  const ItemCommand({this.expectedVersion});

  /// **乐观锁断言**：发起方「看到的」条目版本号（[InboxItem.version]）。
  /// 非空时动作层做 CAS——版本不一致即拒绝，防止人类慢速编辑与 AI 瞬时写入
  /// 互相**静默覆盖**（这是最难发现的一类脏数据：无报错、无痕迹）。
  /// 空 = 不校验，保持既有调用零改动，按场景渐进接入。
  final int? expectedVersion;

  /// 命令字：JSON 载荷的判别字段，与 MCP 工具名解耦（工具只是命令的包装）。
  String get op;

  /// 目标条目 id；创建类命令为 null。
  String? get targetId;

  Map<String, Object?> toJson();

  /// JSON → 命令。AI 侧唯一入口：大模型输出什么就反序列成什么，
  /// 不做任何「只有 UI 才懂」的隐转换。
  static ItemCommand fromJson(Map<String, Object?> json) {
    final op = json['op'];
    if (op is! String || op.isEmpty) {
      throw ActionException(
        '命令缺少 op 字段',
        code: ActionErrorCode.invalidRequest,
        hint: '可选 op：${supportedOps.join(', ')}',
      );
    }
    final id = _reqId(json, op);
    final ev = _int(json['expected_version']);
    switch (op) {
      case 'update':
        return UpdateItemCommand(
          id: id,
          title: _str(json['title']),
          tldr: _str(json['tldr']),
          tags: _strList(json['tags']),
          humanMd: _str(json['human_md']),
          machineJson: _jsonField(json['machine_json']),
          itemType: _str(json['item_type']),
          expectedVersion: ev,
        );
      case 'delete':
        return DeleteItemCommand(id, expectedVersion: ev);
      case 'set_vault':
        final on = _bool(json['on']);
        if (on == null) {
          throw ActionException('set_vault 需要布尔字段 on', code: ActionErrorCode.invalidRequest);
        }
        return SetVaultCommand(id, on, expectedVersion: ev);
      case 'reclassify':
        final to = _str(json['item_type']) ?? _str(json['to']);
        if (to == null) {
          throw ActionException('reclassify 需要 item_type 字段', code: ActionErrorCode.invalidRequest);
        }
        return ReclassifyCommand(id, to, expectedVersion: ev);
      case 'reprocess':
        return ReprocessCommand(id, expectedVersion: ev);
      case 'transcribe':
        return TranscribeCommand(id, expectedVersion: ev);
      case 'ocr':
        return OcrCommand(id, expectedVersion: ev);
      case 'translate':
        return TranslateCommand(
          id,
          targetLang: _str(json['target_lang']) ?? _str(json['lang']),
          expectedVersion: ev,
        );
      case 'unlock_edit':
        return UnlockEditCommand(id, expectedVersion: ev);
      case 'restore':
        return RestoreCommand(id, expectedVersion: ev);
      case 'delete_forever':
        return DeleteForeverCommand(id, expectedVersion: ev);
      case 'collect':
        return CollectCommand(
          itemType: _str(json['item_type']) ?? InboxItem.typeNote,
          sourceApp: _str(json['source_app']) ?? 'unknown',
          rawContent: _str(json['content']) ?? _str(json['raw_content']),
          rawFilePath: _str(json['file']) ?? _str(json['raw_file_path']),
          humanTitle: _str(json['title']),
          tags: _strList(json['tags']),
          collectMode: _str(json['collect_mode']) ?? InboxItem.modeScatter,
        );
      case 'append_segment':
        final text = _str(json['text']) ?? _str(json['content']);
        if (text == null || text.trim().isEmpty) {
          throw ActionException(
            'append_segment 需要非空 text 字段',
            code: ActionErrorCode.invalidRequest,
          );
        }
        return AppendSegmentCommand(
          id,
          text,
          sourceApp: _str(json['source_app']),
          expectedVersion: ev,
        );
      case 'apply_ai_result':
        return ApplyAiResultCommand(
          id,
          ReconstructResult(
            humanMd: _str(json['human_md']) ?? '',
            machineJson: json['machine_json'] is Map
                ? (json['machine_json'] as Map).cast<String, Object?>()
                : null,
            tags: _strList(json['tags']) ?? const [],
            itemType: _str(json['item_type']),
            facets: _facets(json['facets']),
            translatedMd: _str(json['translated_md']),
            translateLang: _str(json['translate_lang']),
          ),
        );
      default:
        throw ActionException(
          '未知命令：$op',
          code: ActionErrorCode.invalidRequest,
          hint: '可选 op：${supportedOps.join(', ')}',
        );
    }
  }

  /// 所有合法命令字（错误提示与文档同步用）。
  static const supportedOps = [
    'update',
    'delete',
    'set_vault',
    'reclassify',
    'reprocess',
    'transcribe',
    'ocr',
    'translate',
    'unlock_edit',
    'restore',
    'delete_forever',
    'collect',
    'append_segment',
    'apply_ai_result',
  ];
}

/// 编辑（= MCP update_item 的 patch）：title / tldr / tags / human_md / machine_json / item_type。
final class UpdateItemCommand extends ItemCommand {
  const UpdateItemCommand({
    required this.id,
    this.title,
    this.tldr,
    this.tags,
    this.humanMd,
    this.machineJson,
    this.itemType,
    super.expectedVersion,
  });

  final String id;
  final String? title;
  final String? tldr;
  final List<String>? tags;
  final String? humanMd;

  /// machine_json 原文（字符串或对象皆可，落库前过领域 Schema 强校验）。
  final String? machineJson;

  /// 重分类目标类型；null = 不改。
  final String? itemType;

  bool get isEmpty =>
      title == null &&
      tldr == null &&
      tags == null &&
      humanMd == null &&
      machineJson == null &&
      itemType == null;

  @override
  String get op => 'update';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (title != null) 'title': title,
        if (tldr != null) 'tldr': tldr,
        if (tags != null) 'tags': tags,
        if (humanMd != null) 'human_md': humanMd,
        if (machineJson != null) 'machine_json': machineJson,
        if (itemType != null) 'item_type': itemType,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 软删除（= MCP delete_item）：置 is_deleted 并取消关联队列任务，30 天内可恢复。
final class DeleteItemCommand extends ItemCommand {
  const DeleteItemCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'delete';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 移入 / 移出保险箱（= MCP set_vault）。
/// 移出（`on=false`）须 [CommandActor.ui]——AI 不得自行解除 Vault 隔离。
final class SetVaultCommand extends ItemCommand {
  const SetVaultCommand(this.id, this.on, {super.expectedVersion});

  final String id;
  final bool on;

  @override
  String get op => 'set_vault';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        'on': on,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 重分类（= 详情「重分类」BottomSheet / update_item 的 item_type）。
final class ReclassifyCommand extends ItemCommand {
  const ReclassifyCommand(this.id, this.to, {super.expectedVersion});

  final String id;
  final String to;

  @override
  String get op => 'reclassify';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        'item_type': to,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 重新处理（= UI「重新处理」/ MCP reprocess_item）：重置处理态并入队。
final class ReprocessCommand extends ItemCommand {
  const ReprocessCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'reprocess';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 手动 OCR 图片（= UI「识别文字」）：入队 task_action=ocr_and_extract。
///
/// 与 [TranscribeCommand] 对称（2026-09-28 用户拍板：分享摄入不默认 OCR，只存文件，
/// 识别文字必须用户手动触发）。是**唯一**会真正跑 ML Kit 识别的入口。
final class OcrCommand extends ItemCommand {
  const OcrCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'ocr';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 翻译条目正文（= UI「翻译」/ MCP translate_item）：入队 task_action=translate。
///
/// 与 [ReprocessCommand] 的区别：reprocess 走按类型的通用重构，本命令显式指定
/// 「翻译」这一动作，是**唯一**会真正跑翻译引擎的入口（与 OCR / 转写同构：
/// 端侧重资源动作一律手动 / 显式触发，摄入不自动跑）。
///
/// [targetLang] 为 BCP-47 目标语言（如 'zh'）；null = 沿用设置项所选目标语言。
/// 语言合法性由动作层校验（防呆下沉），AI 换个入口也绕不过。
final class TranslateCommand extends ItemCommand {
  const TranslateCommand(this.id, {this.targetLang, super.expectedVersion});

  final String id;
  final String? targetLang;

  @override
  String get op => 'translate';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (targetLang != null) 'target_lang': targetLang,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 手动转写音频 / 视频（= UI「转写」）：入队 task_action=transcribe_audio。
///
/// 与 [ReprocessCommand] 的区别：reprocess 按 item_type 走通用重构（音频只占位，
/// 不跑模型），本命令显式指定转写动作，是**唯一**会真正跑 Sherpa 转写入口
/// （2026-09-28 用户拍板：音频不做实时 / 摄入即转写，只存文件，转写手动触发）。
final class TranscribeCommand extends ItemCommand {
  const TranscribeCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'transcribe';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 解除合并项编辑锁（= MCP unlock_edit）：edit_locked→0，随后 update 方可写入。单向，不重锁。
final class UnlockEditCommand extends ItemCommand {
  const UnlockEditCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'unlock_edit';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 恢复一条软删除条目（最近删除页 / AI 误删纠正）。
final class RestoreCommand extends ItemCommand {
  const RestoreCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'restore';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 物理彻底删除（含附件，不可恢复）。仅 [CommandActor.ui]。
final class DeleteForeverCommand extends ItemCommand {
  const DeleteForeverCommand(this.id, {super.expectedVersion});

  final String id;

  @override
  String get op => 'delete_forever';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// 收集入库一条并立即入队（分享摄入 / 手动添加 / MCP add_item 同源）。
/// 文本 / 链接传 [rawContent]；媒体 / 附件传 [rawFilePath]（须为 app 私有目录路径）。
///
/// [collectMode] 为 `merge` 时建「合并链」：条目默认锁定（须先「解除编辑」），
/// 首段同步记入 appendix，后续段经 [AppendSegmentCommand] 追加。
final class CollectCommand extends ItemCommand {
  const CollectCommand({
    required this.itemType,
    this.sourceApp = 'unknown',
    this.rawContent,
    this.rawFilePath,
    this.humanTitle,
    this.tags,
    this.collectMode = InboxItem.modeScatter,
  });

  final String itemType;
  final String sourceApp;
  final String? rawContent;
  final String? rawFilePath;
  final String? humanTitle;
  final List<String>? tags;
  final String collectMode;

  bool get isMerge => collectMode == InboxItem.modeMerge;

  @override
  String get op => 'collect';

  @override
  String? get targetId => null;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'item_type': itemType,
        'source_app': sourceApp,
        if (rawContent != null) 'content': rawContent,
        if (rawFilePath != null) 'file': rawFilePath,
        if (humanTitle != null) 'title': humanTitle,
        if (tags != null) 'tags': tags,
        'collect_mode': collectMode,
      };
}

/// 往合并链末尾追加一段（= 手机端连续速记自动并链 / MCP append_segment）。
///
/// 领域语义：**合并条目 `edit_locked=1` 仍允许追加**——追加是链的持续生长，
/// 不等同于改写已有内容；该豁免是显式领域规则，不是绕过校验。
/// 模式（必须 merge）与窗口（末段超时）约束全部在动作层判定，
/// 客户端（含 AI）的"策略"只负责选链，不负责下约束。
final class AppendSegmentCommand extends ItemCommand {
  const AppendSegmentCommand(
    this.id,
    this.text, {
    this.sourceApp,
    super.expectedVersion,
  });

  final String id;
  final String text;
  final String? sourceApp;

  @override
  String get op => 'append_segment';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        'text': text,
        if (sourceApp != null) 'source_app': sourceApp,
        if (expectedVersion != null) 'expected_version': expectedVersion,
      };
}

/// AI 管线回写重构产出。**仅 [CommandActor.pipeline]**：
/// 特权入口，若对 AI 开放即可绕过 edit_locked 直接改写条目。
final class ApplyAiResultCommand extends ItemCommand {
  const ApplyAiResultCommand(this.id, this.result);

  final String id;
  final ReconstructResult result;

  @override
  String get op => 'apply_ai_result';

  @override
  String? get targetId => id;

  @override
  Map<String, Object?> toJson() => {
        'op': op,
        'id': id,
        'human_md': result.humanMd,
        if (result.machineJson != null) 'machine_json': result.machineJson,
        if (result.tags.isNotEmpty) 'tags': result.tags,
        if (result.itemType != null) 'item_type': result.itemType,
        if (result.facets != null) 'facets': result.facets,
        if (result.translatedMd != null) 'translated_md': result.translatedMd,
        if (result.translateLang != null) 'translate_lang': result.translateLang,
      };
}

// ───────────────────────────── 解析小工具 ─────────────────────────────
// AI 输出的 JSON 形状不总规矩（bool 可能写成 "true"、数字写成字符串），
// 这里统一做「宽容读取 + 明确报错」，不做静默兜底。

String _reqId(Map<String, Object?> json, String op) {
  final id = _str(json['id']);
  if (id == null || id.trim().isEmpty) {
    throw ActionException('命令 $op 缺少 id 字段', code: ActionErrorCode.invalidRequest);
  }
  return id;
}

String? _str(Object? v) => v is String ? v : null;

bool? _bool(Object? v) => switch (v) {
      bool b => b,
      String s when s == 'true' => true,
      String s when s == 'false' => false,
      _ => null,
    };

List<String>? _strList(Object? v) =>
    v is List ? v.whereType<String>().toList() : null;

int? _int(Object? v) => switch (v) {
      int i => i,
      String s => int.tryParse(s),
      _ => null,
    };

/// machine_json 字段：对象 → 编码为原文字符串；已是字符串 → 原样。
String? _jsonField(Object? v) => switch (v) {
      null => null,
      String s => s,
      Map m => jsonEncode(m),
      _ => throw ActionException(
          'machine_json 必须是对象或 JSON 字符串',
          code: ActionErrorCode.schemaInvalid,
        ),
    };

Map<String, List<String>>? _facets(Object? v) {
  if (v is! Map) return null;
  return {
    for (final e in v.entries)
      if (e.value is List) e.key.toString(): (e.value as List).whereType<String>().toList(),
  };
}

Object? _tryDecode(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null; // 历史脏数据不阻断读取，机器态按缺失处理
  }
}
