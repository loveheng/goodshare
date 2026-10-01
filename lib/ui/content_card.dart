import 'dart:io';

import 'package:flutter/material.dart';

import '../ai/palette_reconstructor.dart' show colorFromMachineJson;
import '../models/item.dart';
import 'goodshare_image.dart';
import 'tokens.dart';

/// 瀑布流通用卡片（2026-09-30 改版，用户拍板「瀑布式卡片布局」取代文档行列表）：
/// 图片条目以真图铺卡顶（高度自适应原图比例，瀑布流错落），文本条目以预览文字
/// 为主体；底部统一元信息行。非图片条目高度由内容自然决定，MasonryGridView
/// 负责按实际高度排布。
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

  /// 卡顶媒体区：图片条目真图铺满（不限高——瀑布流按比例错落）；
  /// 其余类型给一个矮的 type 色带图标头，与图片卡形成节奏差。
  Widget _media(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (item.isImage && item.hasAttachment) {
      final image = GoodshareImage(
        file: File(item.rawFilePath!),
        fit: BoxFit.cover,
        // 瀑布流卡宽约半屏；4x 保证竖长图放大不糊，同时严格限解码宽
        cacheWidth: 1080,
        // V3 主色调占位：解码完成前先铺主色，配合 AspectRatio 零跳动
        placeholderColor: colorFromMachineJson(item.machineJson),
        errorBuilder: (_, _, _) => SizedBox(
          height: 96,
          child: Icon(iconOf(item.itemType), size: 40, color: scheme.outline),
        ),
      );
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.md)),
        // 尺寸前置（rich-text-component.md §6.1 V1）：有宽高比时先按比例占位，
        // 图片解码完成不引起瀑布流高度跳动；无比例退回内在尺寸自适应
        child: item.aspectRatio != null
            ? AspectRatio(aspectRatio: item.aspectRatio!, child: image)
            : image,
      );
    }
    return SizedBox(
      height: 72,
      width: double.infinity,
      child: Icon(iconOf(item.itemType), size: 32, color: scheme.outline),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final preview = item.preview.isEmpty ? '（无文本内容）' : item.preview;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      elevation: 0,
      // mymind 基准（ui-spec §2.1/§2.3）：卡层色 + 大圆角 20（Radii.xl）。
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _media(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, Insets.md, Insets.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview,
                    style: textTheme.bodyMedium,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Insets.xs),
                  Text(
                    [
                      if (item.sourceApp?.isNotEmpty ?? false) item.sourceApp!,
                      _timeLabel(item.createdAt),
                      if (item.tags.isNotEmpty) '#${item.tags.join(' #')}',
                      if (item.hasAttachment && !item.isImage) '📎',
                      if (item.editLocked) '🔒',
                    ].join(' · '),
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
