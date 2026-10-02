import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repository.dart';
import '../doc/rich_text.dart';
import '../models/item.dart';
import 'backup_manifest.dart';
import 's3_client.dart';

/// S3 备份/恢复编排层（2026-09-29，设计 docs/design/s3-backup.md）。
///
/// 独立 ChangeNotifier 状态机（UI 直接观察）：idle → working(progress) → done/failed/cancelled。
/// **不进 ai_task_queue**（队列是条目维度，item_id 外键 NOT NULL；备份是全局维护操作）。
///
/// 备份顺序（设计 §4）：附件增量上传 → DB 快照 → manifest 最后（提交标记）；
/// 恢复顺序（设计 §5）：manifest 校验 → DB 导入（先）→ 附件下载（后，缺失不阻断）。
/// 原子提交语义：S3 单对象 PUT 本身原子（不存在半截正式对象），manifest 最后写
/// 即提交标记；db/附件先传、取消/失败时旧 manifest 仍在 → 远端保持上一次完整备份。
class BackupService extends ChangeNotifier {
  BackupService(this._repo);

  final Repository _repo;

  static const _kEndpoint = 's3_endpoint';
  static const _kBucket = 's3_bucket';
  static const _kRegion = 's3_region';
  static const _kAccessKey = 's3_access_key';
  static const _kSecretKey = 's3_secret_key';
  static const _kLast = 's3_last_backup';

  String? _endpoint;
  String? _bucket;
  String? _region;
  String? _accessKey;
  String? _secretKey;
  LastBackup? _last;

