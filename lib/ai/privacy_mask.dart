/// 隐私打码规则层（V2 R2，2026-10-09 D1 拍板：挂动作层 `_applyAiResult` 通用出口，
/// 覆盖所有 AI 写路径——含占位回退；`raw_content` 保留明文）。
///
/// 纯函数无 Flutter 依赖：身份证（18 位 regex + GB 11643 校验位）与银行卡
/// （13–19 位 + Luhn）默认 `****` 打码；设置页既有占位开关「身份证 / 银行卡
/// 默认打码」本期接线（v2-requirements §4）。
library;

/// 打码一段 AI 产出文本（human_md / machine_json 序列化串共用）。
String maskSensitiveText(String input, {bool enabled = true}) {
  if (!enabled || input.isEmpty) return input;
  var out = maskIdCards(input);
  out = maskBankCards(out);
  return out;
}

/// 18 位身份证号：regex 粗筛 + GB 11643 校验位验证（防把普通 18 位数字误伤）。
String maskIdCards(String input) {
  return input.replaceAllMapped(_idCardRe, (m) {
    final id = m.group(0)!;
    return _validIdCard(id) ? '${id.substring(0, 4)}**********${id.substring(14)}' : id;
  });
}

final RegExp _idCardRe = RegExp(r'\b[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]\b');

const List<int> _idWeights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const List<String> _idCheckCodes = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

bool _validIdCard(String id) {
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    sum += int.parse(id[i]) * _idWeights[i];
  }
  return _idCheckCodes[sum % 11] == id[17].toUpperCase();
}

/// 银行卡号：13–19 位数字 + Luhn 校验。前后文是数字/字母时不打（防切进长数字串）。
String maskBankCards(String input) {
  return input.replaceAllMapped(_bankCardRe, (m) {
    final no = m.group(0)!;
    // 边界守卫：前后紧邻字母/数字说明是更长 token（订单号/编号），不动。
    final start = m.start, end = m.end;
    if (start > 0 && _isAlnum(input[start - 1])) return no;
    if (end < input.length && _isAlnum(input[end])) return no;
    return _luhn(no) ? '${no.substring(0, 4)}****${no.substring(no.length - 4)}' : no;
  });
}

final RegExp _bankCardRe = RegExp(r'\d{13,19}');
final RegExp _alnum = RegExp(r'[0-9A-Za-z]');

bool _isAlnum(String ch) => ch.isNotEmpty && _alnum.hasMatch(ch);

bool _luhn(String s) {
  var sum = 0;
  var alt = false;
  for (var i = s.length - 1; i >= 0; i--) {
    var d = int.parse(s[i]);
    if (alt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alt = !alt;
  }
  return sum % 10 == 0;
}
