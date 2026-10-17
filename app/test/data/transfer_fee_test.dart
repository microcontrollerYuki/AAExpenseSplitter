import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/balance.dart';
import 'package:aa_expense_splitter/utils/report.dart';

import '../helpers/test_support.dart';

const _parentId = 'transfer';
const _feeId = 'transfer_fee:transfer';

Future<Bill> _bill(AppDatabase db, [String id = _parentId]) async =>
    (await db.select(db.bills).get()).singleWhere((b) => b.id == id);

Future<void> _account(
  AppDatabase db,
  String id,
  String currency, {
  int initial = 0,
  int type = 3,
}) => db.upsertAccount(
  id: id,
  name: id,
  emoji: '💳',
  type: type,
  initBalance: initial,
  includeNetWorth: true,
  sort: 20,
  currency: currency,
);

Future<void> _save(
  AppDatabase db, {
  String id = _parentId,
  String source = 'acc_cash',
  String target = 'acc_bank',
  int amount = 1000,
  int incoming = 1000,
  int feeAmount = 25,
  String? category = 'cat_food',
  int date = 1234567890000,
  String note = '本金备注',
  Bill? parent,
  Bill? fee,
  Account? sourceSnapshot,
  Account? targetSnapshot,
}) async => db.saveTransferWithFee(
  id: id,
  amount: amount,
  toAccountAmount: incoming,
  dateMs: date,
  note: note,
  feeAmount: feeAmount,
  feeCategoryId: category,
  expectedSource: sourceSnapshot ?? (await db.getAccount(source))!,
  expectedTarget: targetSnapshot ?? (await db.getAccount(target))!,
  expectedTransfer: parent,
  expectedFee: fee,
);

// Raw rows include every column, soft-deleted rows and both owner fields.
// A failed request must preserve all six tables, not just the transfer pair.
Future<Map<String, Object?>> _snapshot(AppDatabase db) async => {
  for (final table in [
    'accounts',
    'bills',
    'categories',
    'aa_groups',
    'settlements',
    'meta_entries',
  ])
    table: [
      for (final row
          in await db
              .customSelect('SELECT * FROM "$table" ORDER BY rowid')
              .get())
        row.data,
    ],
};

Future<void> _reject(
  AppDatabase db,
  Future<void> Function() action, {
  Matcher failure = throwsStateError,
}) async {
  final before = await _snapshot(db);
  await expectLater(action(), failure);
  expect(await _snapshot(db), before);
}

Future<Map<String, BigInt>> _balances(AppDatabase db) async =>
    computeExactBalances(await db.getAllAccounts(), await db.getAllBills());

