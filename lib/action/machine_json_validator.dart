import 'dart:convert';

/// machine_json 领域 Schema 强校验（PRD §7：update_item 的 machine_json
/// 落库前须通过对应领域 Schema 校验，失败整单拒写——2026-09-27 D4 决策）。
/// V2 截图解析扩展新 Schema 时在此登记（与 V2 需求 §4 的 Schema 表同步维护）。
const machineJsonSchemas = <String, Set<String>>{
  'invoice.v1': {'amount', 'date', 'merchant'}, // V2 §4：amount/date/merchant/tax/items
  'contact.v1': {'name', 'phone'}, // V2 §4：name/phone/org/title
  'event.v1': {'when'}, // V2 §4：when/where/attendees/action_items
  'health_record.v1': {'date', 'metrics'}, // V3 §4 健康接入复用
};

/// 校验 machine_json 原文。返回 null 表示通过，否则返回可展示的拒绝原因。
String? validateMachineJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return 'machine_json 不能为空';
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    return 'machine_json 不是合法 JSON：${e.message}';
  }
  if (decoded is! Map<String, Object?> && decoded is! Map) {
    return 'machine_json 顶层必须是对象';
  }
  final map = (decoded as Map).cast<String, Object?>();
  final schema = map['schema'];
  if (schema is! String || !machineJsonSchemas.containsKey(schema)) {
    return '未知或缺失 schema 字段（已知：${machineJsonSchemas.keys.join(', ')}）';
  }
  final missing = machineJsonSchemas[schema]!.where((f) => map[f] == null).toList();
  if (missing.isNotEmpty) {
    return '$schema 缺少必填字段：${missing.join(', ')}';
  }
  return null;
}
