/// 内容生产模板（2026-10-14 v23，ai-template）：AI 托管的事实源。
///
/// `body_md` 为**单一源**双派生——人类视图渲染它成完整模板样式、AI skill 文件
/// 从它派生；AI 经 MCP 建/改/删，人类端只读（管理权归 AI、有意不对称，见 ADR）。
/// 挂靠 workspace，外键级联清理（PRAGMA foreign_keys=ON）。
class Template {
  const Template({
    required this.id,
    required this.workspaceId,
    required this.name,
    this.description,
    required this.bodyMd,
    this.origin = 'ai',
    this.version = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String workspaceId;
  final String name;
  final String? description;

  /// 单一事实源：markdown 结构骨架，`{{占位符}}` 由填充时替换；
  /// 人类预览页直接渲染它，AI skill 文件由它派生。
  final String bodyMd;

  /// 来源：'ai' = AI 经 MCP 生成 / 'official' = 官方预置 / 'user' = 人类手动创建。
  /// 'user' **已预留、暂不放开**：数据模型从首版即支持人类来源，但人类编辑入口
  /// 遵循 ADR「人类只读、AI 管理」暂不开放——放开时仅需加 UI 入口，无需再动 schema。
  final String origin;

  /// 乐观锁版本号：任何写 +1，CAS 校验用。
  final int version;
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'workspace_id': workspaceId,
        'name': name,
        'description': description,
        'body_md': bodyMd,
        'origin': origin,
        'version': version,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  static Template fromMap(Map<String, Object?> m) => Template(
        id: (m['id'] as String?) ?? '',
        workspaceId: (m['workspace_id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        description: m['description'] as String?,
        bodyMd: (m['body_md'] as String?) ?? '',
        origin: (m['origin'] as String?) ?? 'ai',
        version: (m['version'] as int?) ?? 0,
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
      );
}
