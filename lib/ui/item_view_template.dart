import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/item.dart';

/// 详情查看模板 + 按类型注册表（设计 §4.3/§6）。
/// 通用外壳（tldr/标题/机器态切换/元信息/操作）由 ItemViewTemplate 承载，
/// 类型专属区由 ItemViewRegistry.resolve(itemType) 的实现填充——
/// 新增类型 = 实现专属区 + 注册，框架零改动（与 AiReconstructor 同构）。
typedef ItemViewBuilder = Widget Function(BuildContext context, InboxItem item);

class ItemViewRegistry {
  ItemViewRegistry._();

  static final Map<String, ItemViewBuilder> _views = {
    InboxItem.typeNote: _textView,
    InboxItem.typeChatlog: _textView,
    InboxItem.typeDocument: _documentView,
    InboxItem.typeUrl: _textView,
    InboxItem.typeImage: _imageView,
    InboxItem.typeVideo: _mediaView,
    InboxItem.typeAudio: _mediaView,
  };

  /// 注册/覆盖某类型的专属区（扩展点）。
  static void register(String itemType, ItemViewBuilder builder) =>
      _views[itemType] = builder;

  static ItemViewBuilder resolve(String itemType) =>
      _views[itemType] ?? _fallbackView;
}

/// 详情页模板：双态呈现 + 类型专属区。
class ItemViewTemplate extends StatefulWidget {
  const ItemViewTemplate({super.key, required this.item});

  final InboxItem item;

  @override
  State<ItemViewTemplate> createState() => _ItemViewTemplateState();
}

class _ItemViewTemplateState extends State<ItemViewTemplate> {
  bool _machineMode = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部固定 TL;DR（人类态摘要）
        if (item.humanTldr?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              item.humanTldr!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        if (item.humanTitle?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(item.humanTitle!, style: theme.textTheme.titleLarge),
          ),
        // 机器态切换（双态呈现：机器态需显式切换；空态明示 V1 基础模式）
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text('机器态', style: theme.textTheme.labelLarge),
              Switch(
                value: _machineMode,
                onChanged: (_) => setState(() => _machineMode = !_machineMode),
              ),
              if (_machineMode && (item.machineJson == null || item.machineJson!.isEmpty))
                Text('暂无机器态（基础模式）', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (_machineMode && (item.machineJson?.isNotEmpty ?? false))
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(jsonDecode(item.machineJson!)),
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          )
        else
          ItemViewRegistry.resolve(item.itemType)(context, item),
      ],
    );
  }
}

/// 通用文本/Markdown 专属区（note / chatlog / url / document 摘要）。
Widget _textView(BuildContext context, InboxItem item) {
  final body = item.bodyText;
  if (body.isEmpty) {
    return const _EmptyView();
  }
  return MarkdownBody(
    data: body,
    selectable: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
  );
}

/// 文档类型：显示落盘文件信息（结构化字段表单随 V2 machine_json 驱动）。
Widget _documentView(BuildContext context, InboxItem item) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.bodyText.isNotEmpty) ...[
        MarkdownBody(
          data: item.bodyText,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
        const SizedBox(height: 8),
      ],
      _FileTile(path: item.rawFilePath),
    ],
  );
}

/// 图片专属区：图片 + OCR 文本（OCR 文本 V2 管线产出）。
Widget _imageView(BuildContext context, InboxItem item) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.hasAttachment)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(item.rawFilePath!),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const _EmptyView(text: '图片文件已不存在'),
          ),
        ),
      if (item.bodyText.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(item.bodyText),
        ),
    ],
  );
}

/// 音视频专属区：MVP 显示文件信息（内嵌播放器为 V2 打磨项，可经「再分享」播放）。
Widget _mediaView(BuildContext context, InboxItem item) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (item.bodyText.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SelectableText(item.bodyText),
        ),
      _FileTile(path: item.rawFilePath),
    ],
  );
}

Widget _fallbackView(BuildContext context, InboxItem item) => _textView(context, item);

class _FileTile extends StatelessWidget {
  const _FileTile({this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    if (path == null || path!.isEmpty) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.attach_file),
      title: Text(path!.split('/').last, overflow: TextOverflow.ellipsis),
      subtitle: Text(path!, style: Theme.of(context).textTheme.bodySmall, maxLines: 1),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({this.text = '暂无内容'});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall);
}
