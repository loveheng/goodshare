import 'dart:convert';

import '../data/repository.dart';

/// 速记条草稿 payload（quick-note-draft.md §2.1）：段序列 + 标签 + 待办模式
/// + 面板展开态。编解码收口在本类——UI 层禁内联 jsonDecode/Encode（R2 硬规则）。
/// 段行编码与速记条静态缓存同源：['t',文本] / ['i',图url] / ['a',音url] /
/// ['v',视频url]，第 3 位可选 = 媒体 alt/label（编辑器统一后详情已有条目
/// 的媒体说明随段进出，2026-10-03；缺省 = 旧格式兼容）。
class QuickNoteDraft {
  const QuickNoteDraft({
    required this.segs,
    this.tags = const [],
    this.todo = false,
    this.expanded = false,
  });

  final List<List<String>> segs;
  final List<String> tags;
  final bool todo;
  final bool expanded;

  String encode() => jsonEncode({
        'segs': segs,
        'tags': tags,
        'todo': todo,
        'expanded': expanded,
      });

  /// 损坏（非 Map / 类型漂移）返回 null，调用方按降级处理（不阻断书写）。
  static QuickNoteDraft? tryDecode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return QuickNoteDraft(
        segs: [
          for (final r in (json['segs'] as List? ?? const []).whereType<List>())
            [
              r.first as String,
              if (r.length > 1) r[1] as String,
              if (r.length > 2) r[2] as String,
            ],
        ],
        tags: [
          for (final t in (json['tags'] as List? ?? const []).whereType<String>()) t,
        ],
        todo: json['todo'] == true,
        expanded: json['expanded'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 草稿持久化契约：UI 宿主经此读写持久草稿，不直连 sqflite。
/// 抽象出来的目的（quick-note-draft.md）：widget 测试可注入内存实现——
/// FFI 内存库跨用例共享会让 flush 的草稿泄漏进下一用例的磁盘恢复，
/// 注入 [InMemoryDraftStore] 即与 sqflite 彻底解耦（也避开 fake async
/// 区裸 await 真实 IO 的死锁）。
abstract class DraftPersistencer {
  Future<void> save(String id, String targetId, String content);

  Future<String?> load(String id);

  Future<void> delete(String id);
}

/// 草稿领域存储：drafts 表实现（生产路径）。
/// 对应规范「移动端健壮性底层规则 · 一、状态恢复」——大段输入防抖写本地临时表，
/// 进程被杀后重开可无缝恢复半成品。
class DraftStore implements DraftPersistencer {
  DraftStore([Repository? repo]) : _repo = repo ?? Repository();

  final Repository _repo;

  @override
  Future<void> save(String id, String targetId, String content) =>
      _repo.upsertDraft(id, targetId, content);

  @override
  Future<String?> load(String id) => _repo.getDraft(id);

  @override
  Future<void> delete(String id) => _repo.deleteDraft(id);
}

/// 内存实现（widget 测试 / 预览用）：无 IO、无跨用例状态。
class InMemoryDraftStore implements DraftPersistencer {
  final Map<String, String> _data = {};

  @override
  Future<void> save(String id, String targetId, String content) async =>
      _data[id] = content;

  @override
  Future<String?> load(String id) async => _data[id];

  @override
  Future<void> delete(String id) async => _data.remove(id);
}
