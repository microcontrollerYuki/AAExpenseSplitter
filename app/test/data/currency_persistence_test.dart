import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';

import '../helpers/test_support.dart';

Future<void> _account(
  AppDatabase db, {
  String id = 'foreign',
  String? currency,
  String name = '旅行账户',
  int type = 3,
  int initBalance = 0,
}) => db.upsertAccount(
  id: id,
  name: name,
  emoji: '💳',
  type: type,
  initBalance: initBalance,
  includeNetWorth: true,
  sort: 20,
  currency: currency,
);

Future<void> _bill(
  AppDatabase db, {
  String id = 'bill',
  int type = 0,
  int amount = 1000,
  String? currency,
  int? accountAmount,
  String accountId = 'acc_cash',
  String? toAccountId,
  String? categoryId = 'cat_food',
  int dateMs = 100,
  String note = '',
  int? createdAt,
  String? aaGroupId,
  String? settlementId,
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  currency: currency,
  accountAmount: accountAmount,
  accountId: accountId,
  toAccountId: toAccountId,
  categoryId: categoryId,
  dateMs: dateMs,
  note: note,
  createdAt: createdAt,
  aaGroupId: aaGroupId,
  settlementId: settlementId,
);

Future<Bill> _readBill(AppDatabase db, [String id = 'bill']) async =>
    (await db.select(db.bills).get()).singleWhere((row) => row.id == id);

// 包括软删除记录和时间戳，避免失败路径只验证可见账单或业务金额。
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
  });
  tearDown(() => db.close());

  test('旧调用与预置账户默认人民币，账单实扣金额等于原金额', () async {
    expect((await db.getAllAccounts()).map((row) => row.currency).toSet(), {
      'CNY',
    });
    await _account(db);
    await _bill(db, amount: 529, createdAt: 17);
    expect((await db.getAccount('foreign'))!.currency, 'CNY');
    final row = await _readBill(db);
    expect(row.currency, 'CNY');
    expect(row.amount, 529);
    expect(row.accountAmount, 529);
    expect(row.createdAt, 17);
  });

  test('六币种代码统一规范，日元整数及超过浮点精度的金额精确保留', () async {
    const codes = ['CNY', 'USD', 'HKD', 'EUR', 'JPY', 'GBP'];
    for (final code in codes) {
      final amount = code == 'JPY' ? 1531 : 9007199254740993;
      await _account(
        db,
        id: code,
        currency: ' ${code.toLowerCase()} ',
        initBalance: amount,
      );
      await _bill(
        db,
        id: code,
        currency: ' ${code.toLowerCase()} ',
        accountId: code,
        amount: amount,
      );
      final account = (await db.getAccount(code))!;
      final row = await _readBill(db, code);
      expect(account.currency, code);
      expect(account.initBalance, amount);
      expect(row.currency, code);
      expect(row.amount, amount);
      expect(row.accountAmount, amount);
    }
  });

  test('编辑外币账户时省略币种会保留原币种', () async {
    await _account(db, currency: 'USD', initBalance: 500);
    await _account(db, name: '美元旅行账户', initBalance: 600);
    final account = (await db.getAccount('foreign'))!;
    expect(account.currency, 'USD');
    expect(account.name, '美元旅行账户');
    expect(account.initBalance, 600);
  });

  test('未使用账户可更改币种，空白及未知币种拒绝且整库不变', () async {
    await _account(db, currency: 'USD');
    await _account(db, currency: ' jpy ');
    expect((await db.getAccount('foreign'))!.currency, 'JPY');
    for (final code in ['', ' ', 'BTC', 'US D', '人民币']) {
      await _rejectWithoutChanges(
        db,
        () => _account(db, currency: code, name: '不应保存'),
      );
      await _rejectWithoutChanges(
        db,
        () => _account(db, id: 'new-account', currency: code),
      );
    }
  });

  test('账户被活动或软删除账单引用后均不能更改币种', () async {
    await _account(db, currency: 'USD');
    await _bill(db, currency: 'USD', accountId: 'foreign');
    await _rejectWithoutChanges(db, () => _account(db, currency: 'JPY'));
    await db.softDeleteBill('bill');
    expect((await _readBill(db)).deletedAt, isNotNull);
    await _rejectWithoutChanges(db, () => _account(db, currency: 'JPY'));
    await _account(db, name: '仍能修改名称');
    expect((await db.getAccount('foreign'))!.currency, 'USD');
  });

  test('仅作为转入方且转账已软删除的账户仍不能更改币种', () async {
    await _account(db, id: 'source', currency: 'USD');
    await _account(db, id: 'destination', currency: 'USD');
    await _bill(
      db,
      type: 2,
      currency: 'USD',
      accountId: 'source',
      toAccountId: 'destination',
      categoryId: null,
    );
    await db.softDeleteBill('bill');
    expect(await db.billCountOfAccount('destination'), 0);
    await _rejectWithoutChanges(
      db,
      () => _account(db, id: 'destination', currency: 'CNY'),
    );
  });

  test('AA固定账户与所有type4挂账账户仅可使用人民币', () async {
    for (final entry in [(kAaCreditAccountId, 3), ('another-aa', 4)]) {
      await _rejectWithoutChanges(
        db,
        () => _account(db, id: entry.$1, type: entry.$2, currency: 'USD'),
      );
      await _account(db, id: entry.$1, type: entry.$2, currency: 'CNY');
      expect((await db.getAccount(entry.$1))!.currency, 'CNY');
      await _rejectWithoutChanges(
        db,
        () => _account(db, id: entry.$1, type: entry.$2, currency: 'JPY'),
      );
    }
  });

  test('USD10与CNY72分别持久化，旧编辑调用保留币种实扣及创建时间', () async {
    await _bill(
      db,
      currency: 'USD',
      accountAmount: 7200,
      note: '原备注',
      createdAt: 19,
    );
    final before = await _readBill(db);
    expect(before.amount, 1000);
    expect(before.currency, 'USD');
    expect(before.accountAmount, 7200);
    await _bill(db, categoryId: 'cat_shopping', dateMs: 200, note: '只更新备注日期分类');
    final after = await _readBill(db);
    expect(after.toJson(), {
      ...before.toJson(),
      'categoryId': 'cat_shopping',
      'dateMs': 200,
      'note': '只更新备注日期分类',
      'updatedAt': after.updatedAt,
    });
  });

  test('新增跨币账单必须明确实扣金额，拒绝后整库无新增记录', () async {
    await _rejectWithoutChanges(db, () => _bill(db, currency: 'USD'));
    await _account(db, currency: 'USD');
    await _rejectWithoutChanges(db, () => _bill(db, accountId: 'foreign'));
  });

  test('既有跨币账单改变金额账户或原币而不提供实扣时拒绝且保留快照', () async {
    await _account(db, id: 'another-cny');
    await _account(db, id: 'usd', currency: 'USD');
    await _bill(db, currency: 'USD', accountAmount: 7200, createdAt: 19);
    await _rejectWithoutChanges(db, () => _bill(db, amount: 1100));
    await _rejectWithoutChanges(db, () => _bill(db, accountId: 'another-cny'));
    await _rejectWithoutChanges(db, () => _bill(db, accountId: 'usd'));
    await _rejectWithoutChanges(db, () => _bill(db, currency: 'EUR'));
    await _rejectWithoutChanges(db, () => _bill(db, currency: 'CNY'));
  });

  test('提供新实扣后可修改跨币金额账户或原币，创建时间保持不变', () async {
    await _account(db, id: 'jpy', currency: 'JPY');
    await _bill(db, currency: 'USD', accountAmount: 7200, createdAt: 19);
    await _bill(db, amount: 1100, accountAmount: 7920);
    expect((await _readBill(db)).accountAmount, 7920);
    await _bill(db, amount: 1100, accountId: 'jpy', accountAmount: 1683);
    var row = await _readBill(db);
    expect(row.currency, 'USD');
    expect(row.accountId, 'jpy');
    expect(row.accountAmount, 1683);
    await _bill(
      db,
      amount: 1200,
      currency: 'EUR',
      accountId: 'jpy',
      accountAmount: 1920,
    );
    row = await _readBill(db);
    expect(row.currency, 'EUR');
    expect(row.amount, 1200);
    expect(row.accountAmount, 1920);
    expect(row.createdAt, 19);
  });

  test('同币账单实扣只能等于原金额，省略后随金额编辑同步', () async {
    await _bill(db, accountAmount: 1000);
    for (final type in [0, 1, 3]) {
      await _rejectWithoutChanges(
        db,
        () => _bill(db, type: type, accountAmount: 999),
      );
    }
    await _bill(db, amount: 529);
    expect((await _readBill(db)).amount, 529);
    expect((await _readBill(db)).accountAmount, 529);
  });

  test('账单未知币种、缺失转出或转入账户均拒绝且完整快照不变', () async {
    await _bill(db, createdAt: 19);
    for (final code in ['', ' ', 'BTC', 'US D']) {
      await _rejectWithoutChanges(
        db,
        () => _bill(db, currency: code, accountAmount: 1000),
      );
    }
    await _rejectWithoutChanges(
      db,
      () => _bill(db, accountId: 'missing-account'),
    );
    await _rejectWithoutChanges(
      db,
      () => _bill(db, type: 2, toAccountId: 'missing-account'),
    );
  });

  test('普通收支与转账非负且允许零，余额调节可带符号', () async {
    for (final type in [0, 1, 2]) {
      final toAccountId = type == 2 ? 'acc_bank' : null;
      await _rejectWithoutChanges(
        db,
        () => _bill(db, type: type, amount: -1, toAccountId: toAccountId),
      );
      await _bill(db, type: type, amount: 0, toAccountId: toAccountId);
      expect((await _readBill(db)).accountAmount, 0);
    }
    await _bill(db, type: 3, amount: -529);
    expect((await _readBill(db)).amount, -529);
    expect((await _readBill(db)).accountAmount, -529);
    for (final type in [0, 1]) {
      await _rejectWithoutChanges(
        db,
        () => _bill(db, type: type, currency: 'USD', accountAmount: -7200),
      );
    }
  });

  test('同币外币账户之间可转账，转出转入及两个金额精确保留', () async {
    await _account(db, id: 'source', currency: 'USD');
    await _account(db, id: 'destination', currency: 'USD');
    await _bill(
      db,
      type: 2,
      currency: 'USD',
      amount: 9007199254740993,
      accountId: 'source',
      toAccountId: 'destination',
      categoryId: null,
    );
    final row = await _readBill(db);
    expect(row.type, 2);
    expect(row.currency, 'USD');
    expect(row.accountId, 'source');
    expect(row.toAccountId, 'destination');
    expect(row.amount, 9007199254740993);
    expect(row.accountAmount, 9007199254740993);
  });

  test('转账拒绝缺少转入、自转、跨币、不同实扣和AA内部往来', () async {
    await _account(db, currency: 'USD');
    await _account(db, id: kAaCreditAccountId, type: 4);
    final attempts = <Future<void> Function()>[
      () => _bill(db, type: 2),
      () => _bill(db, type: 2, toAccountId: 'acc_cash'),
      () => _bill(db, type: 2, toAccountId: 'foreign'),
      () => _bill(
        db,
        type: 2,
        toAccountId: 'acc_bank',
        currency: 'USD',
        accountAmount: 7200,
      ),
      () => _bill(db, type: 2, toAccountId: 'acc_bank', accountAmount: 999),
      () => _bill(db, type: 2, toAccountId: kAaCreditAccountId),
      () => _bill(
        db,
        type: 2,
        accountId: kAaCreditAccountId,
        toAccountId: 'acc_cash',
      ),
      () => _bill(db, type: 2, toAccountId: 'acc_bank', aaGroupId: 'group'),
      () => _bill(
        db,
        type: 2,
        toAccountId: 'acc_bank',
        categoryId: kAaMarkerCategoryId,
      ),
    ];
    for (final attempt in attempts) {
      await _rejectWithoutChanges(db, attempt);
    }
  });

  test('AA关联结算与kind2内部往来均拒绝外币交易或外币账户', () async {
    await _account(db, currency: 'USD');
    for (final accountId in ['acc_cash', 'foreign']) {
      for (final relation in ['aa', 'settlement', 'internal']) {
        await _rejectWithoutChanges(
          db,
          () => _bill(
            db,
            accountId: accountId,
            currency: 'USD',
            accountAmount: accountId == 'acc_cash' ? 7200 : 1000,
            aaGroupId: relation == 'aa' ? 'group' : null,
            settlementId: relation == 'settlement' ? 'settlement' : null,
            categoryId: relation == 'internal'
                ? kAaMarkerCategoryId
                : 'cat_food',
          ),
        );
      }
    }
    await _bill(db, aaGroupId: 'group');
    expect((await _readBill(db)).currency, 'CNY');
    expect((await _readBill(db)).accountAmount, 1000);
  });

  for (final isSettlement in [false, true]) {
    test('既有${isSettlement ? '结算' : '未结算AA'}账单不能省略关联绕过CNY限制', () async {
      if (isSettlement) {
        await db.upsertSettlement(
          SettlementsCompanion.insert(
            id: 'settlement',
            receiverUid: 'me',
            amount: 1000,
            dateMs: 100,
            cutoffMs: 100,
            createdAtMs: 101,
          ),
        );
      } else {
        await db.upsertAaGroup(
          AaGroupsCompanion.insert(
            id: 'group',
            ownerUid: 'me',
            payerUid: 'me',
            totalAmount: 1000,
            dateMs: 100,
            createdAtMs: 101,
            updatedAtMs: 102,
          ),
        );
        expect((await db.getAaGroup('group'))!.settled, isFalse);
      }
      final type = isSettlement ? 1 : 0;
      final categoryId = isSettlement ? 'inc_other' : 'cat_food';
      await _bill(
        db,
        type: type,
        categoryId: categoryId,
        aaGroupId: isSettlement ? null : 'group',
        settlementId: isSettlement ? 'settlement' : null,
        createdAt: 19,
      );

      // 模拟旧编辑页仅提交普通字段；必须读取库中既有关联进行防护。
      await _rejectWithoutChanges(
        db,
        () => _bill(
          db,
          type: type,
          categoryId: categoryId,
          currency: 'USD',
          accountAmount: 7200,
          note: '不应改写关联及币种',
        ),
      );
    });
  }

  test('AA快捷关联及金额更新拒绝外币，服务创建的临时AA组也回滚', () async {
    final service = AaSyncService(db);
    await service.setupPairing(
      myName: '本机',
      partnerName: '伙伴',
      secret: 'currency-test',
    );
    await _account(db, currency: 'USD');
    await _bill(db, currency: 'USD', accountId: 'foreign');
    await _rejectWithoutChanges(db, () => db.linkBillToAaGroup('bill', 'g'));
    await _rejectWithoutChanges(db, () => db.updateBillAmount('bill', 123));
    await _rejectWithoutChanges(
      db,
      () => db.updateBillAmountAndDate('bill', 123, 200),
    );
    await _rejectWithoutChanges(
      db,
      () => service.createAaBillFor(
        billId: 'bill',
        totalAmount: 1000,
        dateMs: 100,
        note: '不应生成组',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      ),
    );
    // 原币为人民币但账户外币也不能从快捷入口改成 AA。
    await _bill(db, currency: 'CNY', accountId: 'foreign', accountAmount: 140);
    await _rejectWithoutChanges(db, () => db.linkBillToAaGroup('bill', 'g'));
    await _rejectWithoutChanges(db, () => db.updateBillAmount('bill', 123));
  });

  test('人民币AA快捷金额更新同步实扣，保留创建时间及AA关联', () async {
    await _bill(db, createdAt: 19);
    await db.linkBillToAaGroup('bill', 'group');
    await db.updateBillAmount('bill', 529);
    var row = await _readBill(db);
    expect(row.amount, 529);
    expect(row.accountAmount, 529);
    expect(row.dateMs, 100);
    await db.updateBillAmountAndDate('bill', 631, 200);
    row = await _readBill(db);
    expect(row.amount, 631);
    expect(row.accountAmount, 631);
    expect(row.dateMs, 200);
    expect(row.createdAt, 19);
    expect(row.currency, 'CNY');
    expect(row.isAa, isTrue);
    expect(row.aaGroupId, 'group');
  });

  test('结算本机编辑拒绝外币账户，人民币改账户不改写金额与创建时间', () async {
    await _account(db, currency: 'USD');
    await _bill(db, settlementId: 'settlement', createdAt: 19);
    final before = await _snapshot(db);
    expect(
      await db.updateSettlementBillLocalFields(
        billId: 'bill',
        settlementId: 'settlement',
        accountId: 'foreign',
        note: '不应保存',
      ),
      isFalse,
    );
    expect(await _snapshot(db), before);
    expect(
      await db.updateSettlementBillLocalFields(
        billId: 'bill',
        settlementId: 'settlement',
        accountId: 'acc_bank',
        note: '本机备注',
      ),
      isTrue,
    );
    final row = await _readBill(db);
    expect(row.accountId, 'acc_bank');
    expect(row.note, '本机备注');
    expect(row.currency, 'CNY');
    expect(row.amount, 1000);
    expect(row.accountAmount, 1000);
    expect(row.createdAt, 19);
    expect(row.settlementId, 'settlement');
  });

  test('AA结算服务拒绝外币账户且不核销分摊组或落入结算账单', () async {
    final service = AaSyncService(db);
    await service.setupPairing(
      myName: '本机',
      partnerName: '伙伴',
      secret: 'currency-test',
    );
    await db.setMeta('partnerUid', 'partner');
    final myUid = (await db.getMeta('myUid'))!;
    await db.upsertAaGroup(
      AaGroupsCompanion.insert(
        id: 'group',
        ownerUid: myUid,
        payerUid: myUid,
        totalAmount: 1000,
        dateMs: 100,
        createdAtMs: 101,
        updatedAtMs: 102,
      ),
    );
    await _account(db, currency: 'USD');
    await _rejectWithoutChanges(
      db,
      () => service.settle(accountId: 'foreign', note: '不应保存'),
    );
    expect(await service.computeNet(), 500);
  });

  test('外层事务主动中止会回滚账户币种及账单两个金额和所有关联记录', () async {
    await _account(db, currency: 'USD');
    await _bill(db, currency: 'USD', accountAmount: 7200, createdAt: 19);
    final before = await _snapshot(db);
    await expectLater(
      db.transaction(() async {
        await _account(db, currency: 'JPY');
        await _bill(db, amount: 1200, currency: 'EUR', accountAmount: 9360);
        await _bill(db, id: 'new', accountId: 'foreign', currency: 'JPY');
        await db.setMeta('currency-abort', '不应保留');
        throw StateError('主动中止外层事务');
      }),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '主动中止外层事务',
        ),
      ),
    );
    expect(await _snapshot(db), before);
  });
}
