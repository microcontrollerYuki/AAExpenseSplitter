import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/utils/balance.dart';

import '../helpers/test_support.dart';

void main() {
  test('旧同币结算转账缺新字段仍保留原双向余额，不重写历史金额', () {
    final accounts = [mkAccount('source'), mkAccount('target')];
    final bill = mkBill(
      'legacy',
      type: 2,
      amount: 1234,
      accountId: 'source',
      toAccountId: 'target',
      settlementId: 'old-settlement',
    );
    expect(computeExactBalances(accounts, [bill]), {
      'source': BigInt.from(-1234),
      'target': BigInt.from(1234),
    });
  });

  test('异常跨币AA或结算行不能把新入账额计入另一币种账户', () {
    final accounts = [
      mkAccount('source'),
      mkAccount('target', currency: 'USD'),
    ];
    for (final kind in ['aa', 'group', 'settlement']) {
      final bill = mkBill(
        'bad-$kind',
        type: 2,
        amount: 7200,
        accountId: 'source',
        toAccountId: 'target',
        toAccountAmount: 1000,
        isAa: kind == 'aa',
        aaGroupId: kind == 'group' ? 'group' : null,
        settlementId: kind == 'settlement' ? 'settlement' : null,
      );
      expect(computeExactBalances(accounts, [bill]), {
        'source': BigInt.from(-7200),
        'target': BigInt.zero,
      });
    }
  });
}
