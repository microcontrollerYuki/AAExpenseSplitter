import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';

import '../helpers/test_support.dart';

Future<void> _account(
  AppDatabase db,
  String id, {
  String name = '旅行账户',
  String? currency,
  int type = 3,
  int initBalance = 0,
  Account? expected,
}) => db.upsertAccount(
  id: id,
  name: name,
  emoji: '💳',
  type: type,
  initBalance: initBalance,
  includeNetWorth: true,
  sort: 20,
  currency: currency,
  expected: expected,
);

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
  'metaEntries': {
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

Future<Object?> _attempt(Future<void> Function() action) async {
  try {
    await action();
    return null;
  } catch (error) {
    return error;
  }
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
  });
  tearDown(() => db.close());

  test('转出或仅转入引用均阻止删除外币账户，包括已软删除账单', () async {
    for (final incomingOnly in [false, true]) {
      for (final deleted in [false, true]) {
        final suffix = '$incomingOnly-$deleted';
        final accountId = 'protected-$suffix';
        final billId = 'bill-$suffix';
        await _account(db, accountId, currency: 'USD');
        if (incomingOnly) {
          await _account(db, 'source-$suffix', currency: 'USD');
        }
        await db.upsertBill(
          id: billId,
          type: incomingOnly ? 2 : 0,
          amount: 1001,
          currency: 'USD',
          accountId: incomingOnly ? 'source-$suffix' : accountId,
          toAccountId: incomingOnly ? accountId : null,
          categoryId: incomingOnly ? null : 'cat_food',
          dateMs: 100,
        );
        if (deleted) await db.softDeleteBill(billId);
        expect(await db.billCountOfAccount(accountId), deleted ? 0 : 1);
        expect(await db.billCountOfAccount(accountId, includeDeleted: true), 1);
        await _rejectWithoutChanges(db, () => db.deleteAccount(accountId));
      }
    }
  });

  test('计数默认仍排除软删除，完整计数包含普通和转入引用', () async {
    await _account(db, 'counted');
    await db.upsertBill(
      id: 'expense',
      type: 0,
      amount: 100,
      accountId: 'counted',
      dateMs: 100,
    );
    for (final id in ['incoming', 'deleted-incoming']) {
      await db.upsertBill(
        id: id,
        type: 2,
        amount: 200,
        accountId: 'acc_cash',
        toAccountId: 'counted',
        dateMs: 100,
      );
    }
    await db.softDeleteBill('deleted-incoming');
    expect(await db.billCountOfAccount('counted'), 2);
    expect(await db.billCountOfAccount('counted', includeDeleted: true), 3);
  });

  test('无引用账户可删，固定AA账户拒删而其他type4无引用可删', () async {
    await _account(db, 'unused-usd', currency: 'USD');
    await _account(db, 'other-aa', type: 4);
    await _account(db, kAaCreditAccountId, type: 4);
    await _rejectWithoutChanges(db, () => db.deleteAccount(kAaCreditAccountId));
    final fixed = (await db.getAccount(kAaCreditAccountId))!;
    expect(fixed.currency, 'CNY');
    await db.deleteAccount('unused-usd');
    await db.deleteAccount('other-aa');
    expect(await db.getAccount('unused-usd'), isNull);
    expect(await db.getAccount('other-aa'), isNull);
    expect(await db.getAccount(kAaCreditAccountId), fixed);
  });

  test('有效账户快照可保存，未引用账户更换币种保持创建时间', () async {
    await _account(db, 'editable', currency: 'USD', initBalance: 123);
    final original = (await db.getAccount('editable'))!;
    await _account(
      db,
      'editable',
      name: '日元旅行账户',
      currency: 'JPY',
      initBalance: 456,
      expected: original,
    );
    final saved = (await db.getAccount('editable'))!;
    expect(saved.name, '日元旅行账户');
    expect(saved.currency, 'JPY');
    expect(saved.initBalance, 456);
    expect(saved.createdAt, original.createdAt);
  });

  test('另一窗口已改币种，旧快照不能覆盖新币种和按旧精度输入的期初额', () async {
    await _account(db, 'editable', currency: 'USD', initBalance: 123);
    final original = (await db.getAccount('editable'))!;
    await _account(db, 'editable', currency: 'JPY', initBalance: 456);
    await _rejectWithoutChanges(
      db,
      () => _account(
        db,
        'editable',
        name: '旧窗口备注',
        currency: 'USD',
        initBalance: 789,
        expected: original,
      ),
    );
    final latest = (await db.getAccount('editable'))!;
    expect(latest.currency, 'JPY');
    expect(latest.initBalance, 456);
  });

  test('完整快照也保护同币种下已修改的名称等字段', () async {
    await _account(db, 'editable', currency: 'USD');
    final original = (await db.getAccount('editable'))!;
    await _account(db, 'editable', name: '另一窗口新名称');
    await _rejectWithoutChanges(
      db,
      () => _account(db, 'editable', name: '旧名称覆盖', expected: original),
    );
    expect((await db.getAccount('editable'))!.name, '另一窗口新名称');
  });

  for (final recreate in [false, true]) {
    test('旧快照不能${recreate ? '覆盖同ID重建账户' : '重建已删除账户'}', () async {
      await _account(db, 'editable', currency: 'USD');
      final original = (await db.getAccount('editable'))!;
      await db.deleteAccount('editable');
      if (recreate) {
        await _account(db, 'editable', name: '同ID新账户', currency: 'JPY');
      }
      await _rejectWithoutChanges(
        db,
        () => _account(
          db,
          'editable',
          name: '旧窗口保存',
          currency: 'USD',
          expected: original,
        ),
      );
      if (recreate) {
        expect((await db.getAccount('editable'))!.currency, 'JPY');
      } else {
        expect(await db.getAccount('editable'), isNull);
      }
    });
  }

  test('删除与记账并发只有一方成功，不留悬空账户引用', () async {
    for (final deleteFirst in [true, false]) {
      final accountId = 'racing-$deleteFirst';
      final billId = 'bill-$deleteFirst';
      await _account(db, accountId);
      Future<void> deleteAccount() => db.deleteAccount(accountId);
      Future<void> saveBill() => db.upsertBill(
        id: billId,
        type: 0,
        amount: 529,
        accountId: accountId,
        dateMs: 100,
      );
      final actions = deleteFirst
          ? [deleteAccount, saveBill]
          : [saveBill, deleteAccount];
      final results = await Future.wait([
        for (final action in actions) _attempt(action),
      ]);
      expect(results.where((result) => result == null), hasLength(1));
      expect(
        results.where((result) => result != null).single,
        isA<StateError>(),
      );
      final account = await db.getAccount(accountId);
      final bills = (await db.getAllBills()).where((bill) => bill.id == billId);
      if (account == null) {
        expect(bills, isEmpty);
      } else {
        expect(bills.single.accountId, accountId);
        expect(bills.single.amount, 529);
        expect(bills.single.accountAmount, 529);
      }
    }
  });
}