void main() {
  late AppDatabase db;
  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _account(db, 'jpy', 'JPY');
    await db.upsertCategory(
      id: 'internal',
      name: '不计收支专项',
      emoji: '🤝',
      kind: 2,
      sort: 99,
    );
  });
  tearDown(() => db.close());

  for (final scenario in [
    (
      name: '人民币同币',
      source: 'acc_cash',
      target: 'acc_bank',
      code: 'CNY',
      amount: 1000,
      incoming: 1000,
      fee: 25,
    ),
    (
      name: '人民币转美元',
      source: 'acc_cash',
      target: 'usd',
      code: 'CNY',
      amount: 7200,
      incoming: 1000,
      fee: 123,
    ),
    (
      name: '日元转美元',
      source: 'jpy',
      target: 'usd',
      code: 'JPY',
      amount: 1531,
      incoming: 1000,
      fee: 7,
    ),
  ]) {
    test('${scenario.name}本金与手续费独立持久化且精确动账', () async {
      await _save(
        db,
        source: scenario.source,
        target: scenario.target,
        amount: scenario.amount,
        incoming: scenario.incoming,
        feeAmount: scenario.fee,
      );
      final parent = await _bill(db);
      final fee = (await db.getTransferFee(_parentId))!;
      expect(
        [
          parent.type,
          parent.currency,
          parent.amount,
          parent.accountAmount,
          parent.toAccountAmount,
        ],
        [2, scenario.code, scenario.amount, scenario.amount, scenario.incoming],
      );
      expect(parent.feeTransferId, isNull);
      expect(
        [
          fee.id,
          fee.type,
          fee.currency,
          fee.amount,
          fee.accountAmount,
          fee.accountId,
          fee.categoryId,
          fee.dateMs,
          fee.note,
        ],
        [
          _feeId,
          0,
          scenario.code,
          scenario.fee,
          scenario.fee,
          scenario.source,
          'cat_food',
          parent.dateMs,
          '本金备注 · 转账手续费',
        ],
      );
      expect(fee.feeTransferId, parent.id);
      expect(fee.feeDeletedWithTransferAt, isNull);
      expect(fee.toAccountId, isNull);
      expect(fee.toAccountAmount, isNull);
      expect(fee.isAa, isFalse);
      expect(fee.aaGroupId, isNull);
      expect(fee.settlementId, isNull);
      final balances = await _balances(db);
      expect(
        balances[scenario.source],
        -BigInt.from(scenario.amount) - BigInt.from(scenario.fee),
      );
      expect(balances[scenario.target], BigInt.from(scenario.incoming));
      final report = buildReport(
        bills: await db.getAllBills(),
        categories: await db.getAllCategories(),
        filter: ReportFilter(currency: scenario.code),
      );
      expect(report.expense, BigInt.from(scenario.fee));
      expect(report.income, BigInt.zero);
      expect(report.bills.map((b) => b.id), [_feeId]);
    });
  }

  test('零手续费只保存本金，空备注与未分类费用可保存', () async {
    await _save(db, feeAmount: 0);
    expect(await db.getTransferFee(_parentId), isNull);
    expect((await db.getAllBills()).map((b) => b.id), [_parentId]);
    await _save(
      db,
      parent: await _bill(db),
      feeAmount: 1,
      category: null,
      note: '',
    );
    final fee = (await db.getTransferFee(_parentId))!;
    expect(fee.categoryId, isNull);
    expect(fee.note, '转账手续费');
  });

  test('编辑本金日期备注及增减手续费同步两行并保留各自创建时间', () async {
    await _save(db);
    final originalParent = await _bill(db);
    final originalFee = (await db.getTransferFee(_parentId))!;
    for (final amount in [99, 3]) {
      await _save(
        db,
        parent: await _bill(db),
        fee: await db.getTransferFee(_parentId),
        amount: 2000,
        incoming: 2000,
        feeAmount: amount,
        date: 1234567899999,
        note: '更正',
        category: 'cat_transport',
      );
      final parent = await _bill(db);
      final fee = (await db.getTransferFee(_parentId))!;
      expect(
        [parent.amount, parent.accountAmount, parent.toAccountAmount],
        [2000, 2000, 2000],
      );
      expect(
        [fee.amount, fee.accountAmount, fee.dateMs, fee.note, fee.categoryId],
        [amount, amount, parent.dateMs, '更正 · 转账手续费', 'cat_transport'],
      );
      expect(parent.createdAt, originalParent.createdAt);
      expect(fee.createdAt, originalFee.createdAt);
      expect((await _balances(db))['acc_cash'], BigInt.from(-2000 - amount));
    }
  });

  test('取消费用软删原行，重加复用同一ID并清除联删标记', () async {
    await _save(db);
    final first = (await db.getTransferFee(_parentId))!;
    await _save(db, parent: await _bill(db), fee: first, feeAmount: 0);
    final cancelled = (await db.getTransferFee(_parentId))!;
    expect(cancelled.deletedAt, isNotNull);
    expect(cancelled.feeDeletedWithTransferAt, isNull);
    expect((await _balances(db))['acc_cash'], BigInt.from(-1000));
    await _save(db, parent: await _bill(db), fee: cancelled, feeAmount: 7);
    final resumed = (await db.getTransferFee(_parentId))!;
    expect(resumed.id, first.id);
    expect(resumed.createdAt, first.createdAt);
    expect(resumed.deletedAt, isNull);
    expect(resumed.feeDeletedWithTransferAt, isNull);
    expect((await db.select(db.bills).get()).length, 2);
  });

  test('更换出账币种后手续费同步币种与钱包且旧钱包余额归零', () async {
    await _save(db);
    await _save(
      db,
      source: 'usd',
      target: 'jpy',
      amount: 1000,
      incoming: 1531,
      feeAmount: 13,
      parent: await _bill(db),
      fee: await db.getTransferFee(_parentId),
    );
    final fee = (await db.getTransferFee(_parentId))!;
    expect(
      [fee.currency, fee.accountId, fee.amount, fee.accountAmount],
      ['USD', 'usd', 13, 13],
    );
    final balances = await _balances(db);
    expect(balances['acc_cash'], BigInt.zero);
    expect(balances['acc_bank'], BigInt.zero);
    expect(balances['usd'], BigInt.from(-1013));
    expect(balances['jpy'], BigInt.from(1531));
  });

  test('陈旧本金快照即使金额相同也拒绝覆写并保持整库', () async {
    await _save(db);
    for (final field in ['note', 'updated_at']) {
      final parent = await _bill(db);
      final fee = await db.getTransferFee(_parentId);
      await db.customStatement('UPDATE bills SET $field = ? WHERE id = ?', [
        field == 'note' ? '外部改动' : 42,
        _parentId,
      ]);
      await _reject(db, () => _save(db, parent: parent, fee: fee));
    }
  });

  test('陈旧手续费快照包括软删状态与分类变化均拒绝整库不变', () async {
    await _save(db);
    final parent = await _bill(db);
    final fee = await db.getTransferFee(_parentId);
    await db.customStatement('UPDATE bills SET category_id = ? WHERE id = ?', [
      'cat_transport',
      _feeId,
    ]);
    await _reject(db, () => _save(db, parent: parent, fee: fee));
    final changedFee = await db.getTransferFee(_parentId);
    await db.customStatement('UPDATE bills SET deleted_at = 42 WHERE id = ?', [
      _feeId,
    ]);
    await _reject(db, () => _save(db, parent: parent, fee: changedFee));
  });

  test('来源和目标钱包完整快照过期均拒绝，非币种字段同样受保护', () async {
    for (final id in ['acc_cash', 'acc_bank']) {
      final source = (await db.getAccount('acc_cash'))!;
      final target = (await db.getAccount('acc_bank'))!;
      await db.customStatement('UPDATE accounts SET name = ? WHERE id = ?', [
        '外部更名 $id',
        id,
      ]);
      await _reject(
        db,
        () => _save(db, sourceSnapshot: source, targetSnapshot: target),
      );
    }
  });

  test('null期望表示不存在，不能省略已存在的本金或费用快照', () async {
    await _save(db);
    final parent = await _bill(db);
    final fee = await db.getTransferFee(_parentId);
    await _reject(db, () => _save(db, fee: fee));
    await _reject(db, () => _save(db, parent: parent));
    await _reject(db, () => _save(db));
  });

  for (final invalid in ['非转账', 'AA', '结算', '软删除']) {
    test('已有本金为$invalid时拒绝集成费用且六表不变', () async {
      await _save(db);
      final statement = switch (invalid) {
        '非转账' => 'type = 0',
        'AA' => "is_aa = 1, aa_group_id = 'group'",
        '结算' => "settlement_id = 'settlement'",
        _ => 'deleted_at = 42',
      };
      await db.customStatement('UPDATE bills SET $statement WHERE id = ?', [
        _parentId,
      ]);
      await _reject(
        db,
        () async => _save(
          db,
          parent: await _bill(db),
          fee: await db.getTransferFee(_parentId),
        ),
      );
    });
  }

  test('负费用、错误费用分类、自转与AA钱包拒绝且六表不变', () async {
    await _account(db, 'aa', 'CNY', type: 4);
    for (final category in ['inc_salary', 'internal', 'missing']) {
      await _reject(db, () => _save(db, category: category));
    }
    await _reject(db, () => _save(db, feeAmount: -1));
    await _reject(db, () => _save(db, target: 'acc_cash'));
    await _reject(db, () => _save(db, source: 'aa'));
    await _reject(db, () => _save(db, target: 'aa'));
    await _reject(db, () => _save(db, target: 'usd', incoming: 0));
    await _reject(db, () => _save(db, amount: -1, incoming: -1));
  });

  test('异常费用行不得通过最新快照被静默改成合法费用', () async {
    await _save(db);
    for (final statement in [
      'type = 1',
      "settlement_id = 'settlement'",
      "is_aa = 1, aa_group_id = 'group'",
    ]) {
      await db.customStatement(
        'UPDATE bills SET type = 0, is_aa = 0, '
        'aa_group_id = NULL, settlement_id = NULL, $statement WHERE id = ?',
        [_feeId],
      );
      await _reject(
        db,
        () async => _save(
          db,
          parent: await _bill(db),
          fee: await db.getTransferFee(_parentId),
        ),
      );
    }
  });

  test('固定费用ID与无关联普通账单碰撞时不能占用原行', () async {
    await db.upsertBill(
      id: _feeId,
      type: 0,
      amount: 99,
      accountId: 'acc_cash',
      dateMs: 10,
      note: '旁观账单',
    );
    await _reject(db, () => _save(db));
    expect(await db.getTransferFee(_parentId), isNull);
  });

  test('第二行插入被SQLite触发器拒绝时本金也完整回滚', () async {
    await db.customStatement('''
      CREATE TRIGGER reject_fee BEFORE INSERT ON bills
      WHEN NEW.fee_transfer_id IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'fee write rejected'); END
    ''');
    await _reject(db, () => _save(db), failure: throwsException);
    await db.customStatement('DROP TRIGGER reject_fee');
    await _save(db);
    final parent = await _bill(db);
    final fee = await db.getTransferFee(_parentId);
    await db.customStatement('''
      CREATE TRIGGER reject_fee_update BEFORE UPDATE ON bills
      WHEN NEW.fee_transfer_id IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'fee update rejected'); END
    ''');
    await _reject(
      db,
      () => _save(
        db,
        parent: parent,
        fee: fee,
        amount: 2000,
        incoming: 2000,
        feeAmount: 99,
        note: '全部回滚',
      ),
      failure: throwsException,
    );
  });

  test('通用收支编辑删除恢复AA入口均不能绕过本金和费用联动', () async {
    await _save(db);
    for (final id in [_parentId, _feeId]) {
      final row = await _bill(db, id);
      final actions = <Future<void> Function()>[
        () => db.upsertBill(
          id: id,
          type: row.type,
          amount: row.amount,
          currency: row.currency,
          accountAmount: row.accountAmount,
          toAccountAmount: row.toAccountAmount,
          accountId: row.accountId,
          toAccountId: row.toAccountId,
          categoryId: row.categoryId,
          dateMs: row.dateMs,
          note: '绕过',
        ),
        () => db.updateBillAmount(id, 12),
        () => db.updateBillAmountAndDate(id, 12, 456),
        () => db.softDeleteBill(id),
        () => db.restoreBill(id),
        () => db.linkBillToAaGroup(id, 'group'),
        () => db.unlinkBillFromAaGroup(id),
      ];
      for (final action in actions) {
        await _reject(db, action);
      }
      await db.customStatement(
        'UPDATE bills SET settlement_id = ? WHERE id = ?',
        ['settlement', id],
      );
      final before = await _snapshot(db);
      expect(
        await db.updateSettlementBillLocalFields(
          billId: id,
          settlementId: 'settlement',
          accountId: 'acc_wechat',
          note: '绕过',
        ),
        isFalse,
      );
      expect(await _snapshot(db), before);
    }
  });

  test('只有联删标记而缺失owner的异常行也不能经通用入口改写', () async {
    const id = 'marker-only';
    await db.upsertBill(
      id: id,
      type: 0,
      amount: 55,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1234567890000,
    );
    await db.customStatement(
      'UPDATE bills SET fee_transfer_id = NULL, '
      'fee_deleted_with_transfer_at = 42 WHERE id = ?',
      [id],
    );
    final row = await _bill(db, id);
    expect(row.feeTransferId, isNull);
    expect(row.feeDeletedWithTransferAt, 42);
    expect(await db.hasTransferFeeAssociation(id), isTrue);
    final actions = <Future<void> Function()>[
      () => db.upsertBill(
        id: id,
        type: row.type,
        amount: row.amount,
        currency: row.currency,
        accountAmount: row.accountAmount,
        categoryId: row.categoryId,
        accountId: row.accountId,
        dateMs: row.dateMs,
        note: '不能清除标记后改写',
      ),
      () => db.updateBillAmount(id, 12),
      () => db.updateBillAmountAndDate(id, 12, 456),
      () => db.softDeleteBill(id),
      () => db.restoreBill(id),
      () => db.linkBillToAaGroup(id, 'group'),
      () => db.unlinkBillFromAaGroup(id),
    ];
    for (final action in actions) {
      await _reject(db, action);
    }
    await db.customStatement(
      'UPDATE bills SET settlement_id = ? WHERE id = ?',
      ['settlement', id],
    );
    final before = await _snapshot(db);
    expect(
      await db.updateSettlementBillLocalFields(
        billId: id,
        settlementId: 'settlement',
        accountId: 'acc_wechat',
        note: '不能经结算入口改写',
      ),
      isFalse,
    );
    expect(await _snapshot(db), before);
  });

  test('联删双行回滚所有余额，重复删除不改戳且恢复只恢复同次费用', () async {
    await _save(db);
    final initialParent = await _bill(db);
    final initialFee = (await db.getTransferFee(_parentId))!;
    await db.softDeleteTransferWithFee(
      expectedTransfer: initialParent,
      expectedFee: initialFee,
    );
    final deletedParent = await _bill(db);
    final deletedFee = (await db.getTransferFee(_parentId))!;
    expect(deletedParent.deletedAt, isNotNull);
    expect(deletedFee.deletedAt, deletedParent.deletedAt);
    expect(deletedFee.feeDeletedWithTransferAt, deletedParent.deletedAt);
    expect((await _balances(db))['acc_cash'], BigInt.zero);
    expect((await _balances(db))['acc_bank'], BigInt.zero);
    final deletedSnapshot = await _snapshot(db);
    await db.softDeleteTransferWithFee(
      expectedTransfer: deletedParent,
      expectedFee: deletedFee,
    );
    expect(await _snapshot(db), deletedSnapshot);
    await db.restoreTransferWithFee(
      expectedTransfer: deletedParent,
      expectedFee: deletedFee,
    );
    final restored = (await db.getTransferFee(_parentId))!;
    expect((await _bill(db)).deletedAt, isNull);
    expect(restored.deletedAt, isNull);
    expect(restored.feeDeletedWithTransferAt, isNull);
    expect(
      [restored.id, restored.amount, restored.createdAt],
      [initialFee.id, initialFee.amount, initialFee.createdAt],
    );
    expect((await _balances(db))['acc_cash'], BigInt.from(-1025));
    expect((await _balances(db))['acc_bank'], BigInt.from(1000));
  });

  test('取消费与父联删恰好同毫秒也不会被撤销恢复误复活', () async {
    await _save(db);
    await _save(
      db,
      parent: await _bill(db),
      fee: await db.getTransferFee(_parentId),
      feeAmount: 0,
    );
    final cancelled = (await db.getTransferFee(_parentId))!;
    await db.softDeleteTransferWithFee(
      expectedTransfer: await _bill(db),
      expectedFee: cancelled,
    );
    // Construct the collision deterministically rather than hoping a clock race
    // happens: identical deletion times, but the cancelled fee has no marker.
    final parent = await _bill(db);
    await db.customStatement(
      'UPDATE bills SET deleted_at = ?, '
      'fee_deleted_with_transfer_at = NULL WHERE id = ?',
      [parent.deletedAt, _feeId],
    );
    final aligned = (await db.getTransferFee(_parentId))!;
    await db.restoreTransferWithFee(
      expectedTransfer: parent,
      expectedFee: aligned,
    );
    expect((await _bill(db)).deletedAt, isNull);
    expect((await db.getTransferFee(_parentId))!.deletedAt, parent.deletedAt);
    expect((await _balances(db))['acc_cash'], BigInt.from(-1000));
    // Historical ownership still blocks the generic mutation path.
    await _reject(db, () => db.updateBillAmount(_parentId, 2000));
    await _reject(db, () => db.restoreBill(_feeId));
  });

  test('唯一关联索引连软删费用也保护，不能插入第二条费用', () async {
    await _save(db);
    await _save(
      db,
      parent: await _bill(db),
      fee: await db.getTransferFee(_parentId),
      feeAmount: 0,
    );
    await _reject(
      db,
      () => db.customStatement(
        '''
      INSERT INTO bills (id, type, amount, currency, account_amount,
        to_account_amount, category_id, account_id, to_account_id,
        date_ms, note, is_aa, aa_group_id, settlement_id, created_at,
        updated_at, deleted_at, fee_transfer_id, fee_deleted_with_transfer_at)
      SELECT 'second-fee', type, amount, currency,
        account_amount, to_account_amount, category_id, account_id,
        to_account_id, date_ms, note, is_aa, aa_group_id, settlement_id,
        created_at, updated_at, deleted_at, fee_transfer_id,
        fee_deleted_with_transfer_at FROM bills WHERE id = ?
    ''',
        [_feeId],
      ),
      failure: throwsException,
    );
  });

  test('int64本金加费用可超界，BigInt余额和报表仍精确且费用只计一次', () async {
    const maximum = 9223372036854775807;
    await _save(db, amount: maximum, incoming: maximum, feeAmount: maximum);
    final balances = await _balances(db);
    expect(balances['acc_cash'], -BigInt.from(maximum) * BigInt.two);
    expect(balances['acc_bank'], BigInt.from(maximum));
    final report = buildReport(
      bills: await db.getAllBills(),
      categories: await db.getAllCategories(),
      filter: ReportFilter(currency: 'CNY'),
    );
    expect(report.expense, BigInt.from(maximum));
    expect(report.expenseBills.map((b) => b.id), [_feeId]);
    expect(report.expenseStats.total, BigInt.from(maximum));
  });

  test('分类删除转移活跃和取消费用时完整保留费用归属及删除标记', () async {
    await db.upsertCategory(
      id: 'fee-category',
      name: '专项手续费',
      emoji: '💳',
      kind: 0,
      sort: 50,
    );
    await _save(db, category: 'fee-category');
    final active = (await db.getTransferFee(_parentId))!;
    await db.deleteCategoryAndReassign(
      expected: await db.previewCategoryDeletion('fee-category'),
      destination: const CategoryDeleteDestination.uncategorized(),
    );
    final reclassified = (await db.getTransferFee(_parentId))!;
    expect(reclassified.toJson(), {...active.toJson(), 'categoryId': null});
    await db.upsertCategory(
      id: 'fee-category-2',
      name: '专项手续费二',
      emoji: '💳',
      kind: 0,
      sort: 51,
    );
    await _save(
      db,
      parent: await _bill(db),
      fee: reclassified,
      category: 'fee-category-2',
      feeAmount: 7,
    );
    await _save(
      db,
      parent: await _bill(db),
      fee: await db.getTransferFee(_parentId),
      feeAmount: 0,
    );
    final cancelled = (await db.getTransferFee(_parentId))!;
    final target = (await db.getAllCategories()).singleWhere(
      (c) => c.id == 'cat_transport',
    );
    await db.deleteCategoryAndReassign(
      expected: await db.previewCategoryDeletion('fee-category-2'),
      destination: CategoryDeleteDestination.existing(target),
    );
    expect((await db.getTransferFee(_parentId))!.toJson(), {
      ...cancelled.toJson(),
      'categoryId': target.id,
    });
  });

  test('历史异常费用AA关联不会被开库份额修复覆写或阻断', () async {
    await _save(db);
    await db.upsertAaGroup(
      AaGroupsCompanion.insert(
        id: 'group',
        ownerUid: 'owner',
        payerUid: 'payer',
        totalAmount: 999,
        dateMs: 100,
        createdAtMs: 100,
        updatedAtMs: 100,
      ),
    );
    await db.customStatement(
      'UPDATE bills SET is_aa = 1, aa_group_id = ? '
      'WHERE id = ?',
      ['group', _feeId],
    );
    final before = await _snapshot(db);
    await db.normalizeAaShareAmounts();
    expect(await _snapshot(db), before);
  });

  test('删除与恢复也校验双行完整快照，不以陈旧快照覆盖外部改动', () async {
    await _save(db);
    final originalParent = await _bill(db);
    final originalFee = await db.getTransferFee(_parentId);
    await db.customStatement('UPDATE bills SET note = ? WHERE id = ?', [
      '外部备注',
      _feeId,
    ]);
    await _reject(
      db,
      () => db.softDeleteTransferWithFee(
        expectedTransfer: originalParent,
        expectedFee: originalFee,
      ),
    );
    await db.softDeleteTransferWithFee(
      expectedTransfer: await _bill(db),
      expectedFee: await db.getTransferFee(_parentId),
    );
    final deletedParent = await _bill(db);
    final deletedFee = await db.getTransferFee(_parentId);
    await db.customStatement('UPDATE bills SET note = ? WHERE id = ?', [
      '外部本金备注',
      _parentId,
    ]);
    await _reject(
      db,
      () => db.restoreTransferWithFee(
        expectedTransfer: deletedParent,
        expectedFee: deletedFee,
      ),
    );
  });

  test('异常删除归属状态的最新快照也不能保存删除或恢复，六表保持不变', () async {
    await _save(db);
    for (final state in [
      // A fee linked to a deletion cannot belong to a live transfer.
      (parentDeleted: null, feeDeleted: 42, marker: 42),
      // Deleting the parent must never leave its fee active.
      (parentDeleted: 42, feeDeleted: null, marker: null),
      // A fee marked by another deletion cannot be adopted by this one.
      (parentDeleted: 42, feeDeleted: 43, marker: 43),
    ]) {
      await db.customStatement('UPDATE bills SET deleted_at = ? WHERE id = ?', [
        state.parentDeleted,
        _parentId,
      ]);
      await db.customStatement(
        'UPDATE bills SET deleted_at = ?, '
        'fee_deleted_with_transfer_at = ? WHERE id = ?',
        [state.feeDeleted, state.marker, _feeId],
      );
      final parent = await _bill(db);
      final fee = await db.getTransferFee(_parentId);
      // Supply the latest rows deliberately: these are structural state
      // failures, rather than stale-snapshot failures.
      await _reject(db, () => _save(db, parent: parent, fee: fee));
      await _reject(
        db,
        () => db.softDeleteTransferWithFee(
          expectedTransfer: parent,
          expectedFee: fee,
        ),
      );
      await _reject(
        db,
        () => db.restoreTransferWithFee(
          expectedTransfer: parent,
          expectedFee: fee,
        ),
      );
    }
  });
}
