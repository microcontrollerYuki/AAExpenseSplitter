import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/utils/balance.dart';

import '../helpers/test_support.dart';

Future<void> _account(
  AppDatabase db,
  String id,
  String currency, {
  int type = 3,
  int initBalance = 0,
}) => db.upsertAccount(
  id: id,
  name: id,
  emoji: '💳',
  type: type,
  initBalance: initBalance,
  includeNetWorth: true,
  sort: 20,
  currency: currency,
);

Future<void> _transfer(
  AppDatabase db, {
  String id = 'transfer',
  int amount = 7200,
  String currency = 'CNY',
  int? accountAmount,
  int? toAccountAmount,
  String accountId = 'acc_cash',
  String? toAccountId = 'usd',
  String? categoryId,
  int dateMs = 100,
  String note = '',
  int? createdAt,
  String? aaGroupId,
  String? settlementId,
}) => db.upsertBill(
  id: id,
  type: 2,
  amount: amount,
  currency: currency,
  accountAmount: accountAmount,
  toAccountAmount: toAccountAmount,
  accountId: accountId,
  toAccountId: toAccountId,
  categoryId: categoryId,
  dateMs: dateMs,
  note: note,
  createdAt: createdAt,
  aaGroupId: aaGroupId,
  settlementId: settlementId,
);

Future<Bill> _readBill(AppDatabase db, [String id = 'transfer']) async =>
    (await db.select(db.bills).get()).singleWhere((row) => row.id == id);

Future<Map<String, BigInt>> _balances(AppDatabase db) async =>
    computeExactBalances(await db.getAllAccounts(), await db.getAllBills());

// 包括软删除数据、三个金额及时间戳，确保失败不会局部修改任何一张表。
Future<Map<String, Object?>> _snapshot(AppDatabase db) async => {
  'accounts': {
    for (final row in await db.select(db.accounts).get()) row.id: row.toJson(),
  },
  'bills': {
    for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
  },
  'categories': {
    for (final row in await db.select(db.categories).get())
      row.id: row.toJson(),
  },
  'aaGroups': {
    for (final row in await db.select(db.aaGroups).get()) row.id: row.toJson(),
  },
  'settlements': {
    for (final row in await db.select(db.settlements).get())
      row.id: row.toJson(),
  },
  'meta': {
    for (final row in await db.select(db.metaEntries).get())
      row.key: row.toJson(),
  },
};

