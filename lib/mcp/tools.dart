import 'dart:convert';
import 'dart:io';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../models/item.dart';
import 'jsonrpc.dart';

/// MCP 工具集（PRD §7）：list/get/add/query_machine_data/get_timeline_context/
/// update/delete/set_vault/reprocess/unlock_edit，共 10 个；execute_action 已裁决剔除。
/// 所有写/改动作经 ItemActionHandler（UI 与 MCP 同一套校验与实现）。
/// 隐私硬约束由 Repository 默认查询保证：Vault 与已删条目物理不可见；
/// 因此 MCP 对 Vault 条目仅可 set_vault(on=true) 移入，无法移出或读取。
List<Map<String, Object?>> toolSchemas() => [
      {
        'name': 'list_items',
        'description':
            '列出或搜索「拾贝」收集器里的条目（用户日常分享收集的文本、链接、图片等）。'
                '支持关键词搜索（命中标题/正文/标签）与按类型过滤，按时间倒序分页。'
                'Vault 私密条目与已删条目永远不可见。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '关键词，留空列出最近条目'},
            'type': {
              'type': 'string',
              'enum': InboxItem.allTypes,
              'description': '按 item_type 过滤，可省略',
            },
            'limit': {'type': 'integer', 'default': 20, 'maximum': 100},
            'offset': {'type': 'integer', 'default': 0},
          },
        },
      },
      {
        'name': 'get_item',
        'description': '读取单个收集条目的完整内容（原文 + 人类态/机器态）；图片条目会返回 base64 图像内容块。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
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
      {
        'name': 'query_machine_data',
        'description': '按需检索条目的机器态（machine_json 结构化数组，强类型无噪音，消除幻觉与 token 浪费）。'
            '仅返回已有机器态的条目；Vault 与已删条目不可见。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '关键词，可省略'},
            'type': {
              'type': 'string',
              'enum': InboxItem.allTypes,
              'description': '按 item_type 过滤，可省略',
            },
            'limit': {'type': 'integer', 'default': 20, 'maximum': 100},
            'offset': {'type': 'integer', 'default': 0},
          },
        },
      },
      {
        'name': 'get_timeline_context',
        'description': '获取某天的多维上下文（健康/事件/当日收集条目）。健康与日历事件随 V3 健康接入填充，当前为空。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'date': {'type': 'string', 'description': '日期，YYYY-MM-DD（本机时区）'},
          },
          'required': ['date'],
        },
      },
      {
        'name': 'update_item',
        'description': '编辑条目（与手机 UI 编辑同一实现）。合并锁定的条目会拒绝写入，须先 unlock_edit；'
            'machine_json 必须通过领域 Schema 校验；item_type 仅允许截图条目 image→chatlog/document。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid'},
            'patch': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
                'tldr': {'type': 'string'},
                'tags': {'type': 'array', 'items': {'type': 'string'}},
                'human_md': {'type': 'string'},
                'machine_json': {
                  'description': '机器态对象，须带 schema 字段并通过领域 Schema 校验（如 invoice.v1）',
                },
                'item_type': {'type': 'string', 'enum': [InboxItem.typeChatlog, InboxItem.typeDocument]},
              },
            },
          },
          'required': ['id', 'patch'],
        },
      },
      {
        'name': 'delete_item',
        'description': '删除条目（软删除，30 天内用户可恢复；关联 AI 任务一并取消）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid'},
          },
          'required': ['id'],
        },
      },
      {
        'name': 'set_vault',
        'description': '把条目移入保险箱（用户私密区，之后对 MCP 物理不可见）。'
            '注意：MCP 只能移入；移出须用户在手机上生物识别后操作。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid'},
            'on': {'type': 'boolean', 'description': 'true 移入保险箱；false 仅限 UI 操作'},
          },
          'required': ['id', 'on'],
        },
      },
      {
        'name': 'reprocess_item',
        'description': '重新触发某条目的双态重构（重置处理态并重新入队）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid'},
          },
          'required': ['id'],
        },
      },
      {
        'name': 'unlock_edit',
        'description': '解除合并收集条目的编辑锁（edit_locked→0），随后 update_item 方可写入。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid'},
          },
          'required': ['id'],
        },
      },
    ];

int _clampInt(Object? v, int def, int min, int max) {
  if (v is int) return v.clamp(min, max);
  if (v is String) return int.tryParse(v)?.clamp(min, max) ?? def;
  return def;
}

String? _str(Object? v) => v is String ? v : null;

/// 动作层拒绝（校验不过/不可见）→ MCP 参数错误。
Future<Object?> _guarded(Future<Object?> Function() run) async {
  try {
    return await run();
  } on ActionException catch (e) {
    throw McpRpcError(errInvalidParams, e.message);
  }
}

