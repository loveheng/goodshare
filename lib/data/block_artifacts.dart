/// 块产物（Block Artifact）派生数据存取（schema v21，2026-10-05）。
///
/// 行内媒体块 AI 能力的产物存储：转写/字幕/OCR/译文/摘要/音轨。
/// 结构 SSOT：docs/design/block-artifact-workflow.md §2.2/§2.5。
///
/// 派生缓存治理（与 item_embeddings 同构，非条目域写）：
/// - 不 bump 乐观锁 version、不 notifyListeners（不进条目 UI 读路径；
///   工作流页经任务落定轮询后显式重读刷新）；
/// - 不进 S3 备份（快照清空）、恢复即清、UNIQUE 重跑覆盖、条目删除外键级联；
/// - **文件产物磁盘联动删除**（§2.2 纪律 7）：subtitle/audio_file 凡删行必删盘
///   ——先删 DB 行，后删物理文件（失败仅记日志：产物可重算，孤儿文件可接受；
///   与媒体回收站「宁滞留不丢」口径相反，那边是用户事实数据、这边是缓存）。
///
/// **双产物原子落库**（§2.5）：转写的 transcript + subtitle 两行经 [BlockArtifactStore.upsertAll]
/// 单事务全有或全无——半态会让「按产物反推续点」误判转写已完成，字幕永远缺失。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// 产物类型与块 key 常量（编译期封闭集合：新 kind 须同步设计稿 §2.3 表与产物卡渲染）。
final class BlockArtifactKind {

  /// 顶级条目（整条音/视频/图片）的固定 block_key。
  static const topLevelKey = 'item';

  static const transcript = 'transcript';
  static const subtitle = 'subtitle';
  static const ocrText = 'ocr_text';
  static const translation = 'translation';
  static const summary = 'summary';
  static const audioFile = 'audio_file';

  /// 有 file_path 的 kind（磁盘联动删除的作用域）。
  static const fileBacked = {subtitle, audioFile};
}

/// 一次 upsert 的载荷：kind → 内容（text / filePath / metaJson 至少其一非空）。
class BlockArtifactInput {
  const BlockArtifactInput(this.kind, {this.text, this.filePath, this.metaJson});

  final String kind;
  final String? text;
  final String? filePath;
  final String? metaJson;
}

/// 单条块产物（读取行模型）。
class BlockArtifact {
  const BlockArtifact({
    required this.itemId,
    required this.blockKey,
    required this.kind,
    this.text,
    this.filePath,
    this.metaJson,
    required this.createdAt,
    required this.updatedAt,
  });

  final String itemId;
  final String blockKey;
  final String kind;
  final String? text;
  final String? filePath;
  final String? metaJson;
  final int createdAt;
  final int updatedAt;

  /// meta_json 里的 cue 数（字幕 / 转写产物落库时写入，产物卡摘要「N 段」数据源）。
  ///
  /// 解码留在数据层：UI 不内联 jsonDecode（arch-guard R2-ui-json-codec）——
  /// 坏值 / 非 Map 一律回落 null，视图侧退候选文案。
  int? get cueCount {
    final raw = metaJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      return m is Map && m['cues'] is int ? m['cues'] as int : null;
    } catch (_) {
      return null;
    }
  }

  /// 实测耗时毫秒（§4 卡头耗时；queue_consumer 执行侧注入）——null = 未记录
  ///（旧产物 / 非块通道写入）。
  int? get elapsedMs {
    final raw = metaJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      return m is Map && m['elapsed_ms'] is int ? m['elapsed_ms'] as int : null;
    } catch (_) {
      return null;
    }
  }

  factory BlockArtifact._fromRow(Map<String, Object?> r) => BlockArtifact(
        itemId: r['item_id'] as String,
        blockKey: r['block_key'] as String,
        kind: r['kind'] as String,
        text: r['text'] as String?,
        filePath: r['file_path'] as String?,
        metaJson: r['meta_json'] as String?,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
      );
}

/// block_artifacts 表存取（派生缓存原语，不经 ItemActionHandler，同 replaceItemEmbeddings 口径）。
class BlockArtifactStore {
  BlockArtifactStore(this._dbFactory);

  final Future<Database> Function() _dbFactory;

