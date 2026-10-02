import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../ai/language_codes.dart';
import '../ai/subtitle.dart';
import '../data/repository.dart';
import '../models/item.dart';
import 'jsonrpc.dart';

/// MCP 工具集（PRD §7）：list/get/add/query_machine_data/get_timeline_context/
/// update/delete/set_vault/reprocess/unlock_edit/batch_items/append_segment/translate_item/
/// summarize_item/extract_tags/classify_item/analyze_text_item/scan_barcode_item/
/// transcribe_item/ocr_item 等；
/// 工作区：list_workspaces/create_workspace/rename_workspace/delete_workspace/
/// add_to_workspace/remove_from_workspace；execute_action 已裁决剔除。
/// 所有写/改动作经 ItemActionHandler（UI 与 MCP 同一套校验与实现）。
/// 隐私硬约束由 Repository 默认查询保证：Vault 与已删条目物理不可见；
/// 因此 MCP 对 Vault 条目仅可 set_vault(on=true) 移入，无法移出或读取。
///
/// 本层只做三件事，**不做任何业务判断**（防呆全在动作层）：
/// ① 把大模型输出的 JSON 反序列化成 [ItemCommand]（与 UI 组装的同一类对象）；
/// ② 以 [CommandActor.ai] 调用动作层；
/// ③ 把 [CommandResult]（含最新条目快照）序列化回 JSON，让大模型上下文与数据库对齐。
/// get_item 内联字幕内容的单文件上限：超出只报 size 不带 content（防长视频
/// 字幕把 MCP 响应撑爆；1 小时转写约 50KB，256KB 帽余量充足）。
const int _kSubtitleInlineMaxBytes = 256 * 1024;

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
        'description': '读取单个收集条目的完整内容（原文 + 人类态/机器态）；图片条目会返回 base64 图像内容块；'
            '已转写的音/视频条目会带 subtitles 字段（SRT/VTT 及译文文件内容内联，超 256KB 只报大小）。',
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
        'name': 'get_job_status',
        'description': '查询某条目最近的 AI 后台任务状态（pending/processing/completed/failed/paused/cancelled）。'
            'summarize_item、translate_item、reprocess_item 等耗时工具会立即返回并携带 job_id（任务已入队，产出稍后回写条目），'
            '可凭 job_id 或条目 id 调用本工具确认进度；产出完成后用 get_item 读取最新快照。'
            'Vault 与已删条目的任务不可见。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'job_id': {'type': 'string', 'description': '任务 id（工具返回的 job_id），与 id 二选一'},
            'id': {'type': 'string', 'description': '条目 uuid，返回该条目最近一次任务'},
          },
        },
      },
      {
        'name': 'list_jobs',
        'description': '列出最近的 AI 后台任务（按最新在前），含状态与失败原因。用于总览队列积压或排查哪条任务失败。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'default': 20, 'maximum': 50},
          },
        },
      },
      {
        'name': 'update_item',
        'description': '编辑条目（与手机 UI 编辑同一实现）。合并锁定的条目会拒绝写入，须先 unlock_edit；'
            'machine_json 必须通过领域 Schema 校验；item_type 仅允许截图条目 image→chatlog/document。'
            '返回修改后的完整条目快照——后续推理请以该快照为准，不要用你记忆里的旧值。',
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
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version。带上后，若期间条目已被用户或他人改动，'
                  '本次写入会被拒绝并报 version_conflict（而非静默覆盖）',
            },
          },
          'required': ['id', 'patch'],
        },
      },
      {
        'name': 'delete_item',
        'description': '删除条目（软删除，30 天内用户可恢复；关联 AI 任务一并取消）。'
            '返回条目删除后的快照；彻底删除（不可恢复）不支持，MCP 无此权限。',
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
        'description': '把条目移入保险箱（用户私密区，之后对 MCP 物理不可见，返回值不再含条目内容）。'
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
        'description': '重新触发某条目的双态重构（重置处理态并重新入队）。返回条目最新快照。',
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
        'description': '解除合并收集条目的编辑锁（edit_locked→0），随后 update_item 方可写入。'
            '返回条目最新快照（edit_locked=false）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid'},
          },
          'required': ['id'],
        },
      },
      {
        'name': 'batch_items',
        'description': '原子批量执行多条条目操作（复合操作专用）：全部成功才一次性提交，任一条失败则整体回滚，'
            '不会出现「字改了但标签没打上」的半成品。适合一次完成解锁编辑 + 改标题 + 打标签这类组合改动。'
            '每条命令形如 {"op":"update","id":"<uuid>","title":"..."}，'
            '可用 op：update / delete / set_vault / reclassify / reprocess / unlock_edit / collect / restore；'
            '不支持 delete_forever（不可逆）。返回每条命令的结果与最终条目快照。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'commands': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 20,
              'items': {'type': 'object'},
              'description': '命令数组，按数组顺序执行；每条可带可选的 expected_version 做乐观锁校验',
            },
          },
          'required': ['commands'],
        },
      },
      {
        'name': 'append_segment',
        'description': '往一条合并链（手机端连续速记自动并链产生的条目）末尾追加一段文本，'
            '等价于人在手机上连续速记时内容自动并进同一条。'
            '仅合并模式条目可追加，且末段须在合并窗口（5 分钟）内——超窗请改用 add_item 新建。'
            '合并条目即使 edit_locked=1 也允许追加（追加是链的生长，不是改写已有内容）。'
            '返回追加后的最新条目快照。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '合并链条目 uuid（list_items 返回）'},
            'text': {'type': 'string', 'description': '要追加的正文段，不能为空'},
            'source_app': {'type': 'string', 'description': '可选来源标识，记入该段的 appendix 记录'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝追加',
            },
          },
          'required': ['id', 'text'],
        },
      },
      {
        'name': 'translate_item',
        'description': '把条目的正文译成指定语言（端侧离线翻译，与手机端「翻译」按钮同一入口）。'
            '异步入队执行：本调用只返回入队结果，译文稍后落库，随后用 get_item 读取 translation 字段。'
            '目标语言受白名单约束；条目无正文（如未 OCR 的图片、未转写的音频）会被拒绝。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'target_lang': {
              'type': 'string',
              'enum': kTargetLanguages,
              'description': '目标语言（BCP-47）；省略则用 App 设置项里的目标语言',
            },
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'classify_item',
        'description': '用端侧 ML Kit 给图片打分类标签（与手机端「识别分类」按钮同一入口）。'
            '异步入队执行：本调用只返回入队结果，标签稍后落库到 facets，'
            '随后用 get_item 读取 facets 字段。仅图片条目可用，非图片会被拒绝。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'transcribe_item',
        'description': '对音频 / 视频条目执行端侧离线转写（Sherpa，与手机端「转写」按钮同一入口）。'
            '异步入队执行：本调用只返回入队结果（job_id），转写完成后文本并入 human_md，'
            '同时产出 SRT/VTT 字幕文件（随后 get_item 读取 human_md 与 subtitles 字段，'
            '或用 get_job_status 轮询进度）。仅音频 / 视频条目可用，非媒体条目会被拒绝；'
            '转写模型须已在手机上下载（设置 → 语音转写模型），未下载时任务会以 note 说明。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'ocr_item',
        'description': '对图片条目执行端侧 OCR 文字识别（ML Kit，与手机端「识别文字」按钮同一入口）。'
            '异步入队执行：本调用只返回入队结果（job_id），识别完成后文本并入 human_md，'
            '随后 get_item 读取 human_md 字段（或 get_job_status 轮询进度）。'
            '仅图片条目可用，非图片会被拒绝。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'scan_barcode_item',
        'description': '用端侧 ML Kit 扫描图片中的条码 / 二维码（与手机端「识别条码」按钮同一入口）。'
            '异步入队执行：本调用只返回入队结果，[类型:值] 稍后落库到 facets，'
            '随后用 get_item 读取 facets 字段。仅图片条目可用，非图片会被拒绝。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'analyze_text_item',
        'description': '用端侧离线 ML Kit 分析笔记正文（与手机端「分析文本」按钮同一入口）：'
            '同时做语言识别（写 facets[\'语言\']）与实体提取（日期 / 邮箱 / 电话 / 地址 / URL / 金额等，'
            '写 facets[\'实体\']，格式 [类型:值]）。异步入队执行：本调用只返回入队结果，'
            '随后用 get_item 读取 facets 字段。仅笔记条目可用，非笔记会被拒绝。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'summarize_item',
        'description': '用端侧大模型为条目正文生成摘要（与手机端「摘要」按钮同一入口）。'
            '异步入队执行：本调用只返回入队结果，摘要稍后落库，随后用 get_item 读取 summary 字段。'
            '条目无正文（如未 OCR 的图片、未转写的音频）会被拒绝。摘要与原文并列存储，不覆盖原文。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'extract_tags',
        'description': '用端侧大模型从条目正文提取关键词，并入条目既有标签（不覆盖已有标签）。'
            '与手机端「提取关键词」按钮同一入口。异步入队执行：本调用只返回入队结果，'
            '标签稍后落库，随后用 get_item 读取 tags 字段。条目无正文会被拒绝。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version',
            },
          },
          'required': ['id'],
        },
      },
      {
        'name': 'list_workspaces',
        'description': '列出用户所有工作区（条目集合容器，对应手机端「工作区」tab）。'
            '返回每个工作区的 id / name / createdAt。Vault 过滤对列表无影响（仅条目进工作区受 Vault 约束）。',
        'inputSchema': {'type': 'object', 'properties': {}},
      },
      {
        'name': 'create_workspace',
        'description': '新建一个工作区（与手机端「新建工作区」同一入口）。返回新建工作区的 id 与 name。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '工作区名称，不能为空'},
          },
          'required': ['name'],
        },
      },
      {
        'name': 'rename_workspace',
        'description': '重命名工作区（与手机端同一入口）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'workspace_id': {'type': 'string', 'description': '工作区 id（list_workspaces 返回）'},
            'name': {'type': 'string', 'description': '新名称，不能为空'},
          },
          'required': ['workspace_id', 'name'],
        },
      },
      {
        'name': 'delete_workspace',
        'description': '删除工作区（关系记录随外键级联清理，条目本身不受影响）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'workspace_id': {'type': 'string', 'description': '工作区 id（list_workspaces 返回）'},
          },
          'required': ['workspace_id'],
        },
      },
      {
        'name': 'add_to_workspace',
        'description': '把一条条目加入工作区（与手机端「加入工作区」同一入口）。'
            'Vault 条目对 AI 不可见，加入时会被拒绝。重复加入幂等。返回条目最新快照。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'workspace_id': {'type': 'string', 'description': '工作区 id（list_workspaces 返回）'},
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
            'expected_version': {
              'type': 'integer',
              'description': '可选乐观锁：你读取该条目时看到的 version，不一致则拒绝',
            },
          },
          'required': ['workspace_id', 'id'],
        },
      },
      {
        'name': 'remove_from_workspace',
        'description': '把一条条目移出工作区（与手机端同一入口）。',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'workspace_id': {'type': 'string', 'description': '工作区 id（list_workspaces 返回）'},
            'id': {'type': 'string', 'description': '条目 uuid（list_items 返回）'},
          },
          'required': ['workspace_id', 'id'],
        },
      },
    ];

