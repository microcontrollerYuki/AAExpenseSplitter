import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';

import '../helpers/test_support.dart';

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
  'groups': {
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

Future<void> _rejectUnchanged(
  AppDatabase db,
  Future<void> Function() action,
) async {
  final before = await _snapshot(db);
  await expectLater(action(), throwsStateError);
  expect(await _snapshot(db), before);
}

Future<Bill> _bill(AppDatabase db, [String id = 'bill']) async =>
    (await db.select(db.bills).get()).singleWhere((row) => row.id == id);

Future<void> _writeBill(
  AppDatabase db, {
  String id = 'bill',
  int type = 0,
  int amount = 1001,
  int dateMs = 100,
  String? groupId,
  String? settlementId,
  String? currency,
  int? accountAmount,
  String note = '原始备注',
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  accountId: 'acc_cash',
  categoryId: type == 1 ? 'inc_other' : 'cat_food',
  dateMs: dateMs,
  aaGroupId: groupId,
  settlementId: settlementId,
  currency: currency,
  accountAmount: accountAmount,
  note: note,
  createdAt: 17,
);

Future<void> _group(
  AppDatabase db, {
  String id = 'group',
  int total = 1001,
  bool settled = false,
}) => db.upsertAaGroup(
  AaGroupsCompanion.insert(
    id: id,
    ownerUid: 'me',
    payerUid: 'me',
    totalAmount: total,
    dateMs: 100,
    settled: Value(settled),
    settlementId: Value(settled ? 'settlement' : null),
    createdAtMs: 19,
    updatedAtMs: 23,
  ),
);

void main() {
  late TestAppDatabase db;
  late AaSyncService service;

  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
    service = AaSyncService(db);
    await service.setupPairing(
      myName: '本机',
      partnerName: '伙伴',
      secret: 'association-guard-test',
    );
    await db.setMeta('myUid', 'me');
    await db.setMeta('partnerUid', 'partner');
  });
  tearDown(() => db.close());

  for (final settlement in [false, true]) {
    for (final replacement in [null, 'another-relation']) {
      test(
        '${settlement ? '结算' : '未结算AA'}不能先${replacement == null ? '清空' : '换绑'}关联再改外币',
        () async {
          if (settlement) {
            await db.upsertSettlement(
              SettlementsCompanion.insert(
                id: 'settlement',
                receiverUid: 'me',
                amount: 1001,
                dateMs: 100,
                cutoffMs: 100,
                createdAtMs: 19,
              ),
            );
          } else {
            await _group(db);
          }
          await _writeBill(
            db,
            type: settlement ? 1 : 0,
            groupId: settlement ? null : 'group',
            settlementId: settlement ? 'settlement' : null,
          );
          await _rejectUnchanged(
            db,
            () => _writeBill(
              db,
              type: settlement ? 1 : 0,
              groupId: settlement ? null : replacement,
              settlementId: settlement ? replacement : null,
              note: '第一步不应清关联',
            ),
          );
          await _rejectUnchanged(
            db,
            () => _writeBill(
              db,
              type: settlement ? 1 : 0,
              currency: 'USD',
              accountAmount: 7200,
              groupId: settlement ? null : 'group',
              settlementId: settlement ? 'settlement' : null,
              note: '第二步不应转外币',
            ),
          );
        },
      );
    }
  }

  test('历史仅isAa标志的账单不能经普通upsert丢失标志', () async {
    await _writeBill(db);
    await (db.update(db.bills)..where((row) => row.id.equals('bill'))).write(
      const BillsCompanion(isAa: Value(true)),
    );
    await _rejectUnchanged(db, () => _writeBill(db, note: '不能清标志'));
    final row = await _bill(db);
    expect(row.isAa, isTrue);
    expect(row.aaGroupId, isNull);
  });

  test('AA快捷关联拒绝重绑及历史孤立isAa，同组调用保持幂等', () async {
    await _group(db);
    await _writeBill(db, groupId: 'group');
    await _rejectUnchanged(
      db,
      () => db.linkBillToAaGroup('bill', 'another-group'),
    );
    final before = await _snapshot(db);
    await db.linkBillToAaGroup('bill', 'group');
    expect(await _snapshot(db), before);
    await _writeBill(db, id: 'orphan');
    await (db.update(db.bills)..where((row) => row.id.equals('orphan'))).write(
      const BillsCompanion(isAa: Value(true)),
    );
    await _rejectUnchanged(db, () => db.linkBillToAaGroup('orphan', 'group'));
  });

  test('服务重复创建AA组被拒绝，事务回滚不留下新组或改写原关联', () async {
    await _writeBill(db);
    Future<void> create() => service.createAaBillFor(
      billId: 'bill',
      totalAmount: 1001,
      dateMs: 100,
      note: '原始备注',
      categoryName: '餐饮',
      categoryEmoji: '🍜',
    );
    await create();
    final original = await _bill(db);
    await _rejectUnchanged(db, create);
    expect(await db.getAllAaGroups(), hasLength(1));
    expect((await _bill(db)).aaGroupId, original.aaGroupId);
    expect(await service.computeNet(), 500);
  });

  test('已结算原始AA不能通过快捷更新金额日期或直接unlink绕过保护', () async {
    await _group(db);
    await _writeBill(db, groupId: 'group');
    await service.settle(accountId: 'acc_cash');
    final beforeNet = await service.computeNet();
    expect(beforeNet, 0);
    for (final action in <Future<void> Function()>[
      () => db.updateBillAmount('bill', 2468),
      () => db.updateBillAmountAndDate('bill', 2468, 200),
      () => db.unlinkBillFromAaGroup('bill'),
    ]) {
      await _rejectUnchanged(db, action);
      expect(await service.computeNet(), beforeNet);
    }
  });

  test('结算收支快捷金额更新被拒绝，本机账户和备注仍可编辑', () async {
    await _writeBill(db, type: 1, settlementId: 'settlement');
    for (final action in <Future<void> Function()>[
      () => db.updateBillAmount('bill', 2468),
      () => db.updateBillAmountAndDate('bill', 2468, 200),
    ]) {
      await _rejectUnchanged(db, action);
    }
    final before = await _bill(db);
    expect(
      await db.updateSettlementBillLocalFields(
        billId: 'bill',
        settlementId: 'settlement',
        accountId: 'acc_bank',
        note: '本机备注可更新',
      ),
      isTrue,
    );
    final after = await _bill(db);
    expect(after.toJson(), {
      ...before.toJson(),
      'accountId': 'acc_bank',
      'note': '本机备注可更新',
      'updatedAt': after.updatedAt,
    });
  });

  test('既有结算收支保留原关联也不能经upsert改金额日期或类型', () async {
    await _writeBill(db, type: 1, settlementId: 'settlement');
    for (final action in <Future<void> Function()>[
      () => _writeBill(db, type: 1, amount: 2468, settlementId: 'settlement'),
      () => _writeBill(db, type: 1, dateMs: 200, settlementId: 'settlement'),
      () => _writeBill(db, type: 0, settlementId: 'settlement'),
    ]) {
      await _rejectUnchanged(db, action);
    }
  });

  test('专用取消AA保留墓碑，原始账转普通后可明确保存外币实扣', () async {
    await _writeBill(db);
    await service.createAaBillFor(
      billId: 'bill',
      totalAmount: 1001,
      dateMs: 100,
      note: '原始备注',
      categoryName: '餐饮',
      categoryEmoji: '🍜',
    );
    final groupId = (await db.getAllAaGroups()).single.id;
    await service.cancelAaGroup(groupId: groupId);
    final cancelled = (await db.getAaGroup(groupId))!;
    final ordinary = await _bill(db);
    expect(cancelled.status, 3);
    expect(ordinary.isAa, isFalse);
    expect(ordinary.aaGroupId, isNull);
    expect(ordinary.deletedAt, isNull);
    await _writeBill(db, currency: 'USD', accountAmount: 7200);
    final foreign = await _bill(db);
    expect(foreign.currency, 'USD');
    expect(foreign.amount, 1001);
    expect(foreign.accountAmount, 7200);
    expect(foreign.isAa, isFalse);
    expect(foreign.aaGroupId, isNull);
    expect(foreign.createdAt, ordinary.createdAt);
    expect(await db.getAaGroup(groupId), cancelled);
    expect(await service.computeNet(), 0);
  });

  test('未结算AA原始编辑与份额快捷同步继续保留关联和双金额', () async {
    await _group(db);
    await _writeBill(db, groupId: 'group');
    await db.transaction(() async {
      await _writeBill(db, amount: 2469, groupId: 'group', note: '合法修改');
      await service.ownerUpdatedAaGroup(
        groupId: 'group',
        newTotal: 2469,
        dateMs: 100,
        note: '合法修改',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );
    });
    expect((await db.getAaGroup('group'))!.totalAmount, 2469);
    final edited = await _bill(db);
    expect(edited.amount, 2469);
    expect(edited.accountAmount, 2469);
    expect(edited.aaGroupId, 'group');
    await db.updateBillAmount('bill', 1234);
    await db.updateBillAmountAndDate('bill', 1357, 200);
    final after = await _bill(db);
    expect(after.amount, 1357);
    expect(after.accountAmount, 1357);
    expect(after.dateMs, 200);
    expect(after.aaGroupId, 'group');
    expect(after.isAa, isTrue);
    expect(after.createdAt, 17);
    expect(after.toAccountAmount, isNull);
  });

  test('开库份额修复保留已结算历史及时间戳，未结算奇数份额仍可修正', () async {
    await _group(db, id: 'settled-group', total: 10001);
    await _writeBill(
      db,
      id: 'settled-share',
      type: 1,
      amount: 5001,
      groupId: 'settled-group',
    );
    await _group(db, id: 'settled-group', total: 10001, settled: true);
    final before = await _snapshot(db);
    await db.normalizeAaShareAmounts();
    expect(await _snapshot(db), before);
    await _group(db, total: 10001);
    await _writeBill(
      db,
      id: 'pending-share',
      type: 1,
      amount: 5001,
      groupId: 'group',
    );
    final settledBefore = await _bill(db, 'settled-share');
    await db.normalizeAaShareAmounts();
    expect(await _bill(db, 'settled-share'), settledBefore);
    final pending = await _bill(db, 'pending-share');
    expect(pending.amount, 5000);
    expect(pending.accountAmount, 5000);
    expect(pending.aaGroupId, 'group');
  });
}