  BackupState _state = BackupState.idle;
  BackupProgress _progress = const BackupProgress();
  CancelToken? _token;
  int _transferred = 0; // 本轮累计传输字节（展示用）
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get busy => _state == BackupState.working;
  bool get hasConfig => (_endpoint ?? '').isNotEmpty && (_bucket ?? '').isNotEmpty;
  String? get endpoint => _endpoint;
  String? get bucket => _bucket;
  String? get region => _region;
  bool get hasAccessKey => (_accessKey ?? '').isNotEmpty;
  bool get hasSecretKey => (_secretKey ?? '').isNotEmpty;
  LastBackup? get lastBackup => _last;
  BackupState get state => _state;
  BackupProgress get progress => _progress;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _endpoint = prefs.getString(_kEndpoint);
    _bucket = prefs.getString(_kBucket);
    _region = prefs.getString(_kRegion);
    _accessKey = prefs.getString(_kAccessKey);
    _secretKey = prefs.getString(_kSecretKey);
    final raw = prefs.getString(_kLast);
    if (raw != null) {
      try {
        _last = LastBackup.fromJson(raw);
      } catch (_) {
        _last = null;
      }
    }
    notifyListeners();
  }

  Future<void> saveConfig({
    required String endpoint,
    required String bucket,
    String? region,
    required String accessKey,
    String? secretKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEndpoint, endpoint.trim());
    await prefs.setString(_kBucket, bucket.trim());
    await prefs.setString(_kRegion, (region ?? '').trim());
    await prefs.setString(_kAccessKey, accessKey.trim());
    await prefs.setString(_kSecretKey, secretKey ?? '');
    await load();
  }

  void cancel() => _token?.cancel();

  /// 连接测试：HeadBucket（认证 + bucket 存在 + 权限一次验证），成功返回提示文案。
  Future<String> testConnection() async {
    await _client().testConnection();
    return '已连接，S3 bucket 可用';
  }

  // ---- 备份 ----

  /// 备份体积估算（**备份前可见性**：把「本次要传多少」在点「备份」之前就显性化）。
  ///
  /// 复用 [_collectLocalFiles]（与 [runBackup] **同一收集器**）——估算与实际上传必须
  /// 是同一套集合，UI 另算一套就会「显示 40MB 实际传 60MB」，比不显示更失信。
  /// 视频单独计数：它是体积大头（video-subject.md §4 过准入门槛即进备份），用户需要
  /// 知道代价主要来自哪里（对应用户拍板的「视频 N 个 / 合计 X MB」）。
  ///
  /// 只读 stat，不触发任何上传；失败返回 null（UI 兜底不展示，绝不阻断备份）。
  /// ⚠️ 这是**本地待传总量**：实际上传按「远端已存在且大小一致」增量跳过，会更少。
  Future<BackupSizeEstimate?> estimateBackup() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final files = await _collectLocalFiles(docs);
      final items = await _repo.list(includeDeleted: true, limit: 100000);
      final videoIds = items
          .where((it) => it.itemType == InboxItem.typeVideo)
          .map((it) => it.id)
          .whereType<String>()
          .toSet();
      var videoCount = 0;
      var videoBytes = 0;
      var totalBytes = 0;
      for (final f in files) {
        totalBytes += f.size;
        // 视频条目关联文件（源视频 + 其切片产物）——两者都是视频体积
        if (f.itemId != null && videoIds.contains(f.itemId)) {
          videoCount++;
          videoBytes += f.size;
        }
      }
      return BackupSizeEstimate(
        fileCount: files.length,
        totalBytes: totalBytes,
        videoCount: videoCount,
        videoBytes: videoBytes,
      );
    } catch (_) {
      return null;
    }
  }

  Future<BackupOutcome> runBackup() async {
    if (busy) throw const S3Exception(S3ErrorKind.protocol, '已有备份/恢复正在进行');
    _transferred = 0;
    _token = CancelToken();
    final token = _token!;
    _setState(BackupState.working);
    File? snapFile;
    try {
      final client = _client();

      // 1) DB 快照（快照副本上物理删除 Vault 行 + VACUUM，见 Repository.snapshotTo）
      _setProgress(const BackupProgress(phase: 'snapshot'));
      final snapDir = await getTemporaryDirectory();
      snapFile = File(p.join(snapDir.path, 'goodshare_backup.db'));
      if (await snapFile.exists()) await snapFile.delete();
      final snap = await _repo.snapshotTo(snapFile);
      final schemaV = await _repo.schemaVersion();

      // 2) 收集本地附件白名单（shares/ 非 Vault 附件 + annotations/ 非 Vault 标注）
      final docs = await getApplicationDocumentsDirectory();
      final files = await _collectLocalFiles(docs);
      final total = files.length;
      // 附件总字节（体积可见性：进度文案显示「已传/总量」，让用户看懂代价与剩余）
      final attachBytes = files.fold<int>(0, (s, f) => s + f.size);
      var skipped = 0;
      var uploaded = 0;
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        _setProgress(
          BackupProgress(
            phase: 'attachments',
            total: total,
            done: i,
            currentLabel: f.rel,
            transferredBytes: _transferred,
            totalBytes: attachBytes,
          ),
        );
        final key = '${S3Client.backupRoot}/attachments/${f.rel}';
        final remoteSize = await client.head(key, token: token);
        // 增量跳过：远端存在且大小一致
        if (remoteSize != null && remoteSize == f.size) {
          skipped++;
          continue;
        }
        await client.putFile(key, f.file, token: token, onProgress: _onSend);
        _transferred += f.size;
        uploaded++;
      }

      // 3) DB 快照
      _setProgress(
        BackupProgress(
          phase: 'db',
          total: 1,
          done: 0,
          currentLabel: 'goodshare.db',
          transferredBytes: _transferred,
          totalBytes: snapFile.lengthSync(),
        ),
      );
      await client.putFile(
        '${S3Client.backupRoot}/db/goodshare.db',
        snapFile,
        token: token,
        onProgress: _onSend,
      );
      _transferred += snapFile.lengthSync();

      // 4) manifest 最后上传 = 提交标记（未更新则远端仍是上一次完整备份；
      //    S3 单对象 PUT 原子，无半截正式对象）
      _setProgress(const BackupProgress(phase: 'manifest', total: 1, done: 0));
      final manifest = BackupManifest(
        ts: DateTime.now().millisecondsSinceEpoch,
        schemaVersion: schemaV,
        itemCount: snap.itemCount,
        vaultExcluded: snap.vaultExcluded,
        dbSize: snapFile.lengthSync(),
        attachments: [
          for (final f in files) BackupAttachment(rel: f.rel, size: f.size, itemId: f.itemId),
        ],
      );
      await client.put(
        '${S3Client.backupRoot}/manifest.json',
        utf8.encode(manifest.encode()),
        token: token,
      );

      // 单文件上传失败会直接上抛终止本轮（设计 §4）；走到这里即全部成功
      final outcome = BackupOutcome.ok(
        message: '备份完成：${snap.itemCount} 条（Vault 排除 ${snap.vaultExcluded}），'
            '上传 $uploaded / 跳过 $skipped',
        itemCount: snap.itemCount,
        vaultExcluded: snap.vaultExcluded,
        uploaded: uploaded,
        skipped: skipped,
      );
      await _recordLast(LastBackup(
        ts: DateTime.now().millisecondsSinceEpoch,
        itemCount: snap.itemCount,
        vaultExcluded: snap.vaultExcluded,
        message: outcome.message,
      ));
      _setState(BackupState.done);
      return outcome;
    } on S3Exception catch (e) {
      if (e.kind == S3ErrorKind.cancelled) {
        _setState(BackupState.cancelled);
        return BackupOutcome.cancelled();
      }
      _setState(BackupState.failed);
      return BackupOutcome.fail(e.message);
    } catch (e) {
      _setState(BackupState.failed);
      return BackupOutcome.fail('备份失败：$e');
    } finally {
      _token = null;
      try {
        if (snapFile != null && await snapFile.exists()) await snapFile.delete();
      } catch (_) {}
    }
  }

  // ---- 恢复 ----

  Future<BackupOutcome> runRestore() async {
    if (busy) throw const S3Exception(S3ErrorKind.protocol, '已有备份/恢复正在进行');
    _transferred = 0;
    _token = CancelToken();
    final token = _token!;
    _setState(BackupState.working);
    File? dbTemp;
    try {
      final client = _client();

      // 1) manifest 下载 + 强校验（坏 manifest 整体拒绝，不可信远端不逐条冒险）
      _setProgress(const BackupProgress(phase: 'restore_manifest'));
      final snapDir = await getTemporaryDirectory();
      final mfTemp = File(p.join(snapDir.path, 'manifest.json'));
      if (await mfTemp.exists()) await mfTemp.delete();
      await client.get('${S3Client.backupRoot}/manifest.json', mfTemp, token: token);
      final manifest = BackupManifest.decode(await mfTemp.readAsString());
      for (final a in manifest.attachments) {
        if (!isSafeBackupRel(a.rel)) {
          throw const S3Exception(S3ErrorKind.server, '备份清单含不安全路径，已拒绝恢复');
        }
      }

      // 2) DB 快照下载（校验大小防截断）→ 全量替换导入（云端为源）
      _setProgress(const BackupProgress(phase: 'restore_db'));
      dbTemp = File(p.join(snapDir.path, 'goodshare_restore.db'));
      if (await dbTemp.exists()) await dbTemp.delete();
      await client.get(
        '${S3Client.backupRoot}/db/goodshare.db',
        dbTemp,
        expectedSize: manifest.dbSize,
        token: token,
        onProgress: _onSend,
      );
      final restored = await _repo.restoreFrom(dbTemp);
      _transferred += manifest.dbSize;

      // 3) 附件下载：单文件失败不阻断（条目已恢复，附件缺失走既有「文件缺失」UI 降级态）
      final docs = await getApplicationDocumentsDirectory();
      final atts = manifest.attachments;
      final total = atts.length;
      var restoredAtts = 0;
      var skippedAtts = 0;
      final failed = <String>[];
      for (var i = 0; i < atts.length; i++) {
        final a = atts[i];
        _setProgress(
          BackupProgress(
            phase: 'restore_attachments',
            total: total,
            done: i,
            currentLabel: a.rel,
            transferredBytes: _transferred,
          ),
        );
        final target = File(p.join(docs.path, a.rel));
        try {
          if (await target.exists()) {
            final sz = await target.length();
            if (sz == a.size) {
              skippedAtts++;
              continue;
            }
            await target.delete(); // 大小不符 = 本地文件已变，整体重下
          }
          await target.parent.create(recursive: true);
          await client.get(
            '${S3Client.backupRoot}/attachments/${a.rel}',
            target,
            expectedSize: a.size,
            token: token,
            onProgress: _onSend,
          );
          _transferred += a.size;
          restoredAtts++;
        } catch (e) {
          if (e is S3Exception && e.kind == S3ErrorKind.cancelled) rethrow;
          failed.add(a.rel);
        }
      }

      final outcome = BackupOutcome.ok(
        message: '恢复完成：${restored.itemCount} 条；附件 恢复 $restoredAtts / 跳过 $skippedAtts / 失败 ${failed.length}'
            '${manifest.vaultExcluded > 0 ? '；Vault ${manifest.vaultExcluded} 条未备份（未加密）' : ''}',
        itemCount: restored.itemCount,
        vaultExcluded: manifest.vaultExcluded,
        uploaded: restoredAtts,
        skipped: skippedAtts,
        failed: failed,
      );
      _setState(BackupState.done);
      return outcome;
    } on S3Exception catch (e) {
      if (e.kind == S3ErrorKind.cancelled) {
        _setState(BackupState.cancelled);
        return BackupOutcome.cancelled();
      }
      _setState(BackupState.failed);
      return BackupOutcome.fail(e.message);
    } catch (e) {
      _setState(BackupState.failed);
      return BackupOutcome.fail('恢复失败：$e');
    } finally {
      _token = null;
      try {
        if (dbTemp != null && await dbTemp.exists()) await dbTemp.delete();
      } catch (_) {}
    }
  }

  // ---- 内部 ----

  S3Client _client() {
    if ((_endpoint ?? '').trim().isEmpty || (_bucket ?? '').trim().isEmpty) {
      throw const S3Exception(S3ErrorKind.protocol, '请先在设置中填写 S3 endpoint 与 bucket');
    }
    return S3Client(
      endpoint: _endpoint!,
      bucket: _bucket!,
      region: (_region ?? '').isEmpty ? 'us-east-1' : _region!,
      accessKey: _accessKey ?? '',
      secretKey: _secretKey ?? '',
    );
  }

  /// 收集本地备份白名单（**白名单制**，绝不整扫 documents——LLM/ASR 模型目录不得进备份）。
  Future<List<LocalBackupFile>> _collectLocalFiles(Directory docs) async {
    final docsPath = docs.path;
    final publicItems = await _repo.list(includeDeleted: true, limit: 100000);
    final vaultItems = await _repo.list(vault: true, includeDeleted: true, limit: 100000);
    final vaultIds = vaultItems.map((e) => e.id).whereType<String>().toSet();
    return collectBackupFiles(items: publicItems, vaultIds: vaultIds, docsPath: docsPath);
  }

  void _onSend(int sent, int? total) {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 300) return; // 进度广播节流
    _lastNotify = now;
    _progress = _progress.copyWith(transferredBytes: _transferred + sent);
    notifyListeners();
  }

  void _setState(BackupState s) {
    _state = s;
    _progress = const BackupProgress();
    notifyListeners();
  }

  void _setProgress(BackupProgress prog) {
    _progress = prog;
    notifyListeners();
  }

  Future<void> _recordLast(LastBackup lb) async {
    _last = lb;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLast, lb.toJson());
  }
}