String _iso(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

Future<List<Map<String, Object?>>> callTool(
  String name,
  Map<String, Object?> args,
  Repository repo,
) async {
  final handler = ItemActionHandler(repo);
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
                'type': it.itemType,
                'title': it.humanTitle,
                'preview': it.preview,
                'tags': it.tags,
                'source': it.sourceApp,
                'createdAt': _iso(it.createdAt),
                if (it.hasAttachment) 'attachments': 1,
              },
          ],
        })),
      ];

    case 'get_item':
      final id = args['id'] is String ? args['id'] as String : '${args['id']}';
      if (id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final it = await repo.byId(id); // 默认排除 Vault 与已删条目
      if (it == null) throw McpRpcError(errInvalidParams, '条目不存在: id=$id');
      final blocks = <Map<String, Object?>>[
        _text(jsonEncode({
          'id': it.id,
          'type': it.itemType,
          'title': it.humanTitle,
          'tldr': it.humanTldr,
          'text': it.bodyText,
          'machine_json': it.machineJson == null ? null : jsonDecode(it.machineJson!),
          'tags': it.tags,
          'source': {'app': it.sourceApp, 'type': it.sourceType},
          'createdAt': _iso(it.createdAt),
          'file': it.rawFilePath,
        })),
      ];
      final f = it.rawFilePath;
      if (f != null && f.isNotEmpty) {
        final file = File(f);
        if (await file.exists()) {
          final mime = _mimeOf(f);
          if (mime.startsWith('image/') && await file.length() <= 4 * 1024 * 1024) {
            final b64 = base64Encode(await file.readAsBytes());
            blocks.add({'type': 'image', 'data': b64, 'mimeType': mime});
          } else {
            blocks.add(_text('[附件] $f（$mime，未内联）'));
          }
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
      final saved = await repo.add(InboxItem(
        itemType: type,
        sourceType: type,
        humanTitle: _str(args['title']),
        rawContent: content.trim(),
        sourceApp: 'MCP (AI 写入)',
        tags: tags,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      // 入库即入队（PRD 模块二）；add_item 不参与合并模式（F6 决策），永远独立成条
      await repo.enqueueTask(saved.id!, Repository.taskActionFor(type));
      return [_text('已收集：id=${saved.id}, type=$type')];

    case 'query_machine_data':
      final query = args['query'] is String ? args['query'] as String : null;
      final type = args['type'] is String ? args['type'] as String : null;
      final limit = _clampInt(args['limit'], 20, 1, 100);
      final offset = _clampInt(args['offset'], 0, 0, 1 << 30);
      final all = await repo.list(query: query, type: type, limit: limit, offset: offset);
      final withMachine = [
        for (final it in all)
          if (it.machineJson != null && it.machineJson!.isNotEmpty) it,
      ];
      return [
        _text(jsonEncode({
          'total': withMachine.length,
          'items': [
            for (final it in withMachine)
              {
                'id': it.id,
                'type': it.itemType,
                'machine_json': jsonDecode(it.machineJson!),
                'createdAt': _iso(it.createdAt),
              },
          ],
        })),
      ];

    case 'get_timeline_context':
      final date = args['date'];
      if (date is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
        throw McpRpcError(errInvalidParams, '参数 date 必须是 YYYY-MM-DD');
      }
      final items = await repo.listByDate(date);
      return [
        _text(jsonEncode({
          'date': date,
          // 健康/日历随 V3 健康接入填充（F1：MVP/V2 恒空）
          'health': null,
          'events': <Object>[],
          'ingested_items': [
            for (final it in items)
              {
                'id': it.id,
                'type': it.itemType,
                'title': it.humanTitle,
                'preview': it.preview,
                'createdAt': _iso(it.createdAt),
              },
          ],
        })),
      ];

    case 'update_item':
      final id = _str(args['id']);
      final patch = args['patch'];
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      if (patch is! Map) throw McpRpcError(errInvalidParams, '参数 patch 必须是对象');
      final p = patch.cast<String, Object?>();
      final machineRaw = p['machine_json'] == null
          ? null
          : (p['machine_json'] is String ? p['machine_json'] as String : jsonEncode(p['machine_json']));
      await _guarded(() => handler.edit(
            id,
            title: _str(p['title']),
            tldr: _str(p['tldr']),
            tags: (p['tags'] as List?)?.whereType<String>().toList(),
            humanMd: _str(p['human_md']),
            machineJson: machineRaw,
            itemType: _str(p['item_type']),
          ));
      return [_text('已更新：id=$id')];

    case 'delete_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      await _guarded(() => handler.delete(id));
      return [_text('已删除（30 天内可恢复）：id=$id')];

    case 'set_vault':
      final id = _str(args['id']);
      final on = args['on'];
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      if (on is! bool) throw McpRpcError(errInvalidParams, '参数 on 必须是布尔值');
      if (!on) {
        throw McpRpcError(errInvalidParams, 'MCP 仅可移入保险箱；移出须用户在手机上操作');
      }
      await _guarded(() => handler.setVault(id, true));
      return [_text('已移入保险箱：id=$id（之后对 MCP 不可见）')];

    case 'reprocess_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      await _guarded(() => handler.reprocess(id));
      return [_text('已重新入队：id=$id')];

    case 'unlock_edit':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      await _guarded(() => handler.unlockEdit(id));
      return [_text('已解除编辑锁定：id=$id')];

    default:
      throw McpRpcError(errInvalidParams, 'Unknown tool: $name');
  }
}

String _detectType(String content) =>
    RegExp(r'^https?://\S+$').hasMatch(content) ? InboxItem.typeUrl : InboxItem.typeNote;

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
