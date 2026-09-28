import 'dart:convert';
import 'dart:math';

/// 收集条目：分享进来的「好东西」统一数据模型。
/// 三层结构（PRD §5.3）：raw_content 原始层 → human_md 人类态 / machine_json 机器态。
class InboxItem {
  // item_type canonical 枚举（PRD §5.3；AI 可重分类，'health' 随健康接入 V3 引入）
  static const typeNote = 'note';
  static const typeUrl = 'url';
  static const typeImage = 'image';
  static const typeVideo = 'video';
  static const typeAudio = 'audio';
  static const typeChatlog = 'chatlog';
  static const typeDocument = 'document';

  static const allTypes = [typeNote, typeUrl, typeImage, typeVideo, typeAudio, typeChatlog, typeDocument];

  // collect_mode（设计 §4.9：文本收集合并 / 分散）
  static const modeScatter = 'scatter';
  static const modeMerge = 'merge';

  InboxItem({
    this.id,
    required this.itemType,
    this.sourceType,
    this.sourceApp,
    this.rawContent,
    this.rawFilePath,
    this.humanTitle,
    this.humanTldr,
    this.humanMd,
    this.machineJson,
    List<String> tags = const [],
    Map<String, List<String>>? facets,
    this.isVault = false,
    this.isProcessed = 0,
    this.collectMode = modeScatter,
    List<AppendixEntry> appendix = const [],
    this.editLocked = false,
    this.isDeleted = false,
    this.deletedAt,
    List<TodoMark> todoState = const [],
    required this.createdAt,
    this.version = 0,
  })  : tags = List.unmodifiable(tags),
        facets = facets == null ? null : Map.unmodifiable(facets),
        appendix = List.unmodifiable(appendix),
        todoState = List.unmodifiable(todoState);

  final String? id; // uuid，对外稳定标识（MCP / 侧边栏 / MCP 重分类均用）
  final String itemType; // 逻辑类型，可由 AI 重分类
  final String? sourceType; // 入库原始类型（如截图），入库后不变，供溯源与重分类
  final String? sourceApp;
  final String? rawContent; // 原始脏数据层
  final String? rawFilePath; // 原始图片/文件本地路径（单文件）
  final String? humanTitle; // AI 重构标题
  final String? humanTldr; // AI 3 句摘要
  final String? humanMd; // AI 重构 Markdown（含 [ ] 待办）
  final String? machineJson; // 强类型结构化 JSON
  final List<String> tags;
  final Map<String, List<String>>? facets; // 多视角聚类：视角 → 标签（AI 分类页消费，V2）
  final bool isVault;
  final int isProcessed; // 0 待处理 / 1 完成 / -1 失败
  final String collectMode;
  final List<AppendixEntry> appendix; // 合并模式的各段附加记录
  final bool editLocked; // 合并模式默认锁定，须「解除编辑」后方可改
  final bool isDeleted; // 软删除：查询默认过滤
  final int? deletedAt; // 软删除时间戳；30 天保留期以此计算
  final List<TodoMark> todoState; // 待办勾选状态（V2 可勾）
  final int createdAt;

  /// 乐观锁版本号：任何写操作 +1。发起方可携带自己"看到的"版本做 CAS，
  /// 防止人类慢速编辑与 AI 瞬时写入互相静默覆盖（2026-09-28 v5）。
  final int version;

  bool get isImage => itemType == typeImage;
  bool get hasAttachment => rawFilePath != null && rawFilePath!.isNotEmpty;

  /// 列表/搜索预览：优先标题，其次 TL;DR，最后原文首行。
  String get preview {
    final base = humanTitle?.isNotEmpty ?? false
        ? humanTitle!
        : (humanTldr?.isNotEmpty ?? false)
            ? humanTldr!
            : (rawContent ?? '');
    final oneLine = base.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
  }

