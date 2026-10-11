import 'dart:io';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/test_support.dart';

const _secret = 'currency-guard-secret';

void main() {
  late TestAppDatabase db;
  late AaSyncService service;
  late FakePathProvider paths;
  late PathProviderPlatform previousPaths;

  setUp(() async {
    previousPaths = PathProviderPlatform.instance;
    paths = FakePathProvider();
    PathProviderPlatform.instance = paths;
    db = TestAppDatabase();
    await db.getAllAccounts();
    service = AaSyncService(db);
    await service.setupPairing(
      myName: '本机',
      partnerName: '伙伴',
      secret: _secret,
    );
    await db.setMeta('partnerUid', 'partner');
  });

  tearDown(() async {
    await db.close();
    PathProviderPlatform.instance = previousPaths;
    paths.cleanup();
  });

  Future<void> account(String id, String currency, {int type = 0}) =>
      db.upsertAccount(
        id: id,
        name: id,
        emoji: '💰',
        type: type,
        initBalance: 0,
        includeNetWorth: type != 4,
        sort: 90,
        currency: currency,
      );

  Future<void> createAa(String billId, int amount) => service.createAaBillFor(
    billId: billId,
    totalAmount: amount,
    dateMs: 100,
    note: '测试',
    categoryName: '餐饮',
    categoryEmoji: '🍜',
  );

  Future<Map<String, Object?>> snapshot() async => {
    'bills': {
      for (final bill in await db.select(db.bills).get())
        bill.id: bill.toJson(),
    },
    'groups': {
      for (final group in await db.getAllAaGroups()) group.id: group.toJson(),
    },
    'settlements': {
      for (final settlement in await db.getAllSettlements())
        settlement.id: settlement.toJson(),
    },
    'meta': {
      for (final entry in await db.select(db.metaEntries).get())
        entry.key: entry.value,
    },
  };

  Future<File> syncFile({bool withGroup = false}) async {
    final uid = (await db.getMeta('myUid'))!;
    final payload = <String, Object?>{
      'format': 1,
      'fromUid': 'partner',
      'fromName': '伙伴',
      'groups': [
        if (withGroup)
          {
            'id': 'partner-group',
            'ownerUid': uid,
            'payerUid': uid,
            'totalAmount': 1001,
            'dateMs': 100,
            'settled': true,
            'settlementId': 'partner-settlement',
            'createdAtMs': 101,
            'updatedAtMs': 102,
          },
      ],
      'settlements': [
        {
          'id': 'partner-settlement',
          'receiverUid': uid,
          'amount': 500,
          'dateMs': 200,
          'cutoffMs': 200,
          'createdAtMs': 201,
        },
      ],
    };
    final file = File('${paths.tempDir.path}/currency-guard.aas');
    await file.writeAsString(await encryptToAasContent(payload, _secret));
    return file;
  }

  for (final crossCurrency in [false, true]) {
    test('外币普通账单不能关联 AA，拒绝后不留下孤立组（跨币种=$crossCurrency）', () async {
      await account('usd', 'USD');
      await db.upsertBill(
        id: 'foreign-bill',
        type: 0,
        amount: 1000,
        currency: 'USD',
        accountAmount: crossCurrency ? 7200 : 1000,
        accountId: crossCurrency ? 'acc_cash' : 'usd',
        dateMs: 100,
      );
      final before = await snapshot();

      await expectLater(createAa('foreign-bill', 1000), throwsStateError);

      expect(await snapshot(), before);
      expect(await db.getAllAaGroups(), isEmpty);
      final bill = (await db.getAllBills()).single;
      expect(bill.isAa, isFalse);
      expect(bill.aaGroupId, isNull);
    });
  }

  test('无效、外币和两种 AA 挂账账户不能结算，组 / 账单 / 偏好均不变', () async {
    await account('usd', 'USD');
    await account('other-aa', 'CNY', type: 4);
    final uid = (await db.getMeta('myUid'))!;
    await db.upsertAaGroup(
      AaGroupsCompanion.insert(
        id: 'group',
        ownerUid: uid,
        payerUid: uid,
        totalAmount: 1001,
        dateMs: 100,
        createdAtMs: 101,
        updatedAtMs: 102,
      ),
    );
    await db.setMeta(AaSyncService.kAaSettleAccountKey, 'acc_cash');
    final before = await snapshot();

    for (final accountId in [
      'missing',
      'usd',
      kAaCreditAccountId,
      'other-aa',
    ]) {
      await expectLater(
        service.settle(accountId: accountId),
        throwsStateError,
        reason: accountId,
      );
      expect(await snapshot(), before, reason: accountId);
      expect(await service.computeNet(), 500);
    }
  });

  test('CNY AA 创建和结算保持奇数分口径，原账与结算账双金额一致', () async {
    await db.upsertBill(
      id: 'cny-bill',
      type: 0,
      amount: 1001,
      accountId: 'acc_cash',
      dateMs: 100,
    );
    await createAa('cny-bill', 1001);
    expect(await service.computeNet(), 500);

    await service.settle(accountId: 'acc_cash');

    final bills = await db.getAllBills();
    expect(bills, hasLength(2));
    final original = bills.singleWhere((bill) => bill.id == 'cny-bill');
    final settlement = bills.singleWhere((bill) => bill.settlementId != null);
    expect(original.currency, 'CNY');
    expect(original.amount, 1001);
    expect(original.accountAmount, 1001);
    expect(original.aaGroupId, isNotNull);
    expect(settlement.type, 1);
    expect(settlement.currency, 'CNY');
    expect(settlement.amount, 500);
    expect(settlement.accountAmount, 500);
    expect(settlement.accountId, 'acc_cash');
    expect(await service.computeNet(), 0);

    final before = await snapshot();
    await service.settle(accountId: 'acc_cash');
    expect(await snapshot(), before);
  });

  for (final withGroup in [false, true]) {
    test('旧 CNY 文件在仅有外币 / AA 账户时暂缓，添加 CNY 后重导补录（组=$withGroup）', () async {
      for (final item in await db.getAllAccounts()) {
        if (item.id != kAaCreditAccountId) await db.deleteAccount(item.id);
      }
      await account('usd', 'USD');
      await account('other-aa', 'CNY', type: 4);
      await db.setMeta(AaSyncService.kAaSettleAccountKey, 'usd');
      final file = await syncFile(withGroup: withGroup);

      await service.importSyncFile(file.path);

      expect(await db.getAllBills(), isEmpty);
      expect(await db.getAllSettlements(), hasLength(1));
      expect(await db.getAllAaGroups(), hasLength(withGroup ? 1 : 0));
      await account('cny', 'CNY');

      await service.importSyncFile(file.path);

      final bill = (await db.getAllBills()).single;
      expect(bill.accountId, 'cny');
      expect(bill.currency, 'CNY');
      expect(bill.amount, 500);
      expect(bill.accountAmount, 500);
      expect(bill.type, 1);
      expect(bill.dateMs, withGroup ? 100 : 200);
      expect(bill.settlementId, 'partner-settlement');
      await service.importSyncFile(file.path);
      expect((await db.getAllBills()).single, bill);
      expect(await db.getAllSettlements(), hasLength(1));
    });
  }

  test('导入结算的账户偏好指向 AA 挂账时回退到真实 CNY', () async {
    await db.setMeta(AaSyncService.kAaSettleAccountKey, kAaCreditAccountId);
    final file = await syncFile();

    await service.importSyncFile(file.path);

    final bill = (await db.getAllBills()).single;
    expect(bill.accountId, 'acc_cash');
    expect(bill.currency, 'CNY');
    expect(bill.amount, 500);
    expect(bill.accountAmount, 500);
  });

  test('普通外币账单保留本地，旧 AA 导出仅包含 CNY AA 组', () async {
    await account('usd', 'USD');
    await db.upsertBill(
      id: 'foreign-bill',
      type: 0,
      amount: 4444,
      accountId: 'usd',
      currency: 'USD',
      accountAmount: 4444,
      dateMs: 100,
    );
    await db.upsertBill(
      id: 'cny-bill',
      type: 0,
      amount: 1001,
      accountId: 'acc_cash',
      dateMs: 100,
    );
    await createAa('cny-bill', 1001);

    final path = await service.exportSyncFile();
    final payload = await decryptAasContent(
      await File(path).readAsString(),
      _secret,
    );

    expect(payload['format'], 1);
    final groups = payload['groups'] as List;
    expect(groups, hasLength(1));
    expect((groups.single as Map)['totalAmount'], 1001);
    expect(payload['settlements'], isEmpty);
    expect(payload.containsKey('bills'), isFalse);
    final foreign = (await db.getAllBills()).singleWhere(
      (bill) => bill.id == 'foreign-bill',
    );
    expect(foreign.currency, 'USD');
    expect(foreign.amount, 4444);
    expect(foreign.accountAmount, 4444);
    expect(foreign.aaGroupId, isNull);
  });
}