  /// 单事务落一批产物（同块同任务的多产物必须一起落：转写双产物原子性）。
  ///
  /// ON CONFLICT 覆盖（重跑 Reset 的存储侧语义）；被顶替的旧文件产物
  /// （file_path 变化的 subtitle/audio_file）在新行写入后删盘（纪律 7 覆盖重跑路径）。
  Future<void> upsertAll(
    String itemId,
    String blockKey,
    List<BlockArtifactInput> artifacts, {
    Transaction? txn,
  }) async {
    if (artifacts.isEmpty) return;
    final db = txn ?? await _dbFactory();
    // 先快照将被顶替的旧文件路径（upsert 前），写完再删盘
    final kinds = artifacts.map((a) => a.kind).toList();
    final placeholders = List.filled(kinds.length, '?').join(', ');
    final oldRows = await db.rawQuery(
      'SELECT file_path FROM block_artifacts '
      'WHERE item_id = ? AND block_key = ? AND kind IN ($placeholders) '
      "AND file_path IS NOT NULL AND file_path != ''",
      [itemId, blockKey, ...kinds],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    Future<void> write(DatabaseExecutor executor) async {
      for (final a in artifacts) {
        await executor.rawInsert(
          'INSERT INTO block_artifacts '
          '(item_id, block_key, kind, text, file_path, meta_json, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(item_id, block_key, kind) DO UPDATE SET '
          'text = excluded.text, file_path = excluded.file_path, '
          'meta_json = excluded.meta_json, updated_at = excluded.updated_at',
          [itemId, blockKey, a.kind, a.text, a.filePath, a.metaJson, now, now],
        );
      }
    }

    if (txn != null) {
      await write(txn);
    } else {
      await (await _dbFactory()).transaction(write);
    }
    await _deleteFilesQuietly(
      oldRows.map((r) => r['file_path'] as String).toSet()
        ..removeAll(artifacts.map((a) => a.filePath).whereType<String>()),
    );
  }

  /// 读单条产物（动作层校验「源产物已存在非空」用；批量事务内传 [txn] 保持读一致）。
  Future<BlockArtifact?> get(
    String itemId,
    String blockKey,
    String kind, {
    Transaction? txn,
  }) async {
    final db = txn ?? await _dbFactory();
    final rows = await db.query(
      'block_artifacts',
      where: 'item_id = ? AND block_key = ? AND kind = ?',
      whereArgs: [itemId, blockKey, kind],
      limit: 1,
    );
    return rows.isEmpty ? null : BlockArtifact._fromRow(rows.first);
  }

  /// 读某条目全部产物（可按块过滤，工作流页续跑数据源）。
  Future<List<BlockArtifact>> listForItem(String itemId, {String? blockKey}) async {
    final db = await _dbFactory();
    final rows = await db.query(
      'block_artifacts',
      where: blockKey == null ? 'item_id = ?' : 'item_id = ? AND block_key = ?',
      whereArgs: blockKey == null ? [itemId] : [itemId, blockKey],
      orderBy: 'rowid',
    );
    return [for (final r in rows) BlockArtifact._fromRow(r)];
  }

  /// 按块分组读取（三级页一次拉全，按 block_key 归桶渲染工作流轨）。
  Future<Map<String, List<BlockArtifact>>> groupedForItem(String itemId) async {
    final grouped = <String, List<BlockArtifact>>{};
    for (final a in await listForItem(itemId)) {
      (grouped[a.blockKey] ??= []).add(a);
    }
    return grouped;
  }

  /// 清一个块的全部产物（Reset / 编辑 GC：媒体行被移除）。
  Future<void> deleteBlock(String itemId, String blockKey, {Transaction? txn}) async {
    final db = txn ?? await _dbFactory();
    final files = await _filePathsOf(db, 'item_id = ? AND block_key = ?', [itemId, blockKey]);
    await db.delete(
      'block_artifacts',
      where: 'item_id = ? AND block_key = ?',
      whereArgs: [itemId, blockKey],
    );
    await _deleteFilesQuietly(files);
  }

  /// 清某条目全部产物（条目删除级联；先收文件路径再删行，删行后删盘）。
  ///
  /// 在调用方事务内传入 [txn] 时行删除随事务提交/回滚；文件删除是文件系统
  /// 副作用不随事务回滚（同 deleteForever 附件口径），失败仅记日志。
  Future<void> clearForItem(String itemId, {Transaction? txn}) async {
    final db = txn ?? await _dbFactory();
    final files = await _filePathsOf(db, 'item_id = ?', [itemId]);
    if (files.isEmpty) {
      await db.delete('block_artifacts', where: 'item_id = ?', whereArgs: [itemId]);
      return;
    }
    await db.delete('block_artifacts', where: 'item_id = ?', whereArgs: [itemId]);
    await _deleteFilesQuietly(files);
  }

  /// 清全表（恢复即清：事实源全量替换后缓存归零）。
  Future<void> clearAll({Transaction? txn}) async {
    final db = txn ?? await _dbFactory();
    final files = await _filePathsOf(db, '1 = 1', const []);
    await db.delete('block_artifacts');
    await _deleteFilesQuietly(files);
  }

  /// 全表文件产物路径（备份侧判定 / 测试断言用）。
  Future<List<String>> allFilePaths() async =>
      _filePathsOf(await _dbFactory(), '1 = 1', const []);

  /// 删除指定产物文件（restoreFrom 专用：行级清理随恢复事务，文件删除在
  /// 事务外按恢复前快照路径执行——文件系统副作用不随事务回滚，同 deleteForever 口径）。
  Future<void> deleteArtifactFiles(Iterable<String> paths) => _deleteFilesQuietly(paths);

  static Future<List<String>> _filePathsOf(
    DatabaseExecutor db,
    String extraWhere,
    List<Object?> args,
  ) async {
    final rows = await db.query(
      'block_artifacts',
      columns: ['file_path'],
      where: "file_path IS NOT NULL AND file_path != '' AND ($extraWhere)",
      whereArgs: args,
    );
    return [for (final r in rows) r['file_path'] as String];
  }

  /// 删行后删盘（失败仅记日志：派生缓存可重算，孤儿文件不阻断）。
  static Future<void> _deleteFilesQuietly(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('[BlockArtifactStore] artifact file delete failed (kept): $path: $e');
      }
    }
  }
}