/// 行内媒体收集：解析条目 human_md 的媒体块，`local://` 标记换算成 documents
/// 相对路径收进白名单（同 rel 只收一次；Vault 条目不进本函数的 items——调用方已过滤）。
Future<List<LocalBackupFile>> _collectInlineMediaFiles(
  InboxItem it,
  String docsPath,
  Set<String> seenRels,
) async {
  final md = it.humanMd;
  if (md == null || md.isEmpty) return const [];
  final files = <LocalBackupFile>[];
  for (final b in MarkdownSubsetParser().parse(md)) {
    final url = switch (b) {
      ImageBlock(:final url) => url,
      AudioBlock(:final url) => url,
      VideoBlock(:final url) => url,
      _ => null,
    };
    if (url == null || !url.startsWith('local://')) continue;
    final rel = url.substring('local://'.length);
    if (!isSafeBackupRel(rel) || !seenRels.add(rel)) continue;
    try {
      final f = File(p.join(docsPath, rel));
      final st = await f.stat();
      if (st.size <= 0) continue;
      files.add(LocalBackupFile(file: f, rel: rel, size: st.size, itemId: it.id));
    } catch (_) {}
  }
  return files;
}

/// 备份白名单收集（可单测的文件系统扫描；2026-09-29 D3 拍板，设计 s3-backup.md §4）：
/// - 条目原始附件：**过门槛收进来的视频进备份**（video-subject.md §4「收进来 = 系统认可
///   = 进备份」——判断条件只有一个，无特例表）；门槛已拦掉超阈值整片，故体积上界有界。
///   未真正收进来的（SAF 引用型，路径不在 app documents 内）由下方纵深防御自然排除
/// - annotations/：图片标注；subtitles/ + translations/：转写字幕与译文（关键产物，小体积文本）
/// - 派生文件名首段为来源条目 id，Vault 条目的派生文件同样排除
Future<List<LocalBackupFile>> collectBackupFiles({
  required List<InboxItem> items,
  required Set<String> vaultIds,
  required String docsPath,
}) async {
  final out = <LocalBackupFile>[];
  final seenRels = <String>{};

  for (final it in items) {
    // 行内媒体（便签作曲器产出，human_md 内 `local://` 标记，2026-09-30 拍板①）：
    // 是条目的用户资产，随条目进备份——与原始附件的收进判定各走各的收集通道
    out.addAll(await _collectInlineMediaFiles(it, docsPath, seenRels));
    // 收进判定（video-subject.md §4）：**不按 item_type 排除**——「过门槛收进来的就在
    // 备份里」；未真正收进的（引用型，路径不在 app documents 内）由下方 isWithin 排除。
    final path = it.rawFilePath;
    if (path == null || path.isEmpty) continue;
    // 纵深防御：只收 app documents 内的路径（rawFilePath 理论上必然在内）
    if (!p.isWithin(docsPath, path)) continue;
    final rel = p.relative(path, from: docsPath);
    if (!isSafeBackupRel(rel)) continue;
    if (!seenRels.add(rel)) continue;
    try {
      final st = await File(path).stat();
      if (st.size <= 0) continue;
      out.add(LocalBackupFile(file: File(path), rel: rel, size: st.size, itemId: it.id));
    } catch (_) {}
  }

  // clip_segments/ = 用户主动提取的视频片段（关键产物，小体积）
  for (final dirName in const ['annotations', 'subtitles', 'translations', 'clip_segments']) {
    final dir = Directory(p.join(docsPath, dirName));
    if (!await dir.exists()) continue;
    for (final e in await dir.list().toList()) {
      if (e is! File) continue;
      final itemId = derivedArtifactItemId(p.basename(e.path));
      if (itemId != null && vaultIds.contains(itemId)) continue; // Vault 条目的派生文件同样排除
      try {
        final st = await e.stat();
        if (st.size <= 0) continue;
        final rel = p.relative(e.path, from: docsPath);
        if (!isSafeBackupRel(rel)) continue;
        out.add(LocalBackupFile(file: e, rel: rel, size: st.size, itemId: itemId));
      } catch (_) {}
    }
  }
  return out;
}

