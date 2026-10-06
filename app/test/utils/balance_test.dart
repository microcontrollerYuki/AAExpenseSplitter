import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/utils/balance.dart';

import '../helpers/test_support.dart';

void main() {
  final accounts = [
    mkAccount('a1', initBalance: 10000),
    mkAccount('a2', name: '微信', initBalance: 500),
  ];

  test('空账单时余额为期初余额', () {
    expect(computeBalances(accounts, []), {'a1': 10000, 'a2': 500});
    expect(computeBalances([], []), <String, int>{});
  });

  test('支出减余额、收入加余额', () {
    final bills = [
      mkBill('b1', type: 0, amount: 300, accountId: 'a1'),
      mkBill('b2', type: 1, amount: 50, accountId: 'a1'),
    ];
    expect(computeBalances(accounts, bills)['a1'], 10000 - 300 + 50);
  });

  test('转账：转出减、转入加', () {
    final bills = [
      mkBill('b1', type: 2, amount: 200, accountId: 'a1', toAccountId: 'a2'),
    ];
    final b = computeBalances(accounts, bills);
    expect(b['a1'], 10000 - 200);
    expect(b['a2'], 500 + 200);
  });

  test('转账缺少 toAccountId 只扣转出方', () {
    final bills = [
      mkBill('b1', type: 2, amount: 200, accountId: 'a1', toAccountId: null),
    ];
    final b = computeBalances(accounts, bills);
    expect(b['a1'], 10000 - 200);
    expect(b['a2'], 500);
  });

  test('账单指向未知账户被忽略（不新增键）', () {
    final bills = [
      mkBill('b1', type: 0, amount: 100, accountId: 'ghost'),
      mkBill('b2', type: 1, amount: 100, accountId: 'ghost'),
      mkBill('b3', type: 2, amount: 100, accountId: 'a1', toAccountId: 'ghost'),
    ];
    final b = computeBalances(accounts, bills);
    expect(b.containsKey('ghost'), isFalse);
    expect(b['a1'], 10000 - 100); // ghost 的转入被忽略，a1 正常扣
  });

  test('未知 type 不影响余额', () {
    final bills = [mkBill('b1', type: 9, amount: 999, accountId: 'a1')];
    expect(computeBalances(accounts, bills)['a1'], 10000);
  });
}
