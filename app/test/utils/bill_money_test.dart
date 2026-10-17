import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/bill_money.dart';

import '../helpers/test_support.dart';

void main() {
  test('人民币美元保留两位小数，日元整数且已知代码可规范化显示', () {
    expect(displayCurrencyAmount(BigInt.from(529), 'CNY'), '¥ 5.29');
    expect(displayCurrencyAmount(BigInt.from(1000), 'USD'), 'USD 10.00');
    expect(displayCurrencyAmount(BigInt.from(1531), 'JPY'), 'JPY 1,531');
    expect(displayCurrencyAmount(BigInt.one, ' usd '), 'USD 0.01');
    expect(
      displayCurrencyAmount(BigInt.from(1531), 'jpy', prefix: false),
      '1,531',
    );
  });

  test('带币种金额正负符号统一且零不加正号，未知币种保持原最小单位', () {
    expect(
      displayCurrencyAmount(BigInt.from(1000), 'USD', signed: true),
      '+USD 10.00',
    );
    expect(
      displayCurrencyAmount(BigInt.from(-1000), 'USD', signed: true),
      '-USD 10.00',
    );
    expect(displayCurrencyAmount(BigInt.zero, 'CNY', signed: true), '¥ 0.00');
    expect(
      displayCurrencyAmount(BigInt.from(-529), 'CNY', prefix: false),
      '-5.29',
    );
    expect(
      displayCurrencyAmount(BigInt.from(1531), 'XTS', signed: true),
      'XTS +1531 最小单位',
    );
    expect(
      displayCurrencyAmount(BigInt.from(-1531), 'XTS', prefix: false),
      'XTS -1531 最小单位',
    );
    expect(displayCurrencyAmount(BigInt.zero, ''), '未知币种 0 最小单位');
  });

  test('int64正负边界及超限BigInt格式化不经浮点且保留尾分', () {
    final maximum = BigInt.parse('9223372036854775807');
    final minimum = BigInt.parse('-9223372036854775808');
    expect(
      displayCurrencyAmount(maximum, 'CNY'),
      '¥ 92,233,720,368,547,758.07',
    );
    expect(
      displayCurrencyAmount(minimum, 'USD'),
      '-USD 92,233,720,368,547,758.08',
    );
    expect(
      displayCurrencyAmount(maximum + BigInt.one, 'CNY'),
      '¥ 92,233,720,368,547,758.08',
    );
    expect(
      displayCurrencyAmount(maximum + BigInt.one, 'JPY'),
      'JPY 9,223,372,036,854,775,808',
    );
    expect(
      displayCurrencyAmount(minimum - BigInt.one, 'XTS'),
      'XTS -9223372036854775809 最小单位',
    );
  });

  test('账单按类型显示正负，外币总带代码且交易原币不被实扣覆盖', () {
    final expense = mkBill('expense', amount: 529);
    expect(displayBillAmount(expense), '-5.29');
    expect(displayBillAmount(expense, prefix: true), '-¥ 5.29');
    expect(
      displayBillAmount(
        mkBill('cross', currency: 'USD', amount: 1000, accountAmount: 7200),
      ),
      '-USD 10.00',
    );
    expect(
      displayBillAmount(
        mkBill('income', type: 1, currency: 'JPY', amount: 1531),
      ),
      '+JPY 1,531',
    );
    expect(
      displayBillAmount(
        mkBill(
          'transfer',
          type: 2,
          currency: 'USD',
          amount: 1000,
          toAccountAmount: 1531,
        ),
      ),
      'USD 10.00',
    );
    expect(
      displayBillAmount(
        mkBill('adjustment', type: 3, amount: -529),
        prefix: true,
      ),
      '-¥ 5.29',
    );
    expect(displayBillAmount(mkBill('zero', type: 1, amount: 0)), '0.00');
    expect(
      displayBillAmount(mkBill('unknown', currency: 'XTS', amount: 1531)),
      'XTS -1531 最小单位',
    );
  });

  test('收入支出分别按交易币种汇总，跨币实扣与实收不改变原币统计', () {
    final bills = [
      mkBill('cny-expense', amount: 529),
      mkBill('cny-income', type: 1, amount: 230),
      mkBill(
        'usd-cross-expense',
        currency: 'USD',
        amount: 1000,
        accountAmount: 7200,
      ),
      mkBill(
        'usd-cross-income',
        type: 1,
        currency: 'USD',
        amount: 250,
        accountAmount: 1800,
      ),
      mkBill('jpy-expense', currency: 'JPY', amount: 1531),
    ];
    expect(summarizeBills(bills, const [], 'CNY'), (
      income: BigInt.from(230),
      expense: BigInt.from(529),
    ));
    expect(summarizeBills(bills, const [], 'USD'), (
      income: BigInt.from(250),
      expense: BigInt.from(1000),
    ));
    expect(summarizeBills(bills, const [], 'JPY'), (
      income: BigInt.zero,
      expense: BigInt.from(1531),
    ));
    expect(summarizeBills(bills, const [], 'EUR'), (
      income: BigInt.zero,
      expense: BigInt.zero,
    ));
  });

  test('汇总排除软删、本人转账、余额调节和内部收入，保留既有支出口径', () {
    const internal = Category(
      id: 'internal',
      parentId: null,
      name: '内部往来',
      emoji: '🤝',
      kind: 2,
      sort: 90,
      isPreset: false,
    );
    final bills = [
      mkBill('expense', amount: 100),
      mkBill('internal-expense', amount: 200, categoryId: internal.id),
      mkBill('income', type: 1, amount: 500),
      mkBill('internal-income', type: 1, amount: 700, categoryId: internal.id),
      mkBill('deleted-expense', amount: 999, deletedAt: 1),
      mkBill('deleted-income', type: 1, amount: 999, deletedAt: 1),
      mkBill(
        'transfer',
        type: 2,
        amount: 800,
        toAccountId: 'target',
        toAccountAmount: 100,
      ),
      mkBill('adjust-up', type: 3, amount: 800),
      mkBill('adjust-down', type: 3, amount: -800),
    ];
    expect(summarizeBills(bills, [internal], 'CNY'), (
      income: BigInt.from(500),
      expense: BigInt.from(300),
    ));
  });

  test('聚合超出int64仍精确，未知历史币种独立汇总且不默认人民币', () {
    const maximum = 9223372036854775807;
    final bills = [
      mkBill('income-one', type: 1, amount: maximum),
      mkBill('income-two', type: 1, amount: maximum),
      mkBill('expense-one', amount: maximum),
      mkBill('expense-two', amount: 1),
      mkBill('unknown-income', type: 1, currency: 'XTS', amount: 1531),
      mkBill('unknown-expense', currency: 'XTS', amount: 29),
    ];
    final yuan = summarizeBills(bills, const [], 'CNY');
    expect(yuan.income, BigInt.from(maximum) * BigInt.two);
    expect(yuan.expense, BigInt.from(maximum) + BigInt.one);
    expect(
      displayCurrencyAmount(yuan.income, 'CNY'),
      '¥ 184,467,440,737,095,516.14',
    );
    expect(summarizeBills(bills, const [], 'XTS'), (
      income: BigInt.from(1531),
      expense: BigInt.from(29),
    ));
  });
}