// ---- 状态与结果模型 ----

enum BackupState { idle, working, done, failed, cancelled }

/// 备份/恢复进度（UI 直接消费：phase 文案 + done/total 进度条 + currentLabel 当前文件）。
class BackupProgress {
  const BackupProgress({
    this.phase = '',
    this.total = 0,
    this.done = 0,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.currentLabel = '',
  });

  /// snapshot/attachments/db/manifest/restore_manifest/restore_db/restore_attachments
  final String phase;
  final int total;
  final int done;
  final int transferredBytes;

  /// 本阶段待传总字节（0=未知）。与 [transferredBytes] 配对，供进度文案显示
  /// 「12.3 MB / 48.2 MB」——体积可见性的「备份中」一半（用户要能看懂还剩多少）。
  final int totalBytes;
  final String currentLabel;

  BackupProgress copyWith({
    String? phase,
    int? total,
    int? done,
    int? transferredBytes,
    int? totalBytes,
    String? currentLabel,
  }) =>
      BackupProgress(
        phase: phase ?? this.phase,
        total: total ?? this.total,
        done: done ?? this.done,
        transferredBytes: transferredBytes ?? this.transferredBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        currentLabel: currentLabel ?? this.currentLabel,
      );
}

/// 一次备份/恢复的收尾结果（UI 以 SnackBar 展示 message；failed 非空时列表可展开）。
class BackupOutcome {
  const BackupOutcome({
    required this.ok,
    required this.cancelled,
    required this.message,
    this.itemCount,
    this.vaultExcluded,
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = const [],
  });

