import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/utils/balance.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/utils/money.dart';

import '../helpers/test_support.dart';

void main() {
  test('两笔合法收入合计超过 int64 时精确余额保持正数，旧接口明确拒绝', () {
    final accounts = [mkAccount('cash')];
    final bills = [
      mkBill(
        'maximum',
        type: 1,
        accountId: 'cash',
        amount: 9223372036854775807,
      ),
      mkBill('one-more', type: 1, accountId: 'cash', amount: 1),
    ];
    final expected = BigInt.parse('9223372036854775808');
    final balances = computeExactBalances(accounts, bills);
    expect(balances, {'cash': expected});
    expect(computeExactNetWorthByCurrency(accounts, balances), {
      'CNY': expected,
    });
    expect(() => computeBalances(accounts, bills), throwsRangeError);
  });

  test('同币两个合法期初余额超过 int64 时分币种净资产精确且旧接口拒绝', () {
    final accounts = [
      mkAccount('maximum', currency: 'JPY', initBalance: 9223372036854775807),
      mkAccount('one-more', currency: 'JPY', initBalance: 1),
    ];
    final balances = computeBalances(accounts, []);
    expect(balances, {'maximum': 9223372036854775807, 'one-more': 1});
    expect(
      computeExactNetWorthByCurrency(
        accounts,
        computeExactBalances(accounts, []),
      ),
      {'JPY': BigInt.parse('9223372036854775808')},
    );
    expect(
      () => computeNetWorthByCurrency(accounts, balances),
      throwsRangeError,
    );
  });

  test('最小调节后再支出一分精确余额仍负数，旧接口拒绝而不回绕成正数', () {
    final accounts = [mkAccount('cash')];
    final bills = [
      mkBill(
        'minimum',
        type: 3,
        accountId: 'cash',
        amount: -9223372036854775808,
      ),
      mkBill('one-more', accountId: 'cash', amount: 1),
    ];
    expect(computeExactBalances(accounts, bills), {
      'cash': BigInt.parse('-9223372036854775809'),
    });
    expect(() => computeBalances(accounts, bills), throwsRangeError);
    expect(
      () => computeNetWorthByCurrency(
        [mkAccount('minimum'), mkAccount('negative-one')],
        {'minimum': -9223372036854775808, 'negative-one': -1},
      ),
      throwsRangeError,
    );
  });

  test('精确聚合金额共享币种格式，超 int64 仍保留符号尾分和日元整数', () {
    final units = BigInt.parse('9223372036854775808');
    expect(
      formatBigMinorUnits(units, Currency.cny, signed: true),
      '+92,233,720,368,547,758.08',
    );
    expect(
      formatBigMinorUnits(-units - BigInt.one, Currency.cny),
      '-92,233,720,368,547,758.09',
    );
    expect(
      formatBigMinorUnits(units, Currency.jpy),
      '9,223,372,036,854,775,808',
    );
    expect(
      formatBigMinorUnits(units, Currency.usd, grouping: false),
      '92233720368547758.08',
    );
    expect(
      formatBigMinorUnits(BigInt.zero, Currency.cny, signed: true),
      '0.00',
    );
    expect(
      formatMinorUnits(-9223372036854775808, Currency.cny),
      '-92,233,720,368,547,758.08',
    );
  });

  test('USD10/CNY72按人民币实扣减余额，跨币收入按实际到账加余额', () {
    final accounts = [mkAccount('cash', initBalance: 10000)];
    final bills = [
      mkBill(
        'expense',
        accountId: 'cash',
        currency: 'USD',
        amount: 1000,
        accountAmount: 7200,
      ),
      mkBill(
        'income',
        type: 1,
        accountId: 'cash',
        currency: 'USD',
        amount: 200,
        accountAmount: 1440,
      ),
    ];
    expect(computeBalances(accounts, bills), {'cash': 4240});
  });

  test('外币账户同样按该账户实际额，不把交易人民币分直接用于美元余额', () {
    final accounts = [mkAccount('usd', currency: 'USD', initBalance: 5000)];
    final bills = [
      mkBill('expense', accountId: 'usd', amount: 7200, accountAmount: 1000),
    ];
    expect(computeBalances(accounts, bills), {'usd': 4000});
  });

  test('JPY以整数最小单位计算跨币支出和同币收入，不做百分换算', () {
    final accounts = [mkAccount('jpy', currency: 'JPY', initBalance: 5000)];
    final bills = [
      mkBill(
        'expense',
        accountId: 'jpy',
        currency: 'USD',
        amount: 1000,
        accountAmount: 1531,
      ),
      mkBill('income', type: 1, accountId: 'jpy', currency: 'JPY', amount: 500),
    ];
    expect(computeBalances(accounts, bills), {'jpy': 3969});
  });

  test('同币外币转账双向记实际额，账户总额守恒', () {
    final accounts = [
      mkAccount('from', currency: 'USD', initBalance: 5000),
      mkAccount('to', currency: 'USD', initBalance: 2000),
    ];
    final bills = [
      mkBill(
        'transfer',
        type: 2,
        accountId: 'from',
        toAccountId: 'to',
        currency: 'USD',
        amount: 529,
      ),
    ];
    final balances = computeBalances(accounts, bills);
    expect(balances, {'from': 4471, 'to': 2529});
    expect(computeNetWorthByCurrency(accounts, balances), {'USD': 7000});
  });

  test('软删除的收支转账和调节均不影响账户余额', () {
    final accounts = [mkAccount('from', initBalance: 5000), mkAccount('to')];
    final bills = [
      for (final type in [0, 1, 2, 3])
        mkBill(
          '$type',
          type: type,
          accountId: 'from',
          toAccountId: type == 2 ? 'to' : null,
          amount: 1000,
          accountAmount: 7200,
          deletedAt: 123,
        ),
    ];
    expect(computeBalances(accounts, bills), {'from': 5000, 'to': 0});
  });

  test('有符号余额调节按实际额增减，未识别类型不参与', () {
    final accounts = [mkAccount('cash', initBalance: 1000)];
    final bills = [
      mkBill(
        'positive',
        type: 3,
        accountId: 'cash',
        currency: 'USD',
        amount: 100,
        accountAmount: 300,
      ),
      mkBill(
        'negative',
        type: 3,
        accountId: 'cash',
        currency: 'USD',
        amount: -200,
        accountAmount: -529,
      ),
      mkBill('unknown', type: 9, accountId: 'cash', accountAmount: 9999),
    ];
    expect(computeBalances(accounts, bills), {'cash': 771});
    expect(
      computeBalances(
        [mkAccount('cash')],
        [
          mkBill(
            'minimum',
            type: 3,
            accountId: 'cash',
            amount: -9223372036854775808,
          ),
        ],
      ),
      {'cash': -9223372036854775808},
    );
  });

  test('历史跨币坏转账不把来源实际额误加到另一币种的目标', () {
    final accounts = [
      mkAccount('cny', initBalance: 10000),
      mkAccount('usd', currency: 'USD', initBalance: 5000),
    ];
    final bills = [
      mkBill(
        'bad-transfer',
        type: 2,
        accountId: 'cny',
        toAccountId: 'usd',
        amount: 7200,
      ),
    ];
    expect(computeBalances(accounts, bills), {'cny': 2800, 'usd': 5000});
  });

  test('历史缺失转入账户保留来源扣款，不凭账单创建幽灵余额', () {
    final accounts = [mkAccount('cash', initBalance: 10000)];
    final bills = [
      mkBill(
        'missing',
        type: 2,
        accountId: 'cash',
        toAccountId: 'ghost',
        amount: 529,
      ),
      mkBill('unknown-source', type: 0, accountId: 'ghost', amount: 999),
    ];
    expect(computeBalances(accounts, bills), {'cash': 9471});
  });

  test('净资产逐币种合计，排除不计资产账户但不影响其单账户余额', () {
    final accounts = [
      mkAccount('cny-a', initBalance: 10000),
      mkAccount('cny-b', initBalance: -500),
      mkAccount('usd', currency: 'USD', initBalance: 10000),
      mkAccount('jpy', currency: 'JPY', initBalance: 10000),
      mkAccount(
        'excluded',
        currency: 'USD',
        initBalance: 90000,
        includeNetWorth: false,
      ),
      mkAccount('aa', type: 4, initBalance: 50000, includeNetWorth: false),
    ];
    final balances = computeBalances(accounts, []);
    expect(balances['excluded'], 90000);
    expect(computeNetWorthByCurrency(accounts, balances), {
      'CNY': 9500,
      'USD': 10000,
      'JPY': 10000,
    });
  });

  test('未知币种保留独立资产分组，已知代码规范化但不默认人民币', () {
    final accounts = [
      mkAccount('known', currency: ' usd ', initBalance: 1000),
      mkAccount('cny', initBalance: 100),
      mkAccount('unknown', currency: 'XTS', initBalance: 300),
      mkAccount('blank', currency: '', initBalance: 400),
    ];
    expect(computeNetWorthByCurrency(accounts, computeBalances(accounts, [])), {
      'USD': 1000,
      'CNY': 100,
      'XTS': 300,
      '': 400,
    });
    expect(computeNetWorthByCurrency([], {}), isEmpty);
  });

  test('大金额实际额及净资产保留尾分，纯聚合不改写调用者输入', () {
    final accounts = [
      mkAccount('usd', currency: 'USD', initBalance: 9007199254740993),
    ];
    final bills = [
      mkBill('expense', accountId: 'usd', amount: 7200, accountAmount: 1000),
    ];
    final accountBefore = accounts.single.toJson();
    final billBefore = bills.single.toJson();
    final balances = computeBalances(accounts, bills);
    expect(balances['usd'], 9007199254739993);
    expect(computeNetWorthByCurrency(accounts, balances), {
      'USD': 9007199254739993,
    });
    expect(accounts.single.toJson(), accountBefore);
    expect(bills.single.toJson(), billBefore);
    expect(balances, {'usd': 9007199254739993});
  });
}
