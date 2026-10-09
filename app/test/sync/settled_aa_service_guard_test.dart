import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';

import '../helpers/test_support.dart';

const _settledMessage = '该 AA 账单已结算，不能再修改';

Matcher get _settledError => throwsA(
      isA<StateError>().having((e) => e.message, 'message', _settledMessage),
    );

Future<Map<String, Object?>> _businessRows(AppDatabase db) async => {
      'bills': {
        for (final b in await db.select(db.bills).get()) b.id: b.toJson(),
      },
      'groups': {
        for (final g in await db.getAllAaGroups()) g.id: g.toJson(),
      },
      'settlements': {
        for (final s in await db.getAllSettlements()) s.id: s.toJson(),
      },
    };

/// 原始支出：本人垫付为全额；伙伴垫付覆盖旧版保留的本机份额账单。
Future<({Bill bill, AaGroup group})> _seedOriginal(
  AppDatabase db,
  AaSyncService service, {
  bool iAmOwner = true,
}) async {
  await service.setupPairing(
    myName: '本机',
    partnerName: '伙伴',
    secret: 'settled-guard-test',
  );
  await db.setMeta('partnerUid', 'partner-uid');
  if (iAmOwner) {
    await db.upsertBill(
      id: 'original-bill',
      type: 0,
      amount: 10001,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1000,
      note: '原始 AA 支出',
      createdAt: 123,
    );
    await service.createAaBillFor(
      billId: 'original-bill',
      totalAmount: 10001,
      dateMs: 1000,
      note: '原始 AA 支出',
      categoryName: '餐饮',
      categoryEmoji: '🍜',
    );
  } else {
    await db.upsertAaGroup(AaGroupsCompanion.insert(
      id: 'partner-original-group',
      ownerUid: 'partner-uid',
      payerUid: 'partner-uid',
      totalAmount: 10001,
      dateMs: 1000,
      note: const Value('伙伴 AA 支出'),
      categoryName: const Value('餐饮'),
      categoryEmoji: const Value('🍜'),
      status: const Value(1),
      createdAtMs: 123,
      updatedAtMs: 123,
    ));
    await db.upsertBill(
      id: 'original-bill',
      type: 0,
      amount: 5000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1000,
      note: '旧版 AA 份额',
      createdAt: 123,
      aaGroupId: 'partner-original-group',
    );
  }
  return (
    bill: (await db.getAllBills()).single,
    group: (await db.getAllAaGroups()).single,
  );
}

Future<void> _rewriteOriginal(
  AppDatabase db,
  Bill oldSnapshot, {
  String? aaGroupId,
}) =>
    db.upsertBill(
      id: oldSnapshot.id,
      type: 0,
      amount: 25001,
      categoryId: 'cat_food',
      accountId: 'acc_wechat',
      dateMs: 2000,
      note: '旧页面试图改写',
      createdAt: oldSnapshot.createdAt,
      aaGroupId: aaGroupId,
    );

