/// 收集条目：分享进来的「好东西」统一数据模型。
class CollectItem {
  static const typeText = 'TEXT';
  static const typeLink = 'LINK';
  static const typeImage = 'IMAGE';
  static const typeVideo = 'VIDEO';
  static const typeAudio = 'AUDIO';
  static const typeFile = 'FILE';

  CollectItem({
    this.id,
    required this.type,
    this.title,
    this.text,
    this.mime,
    this.sourcePackage,
    this.sourceApp,
    List<String> tags = const [],
    List<String> files = const [],
    required this.createdAt,
  })  : tags = List.unmodifiable(tags),
        files = List.unmodifiable(files);

  final int? id;
  final String type;
  final String? title;
  final String? text;
  final String? mime;
  final String? sourcePackage;
  final String? sourceApp;
  final List<String> tags;
  final List<String> files;
  final int createdAt;

  bool get isImage => type == typeImage;
  bool get hasAttachment => files.isNotEmpty;

  /// 列表/搜索预览：优先标题，其次正文首行。
  String get preview {
    final base = (title?.isNotEmpty ?? false) ? title! : (text ?? '');
    final oneLine = base.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'type': type,
        'title': title,
        'text': text,
        'mime': mime,
        'source_package': sourcePackage,
        'source_app': sourceApp,
        'tags': tags.join(','),
        'files': files.join('\n'),
        'created_at': createdAt,
      };

  static CollectItem fromMap(Map<String, Object?> map) => CollectItem(
        id: map['id'] as int?,
        type: (map['type'] as String?) ?? typeText,
        title: map['title'] as String?,
        text: map['text'] as String?,
        mime: map['mime'] as String?,
        sourcePackage: map['source_package'] as String?,
        sourceApp: map['source_app'] as String?,
        tags: ((map['tags'] as String?) ?? '')
            .split(',')
            .where((t) => t.isNotEmpty)
            .toList(),
        files: ((map['files'] as String?) ?? '')
            .split('\n')
            .where((f) => f.isNotEmpty)
            .toList(),
        createdAt: (map['created_at'] as int?) ?? 0,
      );
}
