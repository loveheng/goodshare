import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ai/privacy_mask.dart';

void main() {
  group('maskIdCards（18 位身份证 + GB 11643 校验位）', () {
    test('合法身份证打码（保留前 4 后 4）', () {
      // 11010519491231002X 为 GB 11643 标准示例号（校验位 X）
      const id = '11010519491231002X';
      final out = maskIdCards('身份证：$id');
      expect(out, contains('1101**********002X'));
      expect(out, isNot(contains(id)));
    });

    test('校验位不符的 18 位数字不动（防误伤编号）', () {
      const fake = '110105194912310021'; // 末位 1 不合校验
      final out = maskIdCards('编号：$fake');
      expect(out, contains(fake));
    });

    test('普通 18 位长数字（订单号类）不动', () {
      const no = '202610091234567890'; // 出生段 9112 非法月份
      expect(maskIdCards(no), no);
    });
  });

  group('maskBankCards（13-19 位 + Luhn）', () {
    test('合法银行卡打码（保留前 4 后 4）', () {
      // 4111111111111111 为 Luhn 校验通过的测试卡号
      const card = '4111111111111111';
      final out = maskBankCards('卡号 $card 请查收');
      expect(out, contains('4111****1111'));
      expect(out, isNot(contains(card)));
    });

    test('Luhn 不通过的数字串不动', () {
      const no = '4111111111111112';
      expect(maskBankCards('单号 $no'), contains(no));
    });

    test('紧邻字母/数字的长 token 不动（订单号守卫）', () {
      const no = '4111111111111111';
      expect(maskBankCards('ORD$no'), 'ORD$no'.replaceAll(no, no)); // 前邻字母 R
      expect(maskBankCards('${no}X'), '${no}X');
    });

    test('混合场景：同一文本两类号码都打', () {
      const text = '身份证 11010519491231002X 卡 4111111111111111';
      final out = maskSensitiveText(text);
      expect(out, contains('1101**********002X'));
      expect(out, contains('4111****1111'));
    });
  });

  group('maskSensitiveText 开关', () {
    test('enabled=false 原样返回', () {
      const text = '卡号 4111111111111111';
      expect(maskSensitiveText(text, enabled: false), text);
    });

    test('空串安全', () {
      expect(maskSensitiveText(''), '');
    });
  });
}