int _clampInt(Object? v, int def, int min, int max) {
  if (v is int) return v.clamp(min, max);
  if (v is String) return int.tryParse(v)?.clamp(min, max) ?? def;
  return def;
}

String? _str(Object? v) => v is String ? v : null;

int? _int(Object? v) => switch (v) {
      int i => i,
      String s => int.tryParse(s),
      _ => null,
    };

/// 动作层拒绝（校验不过/不可见/越权）→ MCP 参数错误。
/// 原样透出 code + hint：大模型不只是「看到报错」，还能读懂原因并自我纠正
/// （如收到 edit_locked 会先调 unlock_edit 再重试）。
Future<T> _guarded<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on ActionException catch (e) {
    throw McpRpcError(errInvalidParams, e.message, {
      'code': e.code,
      if (e.hint != null) 'hint': e.hint,
    });
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
      // 与命令结果共用同一序列化口径：AI 上下文里只有一种 item 形状
      final itemJson = itemToJson(it);
      // 最近一次 AI 任务的原因（失败原因 / 「完成但无产出」说明）一并回传：
      // 同一份文字既给人看（任务队列页）也给 AI 读，避免 AI 只能猜「为什么没译文」
      final task = await repo.lastTaskOf(it.id ?? '');
      if (task != null) {
        itemJson['last_task'] = {
          'action': task['task_action'] ?? '',
          'status': task['status'] ?? '',
          if (task['last_note'] != null) 'note': task['last_note'],
        };
      }
      // 字幕产物内联（asr-subtitle.md §10 待定项，2026-10-02 拍板方案 1）：字幕是
      // 纯文件产物不进条目表，AI 经此字段拿到时间轴与译文文件内容，免二次取文件。
      // 文件极小（短音源每条目字节级）直接内联；超长音源超帽只报大小防响应膨胀。
      // DEGRADE: 字幕目录不可得（如无平台通道的测试环境）跳过字段——字幕是增强
      // 层，不得拖挂条目主读取路径；留日志可观测。
      try {
        final subs = <Map<String, Object?>>[];
        for (final f in await SubtitleStore.listFiles(it.id ?? '')) {
          final file = File(f.path);
          if (!await file.exists()) continue;
          final len = await file.length();
          subs.add({
            'ext': f.ext,
            if (f.lang != null) 'lang': f.lang,
            'size': len,
            if (len <= _kSubtitleInlineMaxBytes) 'content': await file.readAsString(),
          });
        }
        if (subs.isNotEmpty) itemJson['subtitles'] = subs;
      } catch (e) {
        debugPrint('[McpTools] subtitle list failed (ignored): $e');
      }
      final blocks = <Map<String, Object?>>[_text(jsonEncode(itemJson))];
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
      final r = await _guarded(() => handler.execute(
            CollectCommand(
              itemType: type,
              sourceApp: 'MCP (AI 写入)',
              rawContent: content.trim(),
              humanTitle: _str(args['title']),
              tags: tags,
            ),
            actor: CommandActor.ai,
          ));
      // add_item 不参与合并模式（F6 决策），永远独立成条
      return [_text(jsonEncode(r.toJson()))];

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

    case 'get_job_status': {
      final jobId = _str(args['job_id']);
      final itemId = _str(args['id']);
      if ((jobId == null || jobId.trim().isEmpty) && (itemId == null || itemId.trim().isEmpty)) {
        throw McpRpcError(errInvalidParams, '参数 job_id 与 id 至少提供一个');
      }
      Map<String, Object?>? task;
      if (jobId != null && jobId.trim().isNotEmpty) {
        task = await repo.taskById(jobId.trim());
        // job_id 查到的任务若其条目不可见（Vault/已删），不回传内容
        final owner = task?['item_id'] as String?;
        if (owner != null && await repo.byId(owner) == null) task = null;
      } else {
        // 按条目查最近任务：条目可见才回传（byId 默认排除 Vault 与已删）
        final it = await repo.byId(itemId!.trim());
        if (it == null) {
          return [_text(jsonEncode({'found': false, 'hint': '条目不存在或不可见（Vault/已删）；可先 list_jobs 查看最近任务'}))];
        }
        task = await repo.lastTaskOf(it.id ?? '');
      }
      if (task == null) {
        return [_text(jsonEncode({'found': false, 'hint': '任务不存在或条目不可见；可先 list_jobs 查看最近任务'}))];
      }
      return [_text(jsonEncode({
        'found': true,
        'job_id': task['task_id'],
        'item_id': task['item_id'],
        'action': task['task_action'] ?? '',
        'status': task['status'] ?? '',
        'updated_at': _iso(task['updated_at'] as int? ?? 0),
        if (task['last_note'] != null) 'note': task['last_note'],
      }))];
    }

    case 'list_jobs': {
      final limit = _clampInt(args['limit'], 20, 1, 50);
      final rows = await repo.listTasks(limit: limit);
      return [_text(jsonEncode({
        'count': rows.length,
        'jobs': [
          for (final t in rows)
            {
              'job_id': t['task_id'],
              'item_id': t['item_id'],
              'item_title': t['human_title'],
              'action': t['task_action'] ?? '',
              'status': t['status'] ?? '',
              'updated_at': _iso(t['updated_at'] as int? ?? 0),
              if (t['last_note'] != null) 'note': t['last_note'],
            },
        ],
      }))];
    }

    case 'update_item':
      final id = _str(args['id']);
      final patch = args['patch'];
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      if (patch is! Map) throw McpRpcError(errInvalidParams, '参数 patch 必须是对象');
      final p = patch.cast<String, Object?>();
      final machineRaw = p['machine_json'] == null
          ? null
          : (p['machine_json'] is String ? p['machine_json'] as String : jsonEncode(p['machine_json']));
      final r = await _guarded(() => handler.execute(
            UpdateItemCommand(
              id: id,
              title: _str(p['title']),
              tldr: _str(p['tldr']),
              tags: (p['tags'] as List?)?.whereType<String>().toList(),
              humanMd: _str(p['human_md']),
              machineJson: machineRaw,
              itemType: _str(p['item_type']),
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'delete_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(DeleteItemCommand(id), actor: CommandActor.ai));
      return [_text(jsonEncode(r.toJson()))];

    case 'set_vault':
      final id = _str(args['id']);
      final on = args['on'];
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      if (on is! bool) throw McpRpcError(errInvalidParams, '参数 on 必须是布尔值');
      // 移出校验不在本层：已下沉到动作层（AI 换个入口也绕不过）
      final r = await _guarded(() => handler.execute(SetVaultCommand(id, on), actor: CommandActor.ai));
      return [_text(jsonEncode(r.toJson()))];

    case 'reprocess_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(ReprocessCommand(id), actor: CommandActor.ai));
      return [_text(jsonEncode(r.toJson()))];

    case 'unlock_edit':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(UnlockEditCommand(id), actor: CommandActor.ai));
      return [_text(jsonEncode(r.toJson()))];

    case 'batch_items':
      final raw = args['commands'];
      if (raw is! List || raw.isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 commands 必须是非空数组');
      }
      if (raw.length > 20) throw McpRpcError(errInvalidParams, '一次最多 20 条命令');
      final cmds = await _guarded(() async => [
            for (final e in raw)
              if (e is Map)
                ItemCommand.fromJson(e.cast<String, Object?>())
              else
                throw ActionException('命令必须是对象', code: ActionErrorCode.invalidRequest),
          ]);
      final results = await _guarded(() => handler.executeAll(cmds, actor: CommandActor.ai));
      return [
        _text(jsonEncode({
          'ok': true,
          'count': results.length,
          'results': [for (final r in results) r.toJson()],
        })),
      ];

    case 'append_segment':
      final id = _str(args['id']);
      final text = _str(args['text']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      if (text == null || text.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 text 不能为空');
      final r = await _guarded(() => handler.execute(
            AppendSegmentCommand(
              id,
              text,
              sourceApp: _str(args['source_app']),
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'translate_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            TranslateCommand(
              id,
              targetLang: _str(args['target_lang']),
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'classify_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            ClassifyCommand(
              id,
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'transcribe_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            TranscribeCommand(
              id,
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'ocr_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            OcrCommand(
              id,
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'scan_barcode_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            ScanBarcodeCommand(
              id,
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'analyze_text_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            AnalyzeTextCommand(
              id,
              expectedVersion: _int(args['expected_version']),
            ),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'summarize_item':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            SummarizeCommand(id, expectedVersion: _int(args['expected_version'])),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'extract_tags':
      final id = _str(args['id']);
      if (id == null || id.trim().isEmpty) throw McpRpcError(errInvalidParams, '参数 id 不能为空');
      final r = await _guarded(() => handler.execute(
            ExtractTagsCommand(id, expectedVersion: _int(args['expected_version'])),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'list_workspaces':
      final ws = await repo.listWorkspaces();
      return [
        _text(jsonEncode({
          'count': ws.length,
          'workspaces': [
            for (final w in ws)
              {'id': w.id, 'name': w.name, 'createdAt': _iso(w.createdAt)},
          ],
        })),
      ];

    case 'create_workspace':
      final name = _str(args['name']);
      if (name == null || name.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 name 不能为空');
      }
      final r = await _guarded(() => handler.execute(
            CreateWorkspaceCommand(name.trim()),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'rename_workspace':
      final wsId = _str(args['workspace_id']);
      final name = _str(args['name']);
      if (wsId == null || wsId.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 workspace_id 不能为空');
      }
      if (name == null || name.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 name 不能为空');
      }
      final r = await _guarded(() => handler.execute(
            RenameWorkspaceCommand(wsId, name.trim()),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'delete_workspace':
      final wsId = _str(args['workspace_id']);
      if (wsId == null || wsId.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 workspace_id 不能为空');
      }
      final r = await _guarded(() => handler.execute(
            DeleteWorkspaceCommand(wsId),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'add_to_workspace':
      final wsId = _str(args['workspace_id']);
      final id = _str(args['id']);
      if (wsId == null || wsId.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 workspace_id 不能为空');
      }
      if (id == null || id.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 id（条目 uuid）不能为空');
      }
      final r = await _guarded(() => handler.execute(
            AddToWorkspaceCommand(wsId, id, expectedVersion: _int(args['expected_version'])),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

    case 'remove_from_workspace':
      final wsId = _str(args['workspace_id']);
      final id = _str(args['id']);
      if (wsId == null || wsId.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 workspace_id 不能为空');
      }
      if (id == null || id.trim().isEmpty) {
        throw McpRpcError(errInvalidParams, '参数 id（条目 uuid）不能为空');
      }
      final r = await _guarded(() => handler.execute(
            RemoveFromWorkspaceCommand(wsId, id),
            actor: CommandActor.ai,
          ));
      return [_text(jsonEncode(r.toJson()))];

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
