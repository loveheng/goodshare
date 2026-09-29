/// 工作区（2026-09-30）：条目集合容器，与条目**多对多**。
///
/// SSOT：docs/design/ui-spec.md §4.11（对应 mymind 的 Spaces）。
///
/// 与「AI 分类标签（facets）」的区别（务必分清，否则两套会互相污染）：
/// - 标签是 AI 产出的**属性**：扁平、用户不能创建、只能筛选
/// - 工作区是**容器**：用户可创建 / 命名 / 增删条目，一个条目可进多个工作区
///
/// 隐私：Vault 条目可进工作区，但外部（MCP）列工作区内容时仍受 `is_vault=0`
/// 约束——工作区不得成为隐私隔离的后门。
class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final int createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'created_at': createdAt,
      };

  static Workspace fromMap(Map<String, Object?> m) => Workspace(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
      );
}