  factory BackupOutcome.ok({
    required String message,
    int? itemCount,
    int? vaultExcluded,
    int uploaded = 0,
    int skipped = 0,
    List<String> failed = const [],
  }) =>
      BackupOutcome(
        ok: true,
        cancelled: false,
        message: message,
        itemCount: itemCount,
        vaultExcluded: vaultExcluded,
        uploaded: uploaded,
        skipped: skipped,
        failed: failed,
      );

  factory BackupOutcome.fail(String message) =>
      BackupOutcome(ok: false, cancelled: false, message: message);

  factory BackupOutcome.cancelled() =>
      const BackupOutcome(ok: false, cancelled: true, message: '已取消（远端旧备份不受影响）');

  final bool ok;
  final bool cancelled;
  final String message;
  final int? itemCount;
  final int? vaultExcluded;
  final int uploaded;
  final int skipped;
  final List<String> failed;
}

/// 最近一次备份记录（设置页状态行展示）。
class LastBackup {
  const LastBackup({
    required this.ts,
    required this.itemCount,
    required this.vaultExcluded,
    required this.message,
  });

  final int ts;
  final int itemCount;
  final int vaultExcluded;
  final String message;

  String toJson() => jsonEncode({
        'ts': ts,
        'item_count': itemCount,
        'vault_excluded': vaultExcluded,
        'message': message,
      });

  factory LastBackup.fromJson(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map) throw const FormatException('last backup 记录非法');
    final m = j.cast<String, Object?>();
    return LastBackup(
      ts: (m['ts'] as int?) ?? 0,
      itemCount: (m['item_count'] as int?) ?? 0,
      vaultExcluded: (m['vault_excluded'] as int?) ?? 0,
      message: (m['message'] as String?) ?? '',
    );
  }
}

/// 备份体积估算（备份前可见性：把「本次要传多少」显性化）。
///
/// 由 [BackupService.estimateBackup] 产出，复用与 [runBackup] 同一收集器，
/// 故**显示的数字 = 真正会传的集合**。
class BackupSizeEstimate {
  const BackupSizeEstimate({
    required this.fileCount,
    required this.totalBytes,
    required this.videoCount,
    required this.videoBytes,
  });

  final int fileCount;
  final int totalBytes;

  /// 视频条目关联文件数（源视频 + 其切片产物）——体积大头，单独可见。
  final int videoCount;
  final int videoBytes;
}

/// 待上传附件条目（本地收集结果）。
class LocalBackupFile {
  const LocalBackupFile({required this.file, required this.rel, required this.size, this.itemId});

  final File file;
  final String rel;
  final int size;
  final String? itemId;
}
