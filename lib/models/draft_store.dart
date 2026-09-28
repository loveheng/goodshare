import '../data/repository.dart';

/// 草稿领域存储：封装 drafts 表的读写 / 删除，UI 经此落盘，不直连 sqflite。
/// 对应规范「移动端健壮性底层规则 · 一、状态恢复」——大段输入防抖写本地临时表，
/// 进程被杀后重开可无缝恢复半成品。
class DraftStore {
  DraftStore([Repository? repo]) : _repo = repo ?? Repository();

  final Repository _repo;

  Future<void> save(String id, String targetId, String content) =>
      _repo.upsertDraft(id, targetId, content);

  Future<String?> load(String id) => _repo.getDraft(id);

  Future<void> delete(String id) => _repo.deleteDraft(id);
}
