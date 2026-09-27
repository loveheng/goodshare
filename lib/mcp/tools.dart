import 'dart:convert';
import 'dart:io';

import '../data/repository.dart';
import '../models/item.dart';
import 'jsonrpc.dart';

/// MCP 工具集 v1：list_items / get_item / add_item。
/// 返回 MCP content 块列表（text / image）。
List<Map<String, Object?>> toolSchemas() => [
      {
        'name': 'list_items',
        'description':
            '列出或搜索「拾贝」收集器里的条目（用户日常分享收集的文本、链接、图片等）。'
                '支持关键词搜索（命中标题/正文/标签）与按类型过滤，按时间倒序分页。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '关键词，留空列出最近条目'},
            'type': {
              'type': 'string',
              'enum': ['TEXT', 'LINK', 'IMAGE', 'VIDEO', 'AUDIO', 'FILE'],
              'description': '按类型过滤，可省略',
            },
            'limit': {'type': 'integer', 'default': 20, 'maximum': 100},
            'offset': {'type': 'integer', 'default': 0},
          },
        },
      },
      {
        'name': 'get_item',
        'description': '读取单个收集条目的完整内容；图片条目会返回 base64 图像内容块。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'integer', 'description': '条目 id（list_items 返回）'},
          },
          'required': ['id'],
        },
      },
      {
        'name': 'add_item',
        'description': '把一段文本或链接存入「拾贝」收集器（例如用户说"帮我存一下"时使用）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'content': {'type': 'string', 'description': '正文或链接'},
            'title': {'type': 'string', 'description': '可选标题'},
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '可选标签',
            },
          },
          'required': ['content'],
        },
      },
    ];

int _clampInt(Object? v, int def, int min, int max) {
  if (v is int) return v.clamp(min, max);
  if (v is String) return int.tryParse(v)?.clamp(min, max) ?? def;
  return def;
}

Future<List<Map<String, Object?>>> callTool(
  String name,
  Map<String, Object?> args,
  Repository repo,
) async {
  switch (name) {
    case 'list_items':
      final query = args['query'] is String ? args['query'] as String : null;
      final type = args['type'] is String ? args['type'] as String : null;
      final limit = _clampInt(args['limit'], 20, 1, 100);
      final offset = _clampInt(args['offset'], 0, 0, 1 << 30);
      final items = await repo.list(query: query, type: type, limit: limit, offset: offset);
      final total = await repo.count(query: query, type: type);
      return [
        _text(jsonEncode({
          'total': total,
          'count': items.length,
          'offset': offset,
          'items': [
            for (final it in items)
              {
                'id': it.id,
                'type': it.type,
                'title': it.title,
                'preview': it.preview,
                'tags': it.tags,
                'source': it.sourceApp ?? it.sourcePackage,
                'createdAt': DateTime.fromMillisecondsSinceEpoch(it.createdAt).toIso8601String(),
                if (it.hasAttachment) 'attachments': it.files.length,
              },
          ],
        })),
      ];

    case 'get_item':
      final id = args['id'] is int ? args['id'] as int : int.tryParse('${args['id']}');
      if (id == null) throw McpRpcError(errInvalidParams, '参数 id 必须是整数');
      final it = await repo.byId(id);
      if (it == null) throw McpRpcError(errInvalidParams, '条目不存在: id=$id');
      final blocks = <Map<String, Object?>>[
        _text(jsonEncode({
          'id': it.id,
          'type': it.type,
          'title': it.title,
          'text': it.text,
          'tags': it.tags,
          'source': {'package': it.sourcePackage, 'app': it.sourceApp},
          'createdAt': DateTime.fromMillisecondsSinceEpoch(it.createdAt).toIso8601String(),
          'files': it.files,
        })),
      ];
      for (final f in it.files) {
        final file = File(f);
        if (!await file.exists()) continue;
        final mime = it.mime ?? _mimeOf(f);
        if (mime.startsWith('image/') && await file.length() <= 4 * 1024 * 1024) {
          final b64 = base64Encode(await file.readAsBytes());
          blocks.add({'type': 'image', 'data': b64, 'mimeType': mime});
        } else {
          blocks.add(_text('[附件] $f（$mime，未内联）'));
        }
      }
      return blocks;

    case 'add_item':
      final content = args['content'];
      if (content is! String || content.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 content 不能为空');
      }
      final tags = (args['tags'] as List?)?.whereType<String>().toList() ?? const [];
      final type = _detectType(content.trim());
      final id = await repo.add(CollectItem(
        type: type,
        title: args['title'] is String ? args['title'] as String : null,
        text: content.trim(),
        sourceApp: 'MCP (AI 写入)',
        tags: tags,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      return [_text('已收集：id=$id, type=$type')];

    default:
      throw McpRpcError(errInvalidParams, 'Unknown tool: $name');
  }
}

String _detectType(String content) =>
    RegExp(r'^https?://\S+$').hasMatch(content) ? CollectItem.typeLink : CollectItem.typeText;

String _mimeOf(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'mp4' => 'video/mp4',
    'mp3' => 'audio/mpeg',
    _ => 'application/octet-stream',
  };
}

Map<String, Object?> _text(String s) => {'type': 'text', 'text': s};
