import 'package:flutter/material.dart';

import '../models/item.dart';

/// 列表通用卡片（设计 §6 ContentCard）：type 图标 + 预览 + 元信息。
class ContentCard extends StatelessWidget {
  const ContentCard({super.key, required this.item, this.onTap});

  final InboxItem item;
  final VoidCallback? onTap;

  static IconData iconOf(String type) => switch (type) {
        InboxItem.typeUrl => Icons.link,
        InboxItem.typeImage => Icons.image_outlined,
        InboxItem.typeVideo => Icons.movie_outlined,
        InboxItem.typeAudio => Icons.audiotrack,
        InboxItem.typeChatlog => Icons.forum_outlined,
        InboxItem.typeDocument => Icons.insert_drive_file_outlined,
        _ => Icons.notes,
      };

  static String labelOf(String type) => switch (type) {
        InboxItem.typeNote => '便签',
        InboxItem.typeUrl => '链接',
        InboxItem.typeImage => '图片',
        InboxItem.typeVideo => '视频',
        InboxItem.typeAudio => '音频',
        InboxItem.typeChatlog => '聊天',
        InboxItem.typeDocument => '文档',
        _ => type,
      };

  String _timeLabel(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(iconOf(item.itemType)),
      title: Text(
        item.preview.isEmpty ? '（无文本内容）' : item.preview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (item.sourceApp?.isNotEmpty ?? false) item.sourceApp!,
          _timeLabel(item.createdAt),
          if (item.tags.isNotEmpty) '#${item.tags.join(' #')}',
          if (item.hasAttachment) '📎',
          if (item.editLocked) '🔒合并',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