void main() {
  late TestAppDatabase db;
  late AaSyncService service;

  setUp(() async {
    db = TestAppDatabase();
    service = AaSyncService(db);
    await db.getAllAccounts();
  });

  tearDown(() => db.close());

  for (final iAmOwner in [true, false]) {
    final perspective = iAmOwner ? '本人垫付' : '伙伴垫付旧版份额';

    test('$perspective：真实结算后服务拒绝陈旧确认、状态修改、重发及取消', () async {
      final old = await _seedOriginal(db, service, iAmOwner: iAmOwner);
      expect(old.group.settled, isFalse);
      await service.settle(accountId: 'acc_cash');
      final settled = (await db.getAaGroup(old.group.id))!;
      expect(settled.settled, isTrue);
      expect(settled.settlementId, isNotNull);
      expect(await db.getAllSettlements(), hasLength(1));
      final before = await _businessRows(db);

      final attempts = <String, Future<void> Function()>{
        '旧 AaGroup 快照确认': () => service.confirmShare(group: old.group),
        '修改待确认': () => service.setGroupStatus(old.group.id, 0),
        '退回': () => service.setGroupStatus(old.group.id, 2, reason: '不能退回'),
        '取消状态': () => service.setGroupStatus(old.group.id, 3),
        '修改共享字段': () => service.ownerUpdatedAaGroup(
              groupId: old.group.id,
              newTotal: 25001,
              dateMs: 2000,
              note: '不能重发',
              categoryName: '购物',
              categoryEmoji: '🛍️',
            ),
        '取消 AA': () => service.cancelAaGroup(groupId: old.group.id),
      };
      for (final attempt in attempts.entries) {
        await expectLater(attempt.value(), _settledError,
            reason: attempt.key);
        expect(await _businessRows(db), before, reason: attempt.key);
        expect(await service.computeNet(), 0);
      }
    });

    test('$perspective：DAO 读取最新关联，拒绝旧快照保存、清空关联及删除', () async {
      final old = await _seedOriginal(db, service, iAmOwner: iAmOwner);
      await service.settle(accountId: 'acc_cash');
      final before = await _businessRows(db);

      for (final requestedGroup in [old.group.id, null, 'another-group']) {
        await expectLater(
          _rewriteOriginal(db, old.bill, aaGroupId: requestedGroup),
          _settledError,
          reason: '传入关联：$requestedGroup',
        );
        expect(await _businessRows(db), before);
      }
      await expectLater(db.softDeleteBill(old.bill.id), _settledError);
      expect(await _businessRows(db), before);
    });
  }

  test('未结算原始 AA 修改、确认、退回、取消继续生效', () async {
    final old = await _seedOriginal(db, service);
    await service.setGroupStatus(old.group.id, 1);
    await db.upsertBill(
      id: 'legacy-receivable',
      type: 1,
      amount: 5000,
      accountId: 'acc_cash',
      dateMs: 1000,
      aaGroupId: old.group.id,
    );
    await db.transaction(() async {
      await _rewriteOriginal(db, old.bill, aaGroupId: old.group.id);
      await service.ownerUpdatedAaGroup(
        groupId: old.group.id,
        newTotal: 25001,
        dateMs: 2000,
        note: '正常重发',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );
    });
    var group = (await db.getAaGroup(old.group.id))!;
    expect(group.totalAmount, 25001);
    expect(group.dateMs, 2000);
    expect(group.note, '正常重发');
    expect(group.status, 0);
    expect(group.statusByUid, isNull);
    expect(group.settled, isFalse);
    var rows = await db.select(db.bills).get();
    expect(rows.firstWhere((b) => b.id == old.bill.id).amount, 25001);
    expect(rows.firstWhere((b) => b.id == 'legacy-receivable').deletedAt,
        isNotNull);

    await service.confirmShare(group: group);
    expect((await db.getAaGroup(group.id))!.status, 1);
    await service.setGroupStatus(group.id, 2, reason: '正常退回');
    group = (await db.getAaGroup(group.id))!;
    expect(group.status, 2);
    expect(group.statusNote, '正常退回');
    await service.cancelAaGroup(groupId: group.id);
    expect((await db.getAaGroup(group.id))!.status, 3);
    rows = await db.select(db.bills).get();
    final original = rows.firstWhere((b) => b.id == old.bill.id);
    expect(original.aaGroupId, isNull);
    expect(original.isAa, isFalse);
    expect(original.amount, 25001);
    expect(original.deletedAt, isNull);
    expect(await db.getAllSettlements(), isEmpty);
  });

  test('服务拒绝已结算组会回滚外层事务先写的账单及结算变更', () async {
    final old = await _seedOriginal(db, service);
    final before = await _businessRows(db);
    await expectLater(
      db.transaction(() async {
        await _rewriteOriginal(db, old.bill, aaGroupId: old.group.id);
        // 模拟保存流程后半段遇到已结算状态；拒绝必须撤回前半段写入。
        await db.upsertSettlement(SettlementsCompanion.insert(
          id: 'temporary-settlement',
          receiverUid: old.group.ownerUid,
          amount: 5000,
          dateMs: 3000,
          cutoffMs: 3000,
          createdAtMs: 3000,
        ));
        await db.markGroupsSettled([old.group.id], 'temporary-settlement', 3000);
        await service.ownerUpdatedAaGroup(
          groupId: old.group.id,
          newTotal: 25001,
          dateMs: 2000,
          note: '不能留下部分写入',
          categoryName: '餐饮',
          categoryEmoji: '🍜',
        );
      }),
      _settledError,
    );
    expect(await _businessRows(db), before);
  });

  test('不存在的分摊组仍保持无操作', () async {
    final before = await _businessRows(db);
    await service.setGroupStatus('missing-group', 1);
    await service.cancelAaGroup(groupId: 'missing-group');
    await service.ownerUpdatedAaGroup(
      groupId: 'missing-group',
      newTotal: 100,
      dateMs: 1,
      note: '',
      categoryName: '餐饮',
      categoryEmoji: '🍜',
    );
    expect(await _businessRows(db), before);
  });
}
