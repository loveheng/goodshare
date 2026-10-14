/// MCP prompts / resources 能力实现（ai-app-split.md §3.7/§3.8，M2.5 接缝扩展）。
/// prompts = CoW 模板源（官方预置，宿主拉取后本地沙盒覆写最高优先级）；
/// resources = 只读数据面（goodshare://items/{uuid}，与 tools 动词面正交）。
/// 可见性与工具面同口径：Vault 与已删条目物理不可见（Repository 默认查询保证）。
library;

import 'dart:convert';
import 'dart:io';

import '../data/repository.dart';
import '../models/template.dart';
import 'jsonrpc.dart';

/// 模板版本（CoW 告警基线，ai-app-split.md §3.7）：宿主比对 template_version
/// 大版本（major）跃迁强制告警——改模板正文语义时同步递增此版本号。
const kPromptTemplateVersion = '1.0.0';

/// 消费模板所需的宿主最低版本（CoW min_hub_version 兼容声明）——须与宿主
/// 当前实际版本对齐（M2.5 真机联调修正：误填 1.0.0 导致宿主 0.1.0 全被
/// skippedIncompatible 跳过）。模板引用的工具面在宿主 0.1.0 已全可用。
const kPromptMinHubVersion = '0.1.0';

/// resources URI 前缀：只读数据面单入口，非法前缀/嵌套路径一律 -32602。
const kResourceUriPrefix = 'goodshare://items/';

/// 内容生产模板资源前缀（ai-template）：goodshare://templates/{id} → 派生 skill 文件。
const kTemplateUriPrefix = 'goodshare://templates/';

/// mcp-blob URI 前缀：get_item 大附件/大图经此 URI 暴露，宿主再 resources/read
/// 取字节（Binder 1MB 事务上限对策，#3；严禁 $ref://——其语义/可达性不可控）。
const kBlobUriPrefix = 'mcp-blob://com.zzh.goodshare/';

/// resources/read 文本阈值帽（Binder 1MB 事务上限对策，#3）：超阈值截断并提示走 get_item。
const _kResourceTextMaxBytes = 512 * 1024;

/// 官方预置模板（ai-app-split.md §3.7：prompts 只描述意图编排，不新增工具；
/// 正文引用既有工具面，宿主模型按其执行）。{arg} 占位符经 prompts/get 字面替换。
const List<Map<String, Object?>> _kPrompts = [
  {
    'name': 'item_digest',
    'description': '把一条收集条目整理成结构化摘要：要点、行动项、值得追问的问题。',
    'arguments': [
      {
        'name': 'id',
        'description': '条目 uuid（list_items 或 resources/list 返回）',
        'required': true,
      },
    ],
    'template': '请先用 get_item 读取条目 {id} 的完整内容，然后整理一份结构化摘要：'
        '① 3~5 条要点；② 需要跟进的行动项（没有就写「无」）；③ 值得向用户追问的问题。',
  },
  {
    'name': 'weekly_review',
    'description': '对最近若干天的收集条目做一次回顾：高频主题、值得深读的条目、收集习惯观察。',
    'arguments': [
      {
        'name': 'days',
        'description': '回看天数（如 7），按创建时间筛选',
        'required': true,
      },
    ],
    'template': '请用 list_items 拉取最近 {days} 天的条目（可分页），做一次回顾：'
        '① 高频主题归类；② 最值得深读的 3 条（给出条目 id 与理由）；'
        '③ 对用户收集习惯的一句观察。',
  },
  {
    'name': 'suggest_tags',
    'description': '在现有标签基础上为一条条目建议补充标签（查重，不与现有重复）。',
    'arguments': [
      {
        'name': 'id',
        'description': '条目 uuid',
        'required': true,
      },
    ],
    'template': '请先用 get_item 读取条目 {id}（注意其 tags 字段是现有标签），'
        '然后建议 3~5 个补充标签：与现有标签去重、贴合内容、用中文短语；'
        '最后列出「现有标签 → 建议新增」的对照清单。',
  },
];

/// prompts/list（§3.7）：官方模板清单 + CoW 版本元数据。
List<Map<String, Object?>> listPrompts() => [
      for (final t in _kPrompts)
        {
          'name': t['name'],
          'description': t['description'],
          'arguments': t['arguments'],
          '_meta': {
            'template_version': kPromptTemplateVersion,
            'min_hub_version': kPromptMinHubVersion,
          },
        },
    ];

/// prompts/get（§3.7）：占位符字面替换（单次遍历不递归——参数值含 {x} 不再展开）；
/// **arguments 字段整体缺省（renderArgs=false）→ 返回未渲染原文**（占位符保留
/// ——CoW 同步拉取模板原文的通道，M2.5-T6）；显式传参但 required 缺失或
/// 未知模板 → -32602。
Map<String, Object?> getPrompt(
  String name,
  Map<String, Object?> args, {
  bool renderArgs = true,
}) {
  Map<String, Object?>? t;
  for (final p in _kPrompts) {
    if (p['name'] == name) {
      t = p;
      break;
    }
  }
  if (t == null) throw McpRpcError(errInvalidParams, '未知模板: $name');
  final decls = (t['arguments'] as List).cast<Map<String, Object?>>();
  var text = t['template'] as String;
  if (renderArgs) {
    for (final d in decls) {
      final argName = d['name'] as String;
      final value = args[argName];
      if (value is String && value.isNotEmpty) {
        text = text.replaceAll('{$argName}', value);
      } else if (d['required'] == true) {
        throw McpRpcError(errInvalidParams, '缺少必填参数: $argName');
      } else {
        text = text.replaceAll('{$argName}', '');
      }
    }
  }
  return {
    'description': t['description'],
    'messages': [
      {
        'role': 'user',
        'content': {'type': 'text', 'text': text},
      },
    ],
  };
}