Future<void> _rejectWithoutChanges(
  AppDatabase db,
  Future<void> Function() action,
) async {
  final before = await _snapshot(db);
  await expectLater(action(), throwsStateError);
  expect(await _snapshot(db), before);
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _account(db, 'jpy', 'JPY');
  });
  tearDown(() => db.close());

  test('同币转账默认转入等于转出，兼容旧空字段和零金额', () async {
    await _transfer(db, amount: 529, toAccountId: 'acc_bank');
    var row = await _readBill(db);
    expect(
      [row.amount, row.accountAmount, row.toAccountAmount],
      [529, 529, 529],
    );
    var balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.from(-529));
    expect(balances['acc_bank'], BigInt.from(529));

    // v4 同币历史行允许迁移后字段为 NULL，不能丢失转入余额。
    await db.customStatement(
      'UPDATE bills SET to_account_amount = NULL WHERE id = ?',
      ['transfer'],
    );
    balances = await _balances(db);
    expect(balances['acc_bank'], BigInt.from(529));
    await _transfer(db, amount: 0, toAccountId: 'acc_bank');
    row = await _readBill(db);
    expect([row.amount, row.accountAmount, row.toAccountAmount], [0, 0, 0]);
    await _rejectWithoutChanges(
      db,
      () => _transfer(
        db,
        amount: 529,
        toAccountId: 'acc_bank',
        toAccountAmount: 528,
      ),
    );
  });

  test('人民币转美元分别扣72元与入10美元，不把出账数字当入账数字', () async {
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    final row = await _readBill(db);
    expect(row.currency, 'CNY');
    expect(
      [row.amount, row.accountAmount, row.toAccountAmount],
      [7200, 7200, 1000],
    );
    expect(row.createdAt, 17);
    final balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.from(-7200));
    expect(balances['usd'], BigInt.from(1000));
  });

  test('美元转日元使用不同精度的账户最小单位并精确入账', () async {
    // 转账未传交易币种时，采用出账账户 USD，不能默认为 CNY。
    await db.upsertBill(
      id: 'transfer',
      type: 2,
      accountId: 'usd',
      toAccountId: 'jpy',
      amount: 1000,
      toAccountAmount: 1531,
      dateMs: 100,
    );
    final row = await _readBill(db);
    expect(row.currency, 'USD');
    expect(
      [row.amount, row.accountAmount, row.toAccountAmount],
      [1000, 1000, 1531],
    );
    final balances = await _balances(db);
    expect(balances['usd'], BigInt.from(-1000));
    expect(balances['jpy'], BigInt.from(1531));
  });

  test('跨币int64边界分别持久化，聚合余额超过int64仍精确', () async {
    const maximum = 9223372036854775807;
    await _account(db, 'jpy', 'JPY', initBalance: maximum);
    await _transfer(
      db,
      currency: 'USD',
      accountId: 'usd',
      toAccountId: 'jpy',
      amount: maximum,
      toAccountAmount: maximum - 1,
    );
    final row = await _readBill(db);
    expect(row.amount, maximum);
    expect(row.toAccountAmount, maximum - 1);
    final balances = await _balances(db);
    expect(balances['usd'], -BigInt.from(maximum));
    expect(balances['jpy'], BigInt.from(maximum) * BigInt.two - BigInt.one);
  });

  test('新增跨币必须明确正数入账，任一方向零或负数均拒绝且整库不变', () async {
    for (final incoming in <int?>[null, 0, -1]) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, toAccountAmount: incoming),
      );
    }
    for (final outgoing in [0, -1]) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, amount: outgoing, toAccountAmount: 1000),
      );
    }
  });

  test('缺失来源目标、自转和未知账户币种拒绝且不留下记录', () async {
    await _account(db, 'unknown', 'CNY');
    await db.customStatement('UPDATE accounts SET currency = ? WHERE id = ?', [
      'BTC',
      'unknown',
    ]);
    for (final source in ['missing', 'unknown']) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, accountId: source, toAccountAmount: 1000),
      );
    }
    for (final target in <String?>[null, 'missing', 'unknown', 'acc_cash']) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, toAccountId: target, toAccountAmount: 1000),
      );
    }
  });

  test('转账原币必须是出账账户币种且实扣必须等于出账金额', () async {
    for (final code in ['USD', 'JPY', 'BTC', '']) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(
          db,
          currency: code,
          accountAmount: 7200,
          toAccountAmount: 1000,
        ),
      );
    }
    for (final actual in [7199, 0, -1]) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, accountAmount: actual, toAccountAmount: 1000),
      );
    }
  });

  test('跨币及同币转账都不能使用AA账户或关联AA和结算', () async {
    await _account(db, kAaCreditAccountId, 'CNY', type: 4);
    await _account(db, 'another-aa', 'CNY', type: 4);
    for (final aa in [kAaCreditAccountId, 'another-aa']) {
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, accountId: aa, toAccountAmount: 1000),
      );
      await _rejectWithoutChanges(
        db,
        () => _transfer(db, toAccountId: aa, toAccountAmount: 7200),
      );
    }
    for (final target in ['usd', 'acc_bank']) {
      final incoming = target == 'usd' ? 1000 : 7200;
      await _rejectWithoutChanges(
        db,
        () => _transfer(
          db,
          toAccountId: target,
          toAccountAmount: incoming,
          aaGroupId: 'group',
        ),
      );
      await _rejectWithoutChanges(
        db,
        () => _transfer(
          db,
          toAccountId: target,
          toAccountAmount: incoming,
          settlementId: 'settlement',
        ),
      );
      await _rejectWithoutChanges(
        db,
        () => _transfer(
          db,
          toAccountId: target,
          toAccountAmount: incoming,
          categoryId: kAaMarkerCategoryId,
        ),
      );
    }
  });

  test('原AA或结算账单省略关联仍不能伪装成普通转账', () async {
    for (final settlement in [false, true]) {
      final id = settlement ? 'settlement-bill' : 'aa-bill';
      await db.upsertBill(
        id: id,
        type: 0,
        amount: 7200,
        accountId: 'acc_cash',
        categoryId: 'cat_food',
        dateMs: 100,
        aaGroupId: settlement ? null : 'group',
        settlementId: settlement ? 'settlement' : null,
      );
      for (final target in ['usd', 'acc_bank']) {
        await _rejectWithoutChanges(
          db,
          () => _transfer(
            db,
            id: id,
            toAccountId: target,
            toAccountAmount: target == 'usd' ? 1000 : 7200,
          ),
        );
      }
      // 即使历史坏数据已经写成转账，旧金额快捷入口也不能改写原关联。
      await db.customStatement(
        'UPDATE bills SET type = 2, to_account_id = ?, '
        'to_account_amount = amount WHERE id = ?',
        ['acc_bank', id],
      );
      await _rejectWithoutChanges(db, () => db.updateBillAmount(id, 123));
      await _rejectWithoutChanges(
        db,
        () => db.updateBillAmountAndDate(id, 123, 200),
      );
    }
  });

  test('仅改跨币转账备注日期可省入账金额并保留创建时间', () async {
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    final before = await _readBill(db);
    await _transfer(db, dateMs: 200, note: '更正备注');
    final after = await _readBill(db);
    expect(after.toJson(), {
      ...before.toJson(),
      'dateMs': 200,
      'note': '更正备注',
      'updatedAt': after.updatedAt,
    });
  });

  test('跨币转账改出账额、来源或目标时必须重新明确入账金额', () async {
    await _account(db, 'cash-2', 'CNY');
    await _account(db, 'usd-2', 'USD');
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    final attempts = <Future<void> Function()>[
      () => _transfer(db, amount: 7300),
      () => _transfer(db, accountId: 'cash-2'),
      () => _transfer(db, toAccountId: 'usd-2'),
      () => _transfer(db, toAccountId: 'jpy'),
      () => _transfer(db, toAccountId: 'acc_wechat'),
      () => _transfer(db, currency: 'USD', accountId: 'usd-2', amount: 1000),
    ];
    for (final attempt in attempts) {
      await _rejectWithoutChanges(db, attempt);
    }
    await _transfer(db, toAccountId: 'acc_wechat', toAccountAmount: 7200);
    final sameCurrency = await _readBill(db);
    expect(sameCurrency.toAccountId, 'acc_wechat');
    expect(sameCurrency.toAccountAmount, 7200);
    // 相同字段的普通收支历史行也不能借旧入账字段自动变成跨币转账。
    await db.upsertBill(
      id: 'ordinary',
      type: 0,
      amount: 7200,
      accountId: 'acc_cash',
      dateMs: 100,
    );
    await _rejectWithoutChanges(db, () => _transfer(db, id: 'ordinary'));
  });

  test('明确新入账额后可修改来源目标和出账额，余额同步且创建时间不变', () async {
    await _account(db, 'cash-2', 'CNY');
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    await _transfer(
      db,
      amount: 7300,
      accountId: 'cash-2',
      toAccountId: 'jpy',
      toAccountAmount: 1531,
      dateMs: 200,
    );
    final row = await _readBill(db);
    expect(row.createdAt, 17);
    expect(
      [row.amount, row.accountAmount, row.toAccountAmount],
      [7300, 7300, 1531],
    );
    final balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.zero);
    expect(balances['usd'], BigInt.zero);
    expect(balances['cash-2'], BigInt.from(-7300));
    expect(balances['jpy'], BigInt.from(1531));
  });

  test('跨币转账软删除撤销同时回滚恢复两边余额，三个金额保持原值', () async {
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    final before = await _readBill(db);
    await db.softDeleteBill('transfer');
    var balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.zero);
    expect(balances['usd'], BigInt.zero);
    expect((await _readBill(db)).deletedAt, isNotNull);
    await db.restoreBill('transfer');
    expect((await _readBill(db)).toJson(), before.toJson());
    balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.from(-7200));
    expect(balances['usd'], BigInt.from(1000));
  });

  test('人民币同币旧快捷更新同步三个金额并保持日期或明确更新日期', () async {
    await _transfer(db, amount: 529, toAccountId: 'acc_bank', createdAt: 17);
    await db.updateBillAmount('transfer', 631);
    var row = await _readBill(db);
    expect(
      [row.amount, row.accountAmount, row.toAccountAmount],
      [631, 631, 631],
    );
    expect(row.dateMs, 100);
    await db.updateBillAmountAndDate('transfer', 0, 200);
    row = await _readBill(db);
    expect([row.amount, row.accountAmount, row.toAccountAmount], [0, 0, 0]);
    expect(row.dateMs, 200);
    expect(row.createdAt, 17);
  });

  test('旧人民币快捷入口拒绝跨币及同币外币转账且完整快照不变', () async {
    await _transfer(db, toAccountAmount: 1000);
    await _account(db, 'usd-2', 'USD');
    await _transfer(
      db,
      id: 'usd-transfer',
      currency: 'USD',
      accountId: 'usd',
      toAccountId: 'usd-2',
      amount: 1000,
    );
    for (final id in ['transfer', 'usd-transfer']) {
      await _rejectWithoutChanges(db, () => db.updateBillAmount(id, 123));
      await _rejectWithoutChanges(
        db,
        () => db.updateBillAmountAndDate(id, 123, 200),
      );
    }
  });

  test('普通收支和余额调节不能携带转入金额', () async {
    for (final type in [0, 1, 3]) {
      await _rejectWithoutChanges(
        db,
        () => db.upsertBill(
          id: 'ordinary',
          type: type,
          amount: 1000,
          accountId: 'acc_cash',
          toAccountAmount: 1000,
          dateMs: 100,
        ),
      );
    }
  });

  test('转账改为普通收支会清空转入账户与金额，不再影响原转入方余额', () async {
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    await db.upsertBill(
      id: 'transfer',
      type: 0,
      amount: 7200,
      accountId: 'acc_cash',
      categoryId: 'cat_food',
      dateMs: 200,
    );
    final row = await _readBill(db);
    expect(row.type, 0);
    expect(row.toAccountId, isNull);
    expect(row.toAccountAmount, isNull);
    expect(row.createdAt, 17);
    final balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.from(-7200));
    expect(balances['usd'], BigInt.zero);
  });

  test('外层事务中止时完整回滚转账三个金额、账户、备注和元数据', () async {
    await _transfer(db, toAccountAmount: 1000, createdAt: 17);
    await _rejectWithoutChanges(
      db,
      () => db.transaction(() async {
        await _transfer(
          db,
          amount: 7300,
          toAccountId: 'jpy',
          toAccountAmount: 1531,
          note: '不应保留',
        );
        await _account(db, 'new-account', 'EUR', initBalance: 123);
        await db.setMeta('cross-transfer-abort', '不应保留');
        throw StateError('主动中止外层事务');
      }),
    );
  });
}
