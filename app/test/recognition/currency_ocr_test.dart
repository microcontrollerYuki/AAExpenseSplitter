import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/recognition/bill_ocr.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

void main() {
  group('OCR 精确金额与局部币种候选', () {
    test('六种明确代码和名称均可识别', () {
      for (final currency in Currency.values) {
        final numeric = currency == Currency.jpy ? '12' : '12.34';
        for (final marker in [currency.code, currency.displayName]) {
          expect(parseBillLines(['合计 $marker $numeric']).amounts, [
            OcrMoneyCandidate(amountText: numeric, currency: currency),
          ], reason: marker);
        }
      }
    });

    test('无歧义符号及前后缀仅关联相邻金额', () {
      expect(
        parseBillLines(['€12.34', '11.23 £', 'US\$10.12', '9.01 HK\$']).amounts,
        [
          const OcrMoneyCandidate(amountText: '12.34', currency: Currency.eur),
          const OcrMoneyCandidate(amountText: '11.23', currency: Currency.gbp),
          const OcrMoneyCandidate(amountText: '10.12', currency: Currency.usd),
          const OcrMoneyCandidate(amountText: '9.01', currency: Currency.hkd),
        ],
      );
    });

    test('裸数字及含糊符号不默认人民币', () {
      for (final line in [
        '12.34',
        '12',
        '¥12.34',
        '￥12.34',
        '\$12.34',
        '12.34元',
      ]) {
        final candidate = parseBillLines([line]).amounts.single;
        expect(candidate.amountText, line == '12' ? '12.00' : '12.34');
        expect(candidate.currency, isNull);
        expect(candidate.requiresCurrencyConfirmation, isTrue);
      }
    });

    test('微信和支付宝模板也不猜人民币', () {
      final wechat = parseBillLines(['支付成功', '财付通', '-6.33', '商户名称']);
      final alipay = parseBillLines(['账单详情', '￥6.33']);
      expect(wechat.source, 'wechat');
      expect(alipay.source, 'alipay');
      expect(wechat.amounts.single.currency, isNull);
      expect(alipay.amounts.single.currency, isNull);
    });

    test('局部代码加兼容符号保留明确币种，相邻裸金额不串用', () {
      expect(
        parseBillLines(['USD \$12.34', 'CNY¥11.23', 'JPY ￥10', '9.01']).amounts,
        [
          const OcrMoneyCandidate(amountText: '12.34', currency: Currency.usd),
          const OcrMoneyCandidate(amountText: '11.23', currency: Currency.cny),
          const OcrMoneyCandidate(amountText: '10', currency: Currency.jpy),
          const OcrMoneyCandidate(amountText: '9.01'),
        ],
      );
    });

    test('矛盾代码符号组合不强猜，后面的其他币种仍局部识别', () {
      expect(
        parseBillLines(['USD€12.34 / HKD \$11.23', 'CNY \$10.12']).amounts,
        [
          const OcrMoneyCandidate(amountText: '12.34'),
          const OcrMoneyCandidate(amountText: '11.23', currency: Currency.hkd),
          const OcrMoneyCandidate(amountText: '10.12'),
        ],
      );
    });

    test('同页币种不传播到其他金额或下一行', () {
      expect(parseBillLines(['USD 12.34', '11.23', 'EUR', '10.12']).amounts, [
        const OcrMoneyCandidate(amountText: '12.34', currency: Currency.usd),
        const OcrMoneyCandidate(amountText: '11.23'),
        const OcrMoneyCandidate(amountText: '10.12'),
      ]);
    });

    test('中文币种金额行不抢占商户与备注', () {
      final result = parseBillLines(['美元12.34', '咖啡店', '咖啡店']);
      expect(result.merchantGuess, '咖啡店');
      expect(result.noteSuggestion, '咖啡店');
    });

    test('同一行不同币种同数分别保留，重复同币种才去重', () {
      final candidates = parseBillLines([
        'USD10.00 / HKD10.00',
        '10.00 USD',
        '10.00',
        '￥10.00',
      ]).amounts;
      expect(candidates, hasLength(3));
      expect(candidates.toSet(), {
        const OcrMoneyCandidate(amountText: '10.00', currency: Currency.usd),
        const OcrMoneyCandidate(amountText: '10.00', currency: Currency.hkd),
        const OcrMoneyCandidate(amountText: '10.00'),
      });
    });

    test('超过 double 精确整数范围的尾分保持原值', () {
      expect(parseBillLines(['USD 90,071,992,547,409.93']).amounts, [
        const OcrMoneyCandidate(
          amountText: '90071992547409.93',
          currency: Currency.usd,
        ),
      ]);
    });

    test('JPY 保持整数，任何小数点包括零小数均拒绝且不回退', () {
      expect(
        parseBillLines(['JPY 1,234', '日元2.00', '3.0 JPY', 'JPY.5']).amounts,
        [const OcrMoneyCandidate(amountText: '1234', currency: Currency.jpy)],
      );
    });

    test('过精度及损坏分组不能截取前两位生成合法候选', () {
      expect(
        parseBillLines([
          'USD 12.345',
          '￥6.789',
          '5.000元',
          '4.321',
          'EUR 1,23.45',
          'GBP 1.23.45',
          'USD 1e3',
          'HKD 1.2e+3',
        ]).amounts,
        isEmpty,
      );
    });

    test('超范围及最小负 int64 的绝对值拒绝', () {
      expect(
        parseBillLines([
          'USD 92233720368547758.08',
          'USD -92233720368547758.08',
          'JPY 9223372036854775808',
          'JPY -9223372036854775808',
          '0.00',
          'JPY0',
        ]).amounts,
        isEmpty,
      );
    });

    test('全角负号表示扣款金额绝对值，精确正号与分组可规范化', () {
      expect(parseBillLines(['USD −1,234.50', '+2.1 EUR', '—6.33']).amounts, [
        const OcrMoneyCandidate(amountText: '1234.50', currency: Currency.usd),
        const OcrMoneyCandidate(amountText: '6.33'),
        const OcrMoneyCandidate(amountText: '2.10', currency: Currency.eur),
      ]);
    });

    test('日期订单电话数字不成为金额，仍保留其他识别字段', () {
      final result = parseBillLines([
        '支付时间 2026.10.11 20:30:01',
        '订单号 USD123456789',
        '流水号 1234.56',
        '电话 12345678',
        '付款方式 外币信用卡',
        '合计 USD12.34',
      ]);
      expect(result.amounts, [
        const OcrMoneyCandidate(amountText: '12.34', currency: Currency.usd),
      ]);
      expect(
        result.detectedDateMs,
        DateTime(2026, 10, 11, 20, 30, 1).millisecondsSinceEpoch,
      );
      expect(result.accountHintLine, '付款方式 外币信用卡');
    });

    test('币种代码嵌入单号和未知代码不生成错误候选', () {
      expect(
        parseBillLines(['ABCUSD12.34', '12.34USDXYZ', 'CAD12.34']).amounts,
        isEmpty,
      );
    });

    test('大小写代码、别名和小数简写保持精确文本', () {
      expect(parseBillLines(['rmb .5', '美金0.4', '港元 .3', '日币2']).amounts, [
        const OcrMoneyCandidate(amountText: '2', currency: Currency.jpy),
        const OcrMoneyCandidate(amountText: '0.50', currency: Currency.cny),
        const OcrMoneyCandidate(amountText: '0.40', currency: Currency.usd),
        const OcrMoneyCandidate(amountText: '0.30', currency: Currency.hkd),
      ]);
    });

    test('超长行整行跳过而非截断为合法金额', () {
      expect(parseBillLines(['USD ${'1' * 1500}.23', 'EUR 1.23']).amounts, [
        const OcrMoneyCandidate(amountText: '1.23', currency: Currency.eur),
      ]);
    });

    test('大量输入候选有界且不执行无限长数字解析', () {
      final result = parseBillLines([
        for (var i = 1; i < 300; i++) 'USD $i.01',
      ]);
      expect(result.amounts, hasLength(128));
      expect(result.amounts.first.amountText, '128.01');
    });
  });
}
