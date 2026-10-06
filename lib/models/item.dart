import 'dart:convert';
import 'dart:math';

import '../doc/rich_text.dart';

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

  // attach_state（2026-09-30 引用模式，content-pipeline §7）：
  // app 不复制原件，不给用户存储添麻烦（复制 = 两份，视频是重灾区）。
  static const attachRef = 'ref'; // 引用原件，未复制
  static const attachOwned = 'owned'; // 已持有副本（app 私有目录）
  static const attachLost = 'lost'; // 原件不可访问（已删或授权失效）

  // author 作者身份（ai-visibility v20）：人类收集 / AI 建条 / 端侧管线回写
  static const authorHuman = 'human';
  static const authorAi = 'ai';
  static const authorPipeline = 'pipeline';

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
    this.humanMdBaseline,
    this.machineJson,
    this.translatedMd,
    this.translateLang,
    this.summaryMd,
    this.clipsJson,
    this.inspirationMd,
    this.docMetaJson,
    this.attachState = attachOwned,
    this.aspectRatio,
    this.mediaDurationMs,
    this.pinnedAt,
    List<String> tags = const [],
    Map<String, List<String>>? facets,
    this.author = authorHuman,
    this.aiVisible = false,
    this.aiEditable = false,
    this.aiProcess = false,
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
  /// AI 写回可逆锚点：AI 动笔前的人类态文本（schema v19，2026-10-04）。
  /// 非空 ⟺ 存在一个未关闭的 AI 会话（ai-writeback-revert §3.1 不变量）。
  final String? humanMdBaseline;
  final String? machineJson; // 强类型结构化 JSON
  final String? translatedMd; // 译文（翻译层产出；与 humanMd 并列，不覆盖原文）
  final String? translateLang; // 译文语言码（BCP-47），与 translatedMd 成对
  final String? summaryMd; // 端侧 LLM 摘要（与 humanMd 并列，不覆盖原文；2026-09-28 v8）
  final String? clipsJson; // 视频切片（关键区间）附属记录 JSON（schema v10，2026-09-29）

  /// 灵感区：用户私密碎片想法（schema v16，2026-10-01，detail-two-zone §3）。
  /// 与 AI 产出区分家；分享预览默认排除（隐私红线）。
  final String? inspirationMd;
  final List<String> tags;
  final Map<String, List<String>>? facets; // 多视角聚类：视角 → 标签（AI 分类页消费，V2）
  final bool isVault;
  // ── AI 可见性分层（v20，ai-visibility）──
  /// 作者身份：human=人类收集 / ai=AI 建条 / pipeline=端侧管线回写。决定 ai_visible/ai_editable 默认值。
  final String author;
  /// 对 AI 读门禁：false=AI（MCP）不可见；true=可见。仅 UI 可改（CommandActor.ui）。
  final bool aiVisible;
  /// 对 AI 写门禁 / 人类同意：false=AI 不可编辑该人类笔记；true=已授权可编辑。仅 UI 可改。
  final bool aiEditable;
  /// 旧管线回写授权位（ai-visibility v20）：开关 UI 与全部门禁已于 2026-10-05
  /// 移除（管线回写不再要独立授权）；字段与 DB 列保留仅供历史数据兼容。
  final bool aiProcess;
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

  /// 文档归一化覆盖率与确认状态 JSON（schema v12，2026-09-30）。
  /// 归一化是有损的，记 {chars, degraded_blocks, truncated, confirmed} 供 UI 明示。
  final String? docMetaJson;

  /// 文件引用状态（schema v13，2026-09-30）：ref / owned / lost。
  /// app 不复制原件——复制一份等于让用户存储翻倍（视频是重灾区）。
  final String attachState;

  /// 图片宽高比（宽/高，schema v15，2026-09-30）：摄入时解码图片头探测，
  /// 渲染处 AspectRatio 占位消灭加载抖动。null=未探测（存量条目/探测失败）。
  final double? aspectRatio;

  /// 音视频时长（毫秒，schema v17，2026-10-02）：摄入时探测一次写入，
  /// 渲染处秒显进度条总时长、省去每次播放前临时建播放器探测。null=未探测。
  final int? mediaDurationMs;

  /// 置顶时间戳（毫秒，schema v18，2026-10-02）：NULL=未置顶；
  /// 全部页独立置顶区按此倒序（card-batch-selection）。仅显示层消费，不回写用户数据。
  final int? pinnedAt;

  bool get isPinned => pinnedAt != null;

  bool get isImage => itemType == typeImage;
  bool get hasAttachment => rawFilePath != null && rawFilePath!.isNotEmpty;

  /// 列表/搜索预览：优先标题，其次 TL;DR，最后原文首行。
  ///
  /// 纯文本剥壳口径（用户拍板：纯文本场景一律无 md 标记）：
  /// - 标题来自一级标题行派生（`noteTitleOf` 保留原文）→ 经 [titleToPlain]
  ///   剥行内标记 + 行首 `#` 前缀（存量数据兜底），卡片不出 `**`/`<u>`/`#` 残壳；
  /// - 无标题/TLDR 时预览落回 rawContent（Markdown 子集）→ 经 [markdownToPlain]
  ///   整篇剥壳（`# 标题`/`**粗体**`/`![图片](…)`→ `[图片]` 等），
  ///   渲染出口（详情页 ContentBody）不受影响。
  String get preview {
    final String base;
    if (humanTitle?.isNotEmpty ?? false) {
      base = titleToPlain(humanTitle!);
    } else if (humanTldr?.isNotEmpty ?? false) {
      base = humanTldr!;
    } else {
      base = markdownToPlain(rawContent ?? '');
    }
    final oneLine = base
        // 媒体占位符不进预览文本（2026-10-06）：列表卡对行内媒体块渲染真图/封面，
        // `[图片]`/`[视频: x]` 文字残留成噪音；音频仍占位（卡无音频渲染面）。
        .replaceAll(RegExp(r'\[(?:图片|视频)(?::[^\]]*)?\]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
  }

  /// 详情正文：人类态优先，缺省回退原文。
  String get bodyText => (humanMd?.isNotEmpty ?? false) ? humanMd! : (rawContent ?? '');

  /// 是否引用原件（未复制）——app 不持有，原件失效即不可访问。
  bool get isRef => attachState == attachRef;

  /// AI 写回会话态（ai-writeback-revert §4）：idle/pending/restored，存于 doc_meta_json。
  String? get aiSessionState => docMeta?['ai_session_state'] as String?;

  /// 归一化元信息（坏 JSON 返回 null，不抛——防御与 facets 同口径）。
  Map<String, Object?>? get docMeta {
    final raw = docMetaJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 是否已有译文（详情页「译文」区与 MCP 回传的显隐依据）。
  bool get hasTranslation => translatedMd != null && translatedMd!.trim().isNotEmpty;

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
        'human_md_baseline': humanMdBaseline,
        'machine_json': machineJson,
        'translated_md': translatedMd,
        'translate_lang': translateLang,
        'summary_md': summaryMd,
        'clips_json': clipsJson,
        'inspiration_md': inspirationMd,
        if (docMetaJson != null) 'doc_meta_json': docMetaJson,
        'attach_state': attachState,
        'aspect_ratio': aspectRatio,
        'media_duration_ms': mediaDurationMs,
        'pinned_at': pinnedAt,
        'tags': jsonEncode(tags),
        'facets_json': facets == null ? null : jsonEncode(facets),
        'is_vault': isVault ? 1 : 0,
        'author': author,
        'ai_visible': aiVisible ? 1 : 0,
        'ai_editable': aiEditable ? 1 : 0,
        'ai_process': aiProcess ? 1 : 0,
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
      humanMdBaseline: map['human_md_baseline'] as String?,
      machineJson: map['machine_json'] as String?,
      translatedMd: map['translated_md'] as String?,
      translateLang: map['translate_lang'] as String?,
      summaryMd: map['summary_md'] as String?,
      clipsJson: map['clips_json'] as String?,
      inspirationMd: map['inspiration_md'] as String?,
      docMetaJson: map['doc_meta_json'] as String?,
      attachState: (map['attach_state'] as String?) ?? attachOwned,
      aspectRatio: (map['aspect_ratio'] as num?)?.toDouble(),
      mediaDurationMs: (map['media_duration_ms'] as int?),
      pinnedAt: map['pinned_at'] as int?,
      tags: tagsOf(map['tags']),
      facets: facetsOf(map['facets_json']),
      isVault: (map['is_vault'] as int? ?? 0) == 1,
      author: (map['author'] as String?) ?? authorHuman,
      aiVisible: (map['ai_visible'] as int? ?? 0) == 1,
      aiEditable: (map['ai_editable'] as int? ?? 0) == 1,
      aiProcess: (map['ai_process'] as int? ?? 0) == 1,
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
    String? humanMdBaseline,
    String? machineJson,
    String? translatedMd,
    String? translateLang,
    String? summaryMd,
    String? clipsJson,
    String? docMetaJson,
    String? attachState,
    double? aspectRatio,
    int? mediaDurationMs,
    List<String>? tags,
    Map<String, List<String>>? facets,
    String? author,
    bool? aiVisible,
    bool? aiEditable,
    bool? aiProcess,
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
        humanMdBaseline: humanMdBaseline ?? this.humanMdBaseline,
        machineJson: machineJson ?? this.machineJson,
        translatedMd: translatedMd ?? this.translatedMd,
        translateLang: translateLang ?? this.translateLang,
        summaryMd: summaryMd ?? this.summaryMd,
        clipsJson: clipsJson ?? this.clipsJson,
        docMetaJson: docMetaJson ?? this.docMetaJson,
        attachState: attachState ?? this.attachState,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        mediaDurationMs: mediaDurationMs ?? this.mediaDurationMs,
        tags: tags ?? this.tags,
        facets: facets ?? this.facets,
        author: author ?? this.author,
        aiVisible: aiVisible ?? this.aiVisible,
        aiEditable: aiEditable ?? this.aiEditable,
        aiProcess: aiProcess ?? this.aiProcess,
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

/// 段级附加记录（appendix_json）。
///
/// 两种用途同构，共用一套结构：
/// - 合并模式：同来源 App + 5 分钟窗内自动追加的各段
/// - **速记混合录入**（2026-09-29）：用户主动组装的文本段 + 语音段
class AppendixEntry {
  const AppendixEntry({required this.ts, required this.text, this.source, this.path});

  final int ts;
  final String text;

  /// 段来源：合并模式为来源 App；速记混合为 `kSegmentText` / `kSegmentVoice`。
  final String? source;

  /// 段级附件路径（语音段的音频文件）。
  ///
  /// 混合录入下一条速记可含多个语音段，而 `rawFilePath` 仅能承载一个——
  /// 故段级音频走本字段，首个语音段另作主附件。`appendix_json` 是 JSON 列，
  /// 加字段**无需 schema 迁移**。
  final String? path;

  bool get isVoice => source == kSegmentVoice;

  Map<String, Object?> toJson() => {
        'ts': ts,
        'text': text,
        if (source != null) 'source': source,
        if (path != null) 'path': path,
      };

  static AppendixEntry fromJson(Map<String, Object?> j) => AppendixEntry(
        ts: j['ts'] as int? ?? 0,
        text: j['text'] as String? ?? '',
        source: j['source'] as String?,
        path: j['path'] as String?,
      );
}

/// 速记段来源标记（与合并模式的「来源 App」取值区分）。
const String kSegmentText = 'text';
const String kSegmentVoice = 'voice';

/// 待办勾选状态（todo_state_json）：按 human_md 待办行内容 hash 关联，
/// 不回写 human_md；AI 重构后按 hash 重挂、失效项丢弃。
class TodoMark {
  const TodoMark({required this.hash, required this.done, this.ts});

  final String hash;
  final bool done;
  final int? ts;

  /// 勾选关联键（2026-10-05 定口径）：**待办行纯文本**（去 `- [ ]`/`- [x]`
  /// 标记与行内标记后的内容，trim）的 FNV-1a 32 位 hex。
  ///
  /// 设计约束（待办勾选批次拍板）：
  /// - **按内容寻址、不掺行号**——重排待办不丢勾选态（行号随编辑失效，
  ///   「行号寻址禁止」拍板早已封死该路）；
  /// - **改文即新条目**——被编辑的待办行算出新 hash 匹配不到旧记录，
  ///   按「新待办、默认未勾」处理，旧记录由写侧 GC 丢弃；
  /// - **禁用 `String.hashCode`**——Dart 对其按进程随机化，重启即变，
  ///   无法跨会话持久关联。
  static String hashOf(String text) {
    var h = 0x811c9dc5;
    for (final code in text.trim().codeUnits) {
      h ^= code;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  Map<String, Object?> toJson() => {'hash': hash, 'done': done, if (ts != null) 'ts': ts};

  static TodoMark fromJson(Map<String, Object?> j) => TodoMark(
        hash: j['hash'] as String? ?? '',
        done: j['done'] as bool? ?? false,
        ts: j['ts'] as int?,
      );
}