/// resources/list（§3.8）：最近 200 条，首版无 cursor 分页；
/// name 取标题，空标题回退 preview 截断。
Future<List<Map<String, Object?>>> listResources(Repository repo) async {
  final items = await repo.list(limit: 200, aiVisible: true);
  final templates = await repo.listTemplates();
  return [
    for (final it in items)
      {
        'uri': '$kResourceUriPrefix${it.id}',
        'name': (it.humanTitle?.isNotEmpty ?? false)
            ? it.humanTitle!
            : it.preview,
        'mimeType': 'text/plain',
      },
    // 内容生产模板（ai-template）：AI 经 goodshare://templates/{id} 读 skill 文件
    for (final t in templates)
      {
        'uri': '$kTemplateUriPrefix${t.id}',
        'name': t.name,
        'mimeType': 'text/markdown',
      },
  ];
}

/// resources/read（§3.8）：text = 条目正文（human_md ?? raw_content，与
/// claim text 同基线）；非法 URI 或条目不可见 → -32602（Vault 物理不可见）。
/// 另支持 mcp-blob:// URI（#3：get_item 大附件/大图暴露的字节入口）。
Future<List<Map<String, Object?>>> readResource(
  Repository repo,
  String uri,
) async {
  if (uri.startsWith(kBlobUriPrefix)) {
    return _readBlob(uri);
  }
  if (uri.startsWith(kTemplateUriPrefix)) {
    return _readTemplate(repo, uri);
  }
  if (!uri.startsWith(kResourceUriPrefix)) {
    throw McpRpcError(errInvalidParams, '不支持的资源 URI: $uri');
  }
  final id = uri.substring(kResourceUriPrefix.length);
  if (id.isEmpty || id.contains('/') || id.contains('?')) {
    throw McpRpcError(errInvalidParams, '非法资源 URI: $uri');
  }
  final it = await repo.byId(id, aiVisible: true);
  if (it == null) throw McpRpcError(errInvalidParams, '资源不存在或不可见: $uri');
  final body = it.bodyText;
  final bytes = utf8.encode(body);
  if (bytes.length > _kResourceTextMaxBytes) {
    // Binder 1MB 事务上限对策：超阈值截断，避免事务撑爆；全文走 get_item。
    final truncated = _truncateUtf8(body, _kResourceTextMaxBytes);
    return [
      {
        'uri': uri,
        'mimeType': 'text/plain',
        'text': '$truncated\n…(已截断，全文请用 get_item 读取)',
      },
    ];
  }
  return [
    {'uri': uri, 'mimeType': 'text/plain', 'text': body},
  ];
}

/// mcp-blob://com.zzh.goodshare/[encodedPath] → 读文件字节，以 blob(base64) 返回。
/// 路径经 [Uri.encodeComponent] 编码后放入 URI，此处解码还原（#3）。
Future<List<Map<String, Object?>>> _readBlob(String uri) async {
  final encoded = uri.substring(kBlobUriPrefix.length);
  final path = Uri.decodeComponent(encoded);
  final file = File(path);
  if (!await file.exists()) {
    throw McpRpcError(errInvalidParams, 'blob 不存在: $uri');
  }
  final mime = _blobMimeOf(path);
  final bytes = await file.readAsBytes();
  return [
    {'uri': uri, 'mimeType': mime, 'blob': base64Encode(bytes)},
  ];
}

/// 按 UTF-8 字节安全截断（不切断多字节字符），用于 resources/read 文本阈值帽。
String _truncateUtf8(String s, int maxBytes) {
  var end = s.length;
  while (end > 0 && utf8.encode(s.substring(0, end)).length > maxBytes) {
    end--;
  }
  return s.substring(0, end);
}

/// blob 路径 MIME 推断（与 tools.dart _mimeOf 同源，避免反向 import 成环）。
String _blobMimeOf(String path) {
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

/// goodshare://templates/{id} → 派生 skill 文件（ai-template）：AI 侧只读视图。
/// 非法 URI / 模板不存在 → -32602。
Future<List<Map<String, Object?>>> _readTemplate(
  Repository repo,
  String uri,
) async {
  final id = uri.substring(kTemplateUriPrefix.length);
  if (id.isEmpty || id.contains('/') || id.contains('?')) {
    throw McpRpcError(errInvalidParams, '非法模板资源 URI: $uri');
  }
  final t = await repo.byIdTemplate(id);
  if (t == null) throw McpRpcError(errInvalidParams, '模板不存在: $uri');
  return [
    {'uri': uri, 'mimeType': 'text/markdown', 'text': templateSkillMd(t)},
  ];
}

/// 模板 → AI skill 文件（派生只读）：单一源 [Template.bodyMd] + 元数据组装成
/// skill 文档，AI 经 resources/read 获取；人类预览页直接渲染 body_md（另一视图）。
/// 双视图同源、零漂移——AI 改模板经 MCP 写 body_md，skill 文件随之重新派生。
String templateSkillMd(Template t) {
  final buf = StringBuffer();
  buf.writeln('---');
  buf.writeln('name: ${t.name}');
  if (t.description != null && t.description!.trim().isNotEmpty) {
    buf.writeln('description: ${t.description}');
  }
  buf.writeln('template_version: ${t.version}');
  buf.writeln('origin: ${t.origin}');
  buf.writeln('workspace: ${t.workspaceId}');
  buf.writeln('---');
  buf.writeln();
  buf.writeln('# ${t.name}');
  buf.writeln();
  buf.writeln('按以下结构骨架帮用户整理内容；将 {{占位符}} 替换为实际值。');
  buf.writeln();
  buf.writeln(t.bodyMd);
  return buf.toString();
}
