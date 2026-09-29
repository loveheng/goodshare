import 'dart:convert';

/// 备份 manifest 模型（schema v1；格式见 docs/design/s3-backup.md §3）。
///
/// manifest 是备份包里**最后上传**的文件 = 提交标记：
/// manifest 未更新时，远端整包仍视为上一次完整备份（部分失败不毁旧备份）。
class BackupManifest {
  const BackupManifest({
    required this.ts,
    required this.schemaVersion,
    this.device,
    required this.itemCount,
    required this.vaultExcluded,
    required this.dbSize,
    required this.attachments,
  });

  static const schema = 1;

  final int ts; // 备份时刻（毫秒）
  final int schemaVersion; // 备份时的 DB schema 版本
  final String? device;
  final int itemCount; // 快照内条目数（不含 Vault）
  final int vaultExcluded; // 被排除的 Vault 条目计数（不含内容，清单不泄露 Vault 文件名）
  final int dbSize; // 快照文件大小（恢复时校验）
  final List<BackupAttachment> attachments;

  Map<String, Object?> toJson() => {
        'schema': BackupManifest.schema,
        'ts': ts,
        'schema_version': schemaVersion,
        'device': device,
        'item_count': itemCount,
        'vault_excluded': vaultExcluded,
        'db_size': dbSize,
        'attachments': [for (final a in attachments) a.toJson()],
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 防御解析：schema 不支持/关键字段坏 → 抛 FormatException；
  /// attachments 坏条目**跳过**（项目约定：坏条目跳过不整体失败）。
  factory BackupManifest.fromJson(Map<String, Object?> j) {
    if (j['schema'] is! int || (j['schema'] as int) != schema) {
      throw const FormatException('不支持的备份 manifest（schema 版本不符或缺失）');
    }
    final ts = j['ts'];
    if (ts is! int || ts <= 0) throw const FormatException('备份 manifest 时间戳非法');
    final raw = j['attachments'];
    final list = <BackupAttachment>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        try {
          list.add(BackupAttachment.fromJson(e.cast<String, Object?>()));
        } on FormatException {
          continue;
        }
      }
    }
    return BackupManifest(
      ts: ts,
      schemaVersion: (j['schema_version'] as int?) ?? 1,
      device: j['device'] is String ? (j['device'] as String) : null,
      itemCount: (j['item_count'] as int?) ?? 0,
      vaultExcluded: (j['vault_excluded'] as int?) ?? 0,
      dbSize: (j['db_size'] as int?) ?? 0,
      attachments: list,
    );
  }

  static BackupManifest decode(String text) {
    final obj = jsonDecode(text);
    if (obj is! Map) throw const FormatException('备份 manifest 不是 JSON 对象');
    return BackupManifest.fromJson(obj.cast<String, Object?>());
  }
}

/// 备份包内单个附件的登记项。
class BackupAttachment {
  const BackupAttachment({required this.rel, required this.size, this.itemId});

  final String rel; // 相对 app documents 目录（如 shares/1729.jpg）
  final int size; // 备份时大小（增量跳过判定与恢复校验用）
  final String? itemId; // 来源条目（展示用；条目可能在恢复后已不存在，可空）

  Map<String, Object?> toJson() =>
      {'rel': rel, 'size': size, if (itemId != null) 'item_id': itemId};

  factory BackupAttachment.fromJson(Map<String, Object?> j) {
    final rel = j['rel'];
    final size = j['size'];
    if (rel is! String || rel.isEmpty || size is! int || size < 0) {
      throw const FormatException('附件条目非法（rel/size）');
    }
    return BackupAttachment(
      rel: rel,
      size: size,
      itemId: j['item_id'] is String ? (j['item_id'] as String) : null,
    );
  }
}

/// 路径穿越纵深防御（设计 §6）：rel 来自自家 DB 正常不该发生，
/// 但恢复端不可信任远端 manifest——拒绝空段 / `.` / `..` / 绝对路径 / 控制字符
/// （NUL 等控制字符在部分文件系统是路径注入的经典手段，一律不落盘）。
/// 派生产物文件名 → 来源条目 id（`{itemId}.{ext}` / `{itemId}.{lang}.{ext}` → 首段）。
/// 用于 Vault 排除：字幕/译文/标注等按条目命名的派生文件，首段即条目 id。
String? derivedArtifactItemId(String basename) {
  if (basename.isEmpty) return null;
  final head = basename.split('.').first;
  return head.isEmpty ? null : head;
}

bool isSafeBackupRel(String rel) {
  if (rel.isEmpty || rel.startsWith('/')) return false;
  for (final seg in rel.split('/')) {
    if (seg.isEmpty || seg == '.' || seg == '..') return false;
    for (final ch in seg.runes) {
      if (ch < 0x20 || ch == 0x7f) return false;
    }
  }
  return true;
}