  /// 详情正文：人类态优先，缺省回退原文。
  String get bodyText => (humanMd?.isNotEmpty ?? false) ? humanMd! : (rawContent ?? '');

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'item_type': itemType,
        'source_type': sourceType,
        'source_app': sourceApp,
        'raw_content': rawContent,
        'raw_file_path': rawFilePath,
        'human_title': humanTitle,
        'human_tldr': humanTldr,
        'human_md': humanMd,
        'machine_json': machineJson,
        'tags': jsonEncode(tags),
        'facets_json': facets == null ? null : jsonEncode(facets),
        'is_vault': isVault ? 1 : 0,
        'is_processed': isProcessed,
        'collect_mode': collectMode,
        'appendix_json':
            appendix.isEmpty ? null : jsonEncode([for (final a in appendix) a.toJson()]),
        'edit_locked': editLocked ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        if (deletedAt != null) 'deleted_at': deletedAt,
        'todo_state_json':
            todoState.isEmpty ? null : jsonEncode([for (final t in todoState) t.toJson()]),
        'created_at': createdAt,
        'version': version,
      };

  static InboxItem fromMap(Map<String, Object?> map) {
    List<String> tagsOf(Object? v) {
      if (v is! String || v.isEmpty) return const [];
      try {
        return [if (jsonDecode(v) is List) ...((jsonDecode(v) as List).whereType<String>())];
      } catch (_) {
        return const [];
      }
    }

    List<T> listOf<T>(Object? v, T Function(Map<String, Object?>) from) {
      if (v is! String || v.isEmpty) return const [];
      try {
        final raw = jsonDecode(v);
        return raw is List ? [for (final e in raw.whereType<Map>()) from(e.cast<String, Object?>())] : const [];
      } catch (_) {
        return const [];
      }
    }

    Map<String, List<String>>? facetsOf(Object? v) {
      if (v is! String || v.isEmpty) return null;
      try {
        final raw = jsonDecode(v);
        return raw is Map
            ? {
                for (final e in raw.entries)
                  if (e.value is List)
                    e.key as String: (e.value as List).whereType<String>().toList(),
              }
            : null;
      } catch (_) {
        return null;
      }
    }

    return InboxItem(
      id: map['id'] as String?,
      itemType: (map['item_type'] as String?) ?? typeNote,
      sourceType: map['source_type'] as String?,
      sourceApp: map['source_app'] as String?,
      rawContent: map['raw_content'] as String?,
      rawFilePath: map['raw_file_path'] as String?,
      humanTitle: map['human_title'] as String?,
      humanTldr: map['human_tldr'] as String?,
      humanMd: map['human_md'] as String?,
      machineJson: map['machine_json'] as String?,
      tags: tagsOf(map['tags']),
      facets: facetsOf(map['facets_json']),
      isVault: (map['is_vault'] as int? ?? 0) == 1,
      isProcessed: map['is_processed'] as int? ?? 0,
      collectMode: (map['collect_mode'] as String?) ?? modeScatter,
      appendix: listOf(map['appendix_json'], AppendixEntry.fromJson),
      editLocked: (map['edit_locked'] as int? ?? 0) == 1,
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
      deletedAt: map['deleted_at'] as int?,
      todoState: listOf(map['todo_state_json'], TodoMark.fromJson),
      createdAt: (map['created_at'] as int?) ?? 0,
      version: (map['version'] as int?) ?? 0,
    );
  }

  InboxItem copyWith({
    String? id,
    String? itemType,
    String? sourceType,
    String? sourceApp,
    String? rawContent,
    String? rawFilePath,
    String? humanTitle,
    String? humanTldr,
    String? humanMd,
    String? machineJson,
    List<String>? tags,
    Map<String, List<String>>? facets,
    bool? isVault,
    int? isProcessed,
    String? collectMode,
    List<AppendixEntry>? appendix,
    bool? editLocked,
    bool? isDeleted,
    int? deletedAt,
    List<TodoMark>? todoState,
    int? createdAt,
    int? version,
  }) =>
      InboxItem(
        id: id ?? this.id,
        itemType: itemType ?? this.itemType,
        sourceType: sourceType ?? this.sourceType,
        sourceApp: sourceApp ?? this.sourceApp,
        rawContent: rawContent ?? this.rawContent,
        rawFilePath: rawFilePath ?? this.rawFilePath,
        humanTitle: humanTitle ?? this.humanTitle,
        humanTldr: humanTldr ?? this.humanTldr,
        humanMd: humanMd ?? this.humanMd,
        machineJson: machineJson ?? this.machineJson,
        tags: tags ?? this.tags,
        facets: facets ?? this.facets,
        isVault: isVault ?? this.isVault,
        isProcessed: isProcessed ?? this.isProcessed,
        collectMode: collectMode ?? this.collectMode,
        appendix: appendix ?? this.appendix,
        editLocked: editLocked ?? this.editLocked,
        isDeleted: isDeleted ?? this.isDeleted,
        deletedAt: deletedAt ?? this.deletedAt,
        todoState: todoState ?? this.todoState,
        createdAt: createdAt ?? this.createdAt,
        version: version ?? this.version,
      );

  /// RFC 4122 v4 形状的 uuid。不引第三方依赖（项目规约：新依赖须显式确认）。
  static String newId() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// 合并模式的段级附加记录（appendix_json）。
class AppendixEntry {
  const AppendixEntry({required this.ts, required this.text, this.source});

  final int ts;
  final String text;
  final String? source;

  Map<String, Object?> toJson() => {'ts': ts, 'text': text, if (source != null) 'source': source};

  static AppendixEntry fromJson(Map<String, Object?> j) => AppendixEntry(
        ts: j['ts'] as int? ?? 0,
        text: j['text'] as String? ?? '',
        source: j['source'] as String?,
      );
}

/// 待办勾选状态（todo_state_json）：按 human_md 待办行内容 hash 关联，
/// 不回写 human_md；AI 重构后按 hash 重挂、失效项丢弃。
class TodoMark {
  const TodoMark({required this.hash, required this.done, this.ts});

  final String hash;
  final bool done;
  final int? ts;

  Map<String, Object?> toJson() => {'hash': hash, 'done': done, if (ts != null) 'ts': ts};

  static TodoMark fromJson(Map<String, Object?> j) => TodoMark(
        hash: j['hash'] as String? ?? '',
        done: j['done'] as bool? ?? false,
        ts: j['ts'] as int?,
      );
}
