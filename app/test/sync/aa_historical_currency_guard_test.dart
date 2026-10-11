import 'dart:io';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/test_support.dart';

const _secret = 'historical-currency-guard';

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
    await db.upsertAccount(
      id: 'usd',
      name: '美元',
      emoji: '💵',
      type: 3,
      initBalance: 0,
      includeNetWorth: true,
      sort: 90,
      currency: 'USD',
    );
  });

  tearDown(() async {
    await db.close();
    PathProviderPlatform.instance = previousPaths;
    paths.cleanup();
  });

  Future<Map<String, Object?>> snapshot() async => {
    'bills': {
      for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
    },
    'accounts': {
      for (final row in await db.getAllAccounts()) row.id: row.toJson(),
    },
    'categories': {
      for (final row in await db.getAllCategories()) row.id: row.toJson(),
    },
    'groups': {
      for (final row in await db.getAllAaGroups()) row.id: row.toJson(),
    },
    'settlements': {
      for (final row in await db.getAllSettlements()) row.id: row.toJson(),
    },
    'meta': {
      for (final row in await db.select(db.metaEntries).get())
        row.key: row.value,
    },
  };

  Future<void> group({String id = 'local-group', bool partner = false}) async {
    final uid = partner ? 'partner' : (await db.getMeta('myUid'))!;
    await db.upsertAaGroup(
      AaGroupsCompanion.insert(
        id: id,
        ownerUid: uid,
        payerUid: uid,
        totalAmount: 1001,
        dateMs: 100,
        createdAtMs: 101,
        updatedAtMs: 200,
      ),
    );
  }

  Future<void> settlement({String id = 'local-settlement'}) async {
    await db.upsertSettlement(
      SettlementsCompanion.insert(
        id: id,
        receiverUid: (await db.getMeta('myUid'))!,
        amount: 500,
        dateMs: 300,
        cutoffMs: 300,
        createdAtMs: 301,
      ),
    );
  }

  Future<void> linkedBill({bool settled = false}) => db.upsertBill(
    id: 'linked',
    type: settled ? 1 : 0,
    amount: 1001,
    accountId: 'acc_cash',
    dateMs: 100,
    aaGroupId: settled ? null : 'local-group',
    settlementId: settled ? 'local-settlement' : null,
  );

  Future<void> makeForeign({bool deleted = false}) => db.customStatement(
    'UPDATE bills SET currency = ?, account_id = ?, account_amount = ?, '
    'deleted_at = ? WHERE id = ?',
    ['USD', 'usd', 1001, deleted ? 400 : null, 'linked'],
  );

  Future<File> incoming({
    List<Map<String, Object?>> groups = const [],
    List<Map<String, Object?>> settlements = const [],
    bool legacy = false,
  }) async {
    final payload = <String, Object?>{
      if (!legacy) 'format': 1,
      'fromUid': 'partner',
      'fromName': '新伙伴名称',
      'groups': groups,
      'settlements': settlements,
    };
    final file = File('${paths.tempDir.path}/incoming.aas');
    await file.writeAsString(await encryptToAasContent(payload, _secret));
    return file;
  }

  Map<String, Object?> incomingGroup({
    String id = 'local-group',
    int updatedAt = 100,
  }) => {
    'id': id,
    'ownerUid': 'partner',
    'payerUid': 'partner',
    'totalAmount': 1001,
    'dateMs': 100,
    'createdAtMs': 101,
    'updatedAtMs': updatedAt,
  };

  Future<Map<String, Object?>> incomingSettlement({
    String id = 'local-settlement',
  }) async => {
    'id': id,
    'receiverUid': (await db.getMeta('myUid'))!,
    'amount': 500,
    'dateMs': 300,
    'cutoffMs': 300,
    'createdAtMs': 301,
  };

  Future<void> rejectsUnchanged(Future<dynamic> Function() action) async {
    final before = await snapshot();
    final files = paths.tempDir.listSync().map((f) => f.path).toSet();
    await expectLater(action(), throwsStateError);
    expect(await snapshot(), before);
    expect(paths.tempDir.listSync().map((f) => f.path).toSet(), files);
  }

  test('导出拒绝历史外币 AA 关联，不创建文件或更新同步时间', () async {
    await group();
    await linkedBill();
    await makeForeign();
    await rejectsUnchanged(service.exportSyncFile);
  });

  test('导出拒绝 CNY 交易挂在外币账户上的历史 AA 账单', () async {
    await group();
    await linkedBill();
    await db.customStatement(
      'UPDATE bills SET account_id = ?, account_amount = ? WHERE id = ?',
      ['usd', 140, 'linked'],
    );
    await rejectsUnchanged(service.exportSyncFile);
  });

  test('导出拒绝历史 CNY AA 原币与实际额不一致', () async {
    await group();
    await linkedBill();
    await db.customStatement(
      'UPDATE bills SET account_amount = ? WHERE id = ?',
      [999, 'linked'],
    );
    await rejectsUnchanged(service.exportSyncFile);
  });

  test('导出拒绝历史 AA 转账及普通账单残留的转入字段', () async {
    await group();
    await linkedBill();
    // 独立覆盖 type、toAccountId、toAccountAmount，不能只靠类型判断。
    for (final fields in [
      [2, null, null],
      [0, 'acc_wechat', null],
      [0, null, 1001],
    ]) {
      await db.customStatement(
        'UPDATE bills SET type = ?, to_account_id = ?, to_account_amount = ? '
        'WHERE id = ?',
        [...fields, 'linked'],
      );
      await rejectsUnchanged(service.exportSyncFile);
    }
  });

  test('导出不会因账单软删除而放过历史外币结算关联', () async {
    await settlement();
    await linkedBill(settled: true);
    await makeForeign(deleted: true);
    await rejectsUnchanged(service.exportSyncFile);
  });

  test('导出遇到历史 AA 缺失账户时待确认，不猜币种', () async {
    await group();
    await linkedBill();
    await db.customStatement('UPDATE bills SET account_id = ? WHERE id = ?', [
      'missing',
      'linked',
    ]);
    await rejectsUnchanged(service.exportSyncFile);
  });

  for (final deleted in [false, true]) {
    test('结算拒绝历史外币关联组，核销与落账均回滚（软删除=$deleted）', () async {
      await group();
      await linkedBill();
      await makeForeign(deleted: deleted);
      await rejectsUnchanged(() => service.settle(accountId: 'acc_cash'));
      expect((await db.getAaGroup('local-group'))!.settled, isFalse);
      expect(await db.getAllSettlements(), isEmpty);
    });
  }

  test('导入陈旧组也检查本机历史外币关联，整份导入不留下其他记录或元数据', () async {
    await group(partner: true);
    await linkedBill();
    await makeForeign();
    final file = await incoming(
      groups: [
        incomingGroup(),
        incomingGroup(id: 'new-group', updatedAt: 300),
      ],
      settlements: [await incomingSettlement(id: 'new-settlement')],
    );
    await rejectsUnchanged(() => service.importSyncFile(file.path));
    expect(await db.getAaGroup('new-group'), isNull);
    expect(await db.getSettlement('new-settlement'), isNull);
  });

  test('导入重复结算不会把软删除外币结算账单当作已完成 CNY 落账', () async {
    await settlement();
    await linkedBill(settled: true);
    await makeForeign(deleted: true);
    final file = await incoming(settlements: [await incomingSettlement()]);
    await rejectsUnchanged(() => service.importSyncFile(file.path));
  });

  test('仅含结算的旧文件也检查经本机已有组间接关联的历史外币账单', () async {
    await group();
    await linkedBill();
    await makeForeign();
    await db.customStatement(
      'UPDATE aa_groups SET settled = 1, settlement_id = ? WHERE id = ?',
      ['local-settlement', 'local-group'],
    );
    // 文件没有重复携带该组，旧导入逻辑仍会依 settlementId 找到本机组落账。
    final file = await incoming(settlements: [await incomingSettlement()]);
    await rejectsUnchanged(() => service.importSyncFile(file.path));
    expect(await db.getAllSettlements(), isEmpty);
    expect(await db.getAllBills(), hasLength(1));
  });

  test('同一文件改金额并结算时先同步未结算份额，两金额一致且重导业务幂等', () async {
    await group(partner: true);
    await linkedBill();
    await db.customStatement(
      'UPDATE bills SET amount = 500, account_amount = 500 WHERE id = ?',
      ['linked'],
    );
    final file = await incoming(
      groups: [
        {
          ...incomingGroup(updatedAt: 300),
          'totalAmount': 2003,
          'dateMs': 800,
          'settled': true,
          'settlementId': 'local-settlement',
        },
      ],
      settlements: [
        {
          ...(await incomingSettlement()),
          'receiverUid': 'partner',
          'amount': 1001,
        },
      ],
    );

    await service.importSyncFile(file.path);

    final bills = await db.getAllBills();
    expect(bills, hasLength(2));
    final share = bills.singleWhere((b) => b.id == 'linked');
    expect(share.currency, 'CNY');
    expect(share.amount, 1001);
    expect(share.accountAmount, 1001);
    expect(share.dateMs, 800);
    expect(share.aaGroupId, 'local-group');
    final settled = bills.singleWhere((b) => b.settlementId != null);
    expect(settled.settlementId, 'local-settlement');
    expect(settled.type, 0);
    expect(settled.currency, 'CNY');
    expect(settled.amount, 1001);
    expect(settled.accountAmount, 1001);
    expect(settled.dateMs, 800);
    expect((await db.getAaGroup('local-group'))!.settled, isTrue);
    final before = (await snapshot())..remove('meta');

    await service.importSyncFile(file.path);

    expect((await snapshot())..remove('meta'), before);
  });

  test('此前已结算组只合并新元数据，不调用快捷入口改写原份额金额和日期', () async {
    await group(partner: true);
    await linkedBill();
    await db.customStatement(
      'UPDATE bills SET amount = 500, account_amount = 500 WHERE id = ?',
      ['linked'],
    );
    await db.upsertSettlement(
      SettlementsCompanion.insert(
        id: 'local-settlement',
        receiverUid: 'partner',
        amount: 500,
        dateMs: 300,
        cutoffMs: 300,
        createdAtMs: 301,
      ),
    );
    await db.upsertBill(
      id: 'original-settlement-bill',
      type: 0,
      amount: 500,
      accountId: 'acc_cash',
      dateMs: 100,
      settlementId: 'local-settlement',
    );
    await db.customStatement(
      'UPDATE aa_groups SET settled = 1, settlement_id = ? WHERE id = ?',
      ['local-settlement', 'local-group'],
    );
    final originalBills = (await snapshot())['bills'];
    final file = await incoming(
      groups: [
        {
          ...incomingGroup(updatedAt: 300),
          'totalAmount': 2003,
          'dateMs': 800,
          'note': '合并元数据',
          'settled': true,
          'settlementId': 'local-settlement',
        },
      ],
      settlements: [
        {...(await incomingSettlement()), 'receiverUid': 'partner'},
      ],
    );

    // 真实快捷入口会拒绝已结算组；导入成功同时证明未调用该改金额路径。
    await service.importSyncFile(file.path);

    expect((await snapshot())['bills'], originalBills);
    final merged = (await db.getAaGroup('local-group'))!;
    expect(merged.totalAmount, 2003);
    expect(merged.dateMs, 800);
    expect(merged.note, '合并元数据');
    expect(merged.settled, isTrue);
    expect(merged.settlementId, 'local-settlement');
    final before = (await snapshot())..remove('meta');

    await service.importSyncFile(file.path);

    expect((await snapshot())..remove('meta'), before);
  });

  test('两份文件不能先清空结算标记，再借更大更新时间改写历史份额', () async {
    await group(partner: true);
    await linkedBill();
    await db.customStatement(
      'UPDATE bills SET amount = 500, account_amount = 500 WHERE id = ?',
      ['linked'],
    );
    await settlement();
    await db.customStatement(
      'UPDATE aa_groups SET settled = 1, settlement_id = ? WHERE id = ?',
      ['local-settlement', 'local-group'],
    );
    final originalBills = (await snapshot())['bills'];
    final downgrade = await incoming(
      groups: [
        {
          ...incomingGroup(updatedAt: 300),
          'settled': false,
          'settlementId': null,
        },
      ],
    );

    await service.importSyncFile(downgrade.path);

    final afterDowngrade = (await db.getAaGroup('local-group'))!;
    expect(afterDowngrade.settled, isTrue);
    expect(afterDowngrade.settlementId, 'local-settlement');
    expect((await snapshot())['bills'], originalBills);
    final changedAmount = await incoming(
      groups: [
        {
          ...incomingGroup(updatedAt: 400),
          'totalAmount': 2003,
          'dateMs': 800,
          'settled': false,
          'settlementId': null,
        },
      ],
    );

    await service.importSyncFile(changedAmount.path);

    final afterSecondFile = (await db.getAaGroup('local-group'))!;
    expect(afterSecondFile.settled, isTrue);
    expect(afterSecondFile.settlementId, 'local-settlement');
    expect(afterSecondFile.totalAmount, 2003);
    expect((await snapshot())['bills'], originalBills);
  });

  test('无关联账单的旧 CNY 组和结算继续可导出，并兼容省略版本的旧文件', () async {
    await group();
    await settlement();
    final path = await service.exportSyncFile();
    final payload = await decryptAasContent(
      await File(path).readAsString(),
      _secret,
    );
    expect(payload['format'], 1);
    expect(payload.containsKey('currency'), isFalse);
    expect((payload['groups'] as List).single['id'], 'local-group');
    expect((payload['settlements'] as List).single['id'], 'local-settlement');
    final file = await incoming(
      legacy: true,
      groups: [incomingGroup()],
      settlements: [await incomingSettlement()],
    );
    await service.importSyncFile(file.path);
    final bill = (await db.getAllBills()).single;
    expect(bill.currency, 'CNY');
    expect(bill.accountId, 'acc_cash');
    expect(bill.amount, 500);
    expect(bill.accountAmount, 500);
    await service.importSyncFile(file.path);
    expect((await db.getAllBills()).single, bill);
  });

  test('旧 CNY 结算转账保留空或等额入账字段，导出和重导均不重写历史账单', () async {
    await settlement();
    await linkedBill(settled: true);
    for (final incomingAmount in [null, 500]) {
      // 旧版本的结算转账，C07 有意保留；新建转账仍禁止关联结算。
      await db.customStatement(
        'UPDATE bills SET type = 2, amount = 500, account_amount = 500, '
        'to_account_id = ?, to_account_amount = ? WHERE id = ?',
        ['acc_wechat', incomingAmount, 'linked'],
      );
      final before = (await snapshot())..remove('meta');
      final path = await service.exportSyncFile();
      final payload = await decryptAasContent(
        await File(path).readAsString(),
        _secret,
      );
      expect(payload['format'], 1);
      expect(payload['groups'], isEmpty);
      expect((payload['settlements'] as List).single['id'], 'local-settlement');
      final file = await incoming(settlements: [await incomingSettlement()]);
      await service.importSyncFile(file.path);
      await service.importSyncFile(file.path);
      final after = (await snapshot())..remove('meta');
      expect(after, before, reason: 'incoming=$incomingAmount');
      expect(await db.getMeta('lastExportAt'), isNotNull);
      expect(await db.getMeta('lastImportAt'), isNotNull);
    }
  });

  test('无 AA 关联的外币普通账单和跨币转账不阻止 CNY 同步或结算', () async {
    await db.upsertBill(
      id: 'ordinary-usd',
      type: 0,
      amount: 1000,
      currency: 'USD',
      accountId: 'acc_cash',
      accountAmount: 7200,
      dateMs: 100,
    );
    await db.upsertBill(
      id: 'ordinary-transfer',
      type: 2,
      amount: 72000,
      accountId: 'acc_cash',
      toAccountId: 'usd',
      toAccountAmount: 10000,
      dateMs: 100,
    );
    final original = {
      for (final bill in await db.getAllBills()) bill.id: bill.toJson(),
    };
    await group();
    await linkedBill();
    await service.settle(accountId: 'acc_cash');
    final path = await service.exportSyncFile();
    final payload = await decryptAasContent(
      await File(path).readAsString(),
      _secret,
    );
    expect(payload['format'], 1);
    expect(payload.containsKey('bills'), isFalse);
    expect(payload['groups'], hasLength(1));
    expect(payload['settlements'], hasLength(1));
    final file = await incoming(
      settlements: [await incomingSettlement(id: 'remote')],
    );
    await service.importSyncFile(file.path);
    final after = {
      for (final bill in await db.getAllBills()) bill.id: bill.toJson(),
    };
    for (final entry in original.entries) {
      expect(after[entry.key], entry.value, reason: entry.key);
    }
    expect(
      (await db.getAllBills()).where((b) => b.settlementId != null),
      everyElement(isA<Bill>().having((b) => b.currency, 'currency', 'CNY')),
    );
  });
}
