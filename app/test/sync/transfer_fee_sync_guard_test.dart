import 'dart:io';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/test_support.dart';

const _secret = 'transfer-fee-sync-guard';
const _transferId = 'ordinary-transfer';
const _feeId = 'transfer_fee:ordinary-transfer';

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

  Future<Map<String, Object?>> snapshot() async => {
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

  Future<Bill> bill(String id) async =>
      (await db.select(db.bills).get()).singleWhere((row) => row.id == id);

  Future<void> transfer({
    String source = 'acc_cash',
    String target = 'acc_bank',
    int amount = 1000,
    int incoming = 1000,
    int feeAmount = 25,
    Bill? expectedTransfer,
    Bill? expectedFee,
  }) async => db.saveTransferWithFee(
    id: _transferId,
    amount: amount,
    toAccountAmount: incoming,
    dateMs: 100,
    note: '本人转账',
    feeAmount: feeAmount,
    feeCategoryId: 'cat_food',
    expectedSource: (await db.getAccount(source))!,
    expectedTarget: (await db.getAccount(target))!,
    expectedTransfer: expectedTransfer,
    expectedFee: expectedFee,
  );

  Future<void> group() => db.upsertAaGroup(
    AaGroupsCompanion.insert(
      id: 'linked-group',
      ownerUid: 'partner',
      payerUid: 'partner',
      totalAmount: 1001,
      dateMs: 100,
      createdAtMs: 101,
      updatedAtMs: 200,
    ),
  );

  Map<String, Object?> incomingGroup() => {
    'id': 'linked-group',
    'ownerUid': 'partner',
    'payerUid': 'partner',
    'totalAmount': 1001,
    'dateMs': 100,
    'note': '仅同步元数据，不触发快捷改金额兜底',
    'createdAtMs': 101,
    'updatedAtMs': 300,
  };

  Future<Map<String, Object?>> incomingSettlement(String id) async => {
    'id': id,
    'receiverUid': (await db.getMeta('myUid'))!,
    'amount': 500,
    'dateMs': 300,
    'cutoffMs': 300,
    'createdAtMs': 301,
  };

  Future<File> incoming({
    List<Map<String, Object?>> groups = const [],
    List<Map<String, Object?>> settlements = const [],
  }) async {
    final file = File('${paths.tempDir.path}/incoming.aas');
    await file.writeAsString(
      await encryptToAasContent({
        'format': 1,
        'fromUid': 'partner',
        'fromName': '导入后不应遗留的新昵称',
        'groups': groups,
        'settlements': settlements,
      }, _secret),
    );
    return file;
  }

  Future<void> rejectUnchanged(Future<dynamic> Function() action) async {
    final before = await snapshot();
    final files = paths.tempDir.listSync().map((file) => file.path).toSet();
    await expectLater(action(), throwsStateError);
    expect(await snapshot(), before);
    expect(paths.tempDir.listSync().map((file) => file.path).toSet(), files);
  }

  test('异常 AA 关联手续费子行含软删除：导出、结算和仅元数据导入均拒绝且六表不变', () async {
    await transfer();
    await group();
    // Deliberately corrupt an otherwise valid CNY fee. All legacy currency
    // checks pass, so this exercises the new fee-association sync guard.
    await db.customStatement(
      'UPDATE bills SET is_aa = 1, aa_group_id = ? WHERE id = ?',
      ['linked-group', _feeId],
    );
    final file = await incoming(groups: [incomingGroup()]);
    for (final deletedAt in [null, 400]) {
      await db.customStatement('UPDATE bills SET deleted_at = ? WHERE id = ?', [
        deletedAt,
        _feeId,
      ]);
      await rejectUnchanged(service.exportSyncFile);
      await rejectUnchanged(() => service.settle(accountId: 'acc_cash'));
      await rejectUnchanged(() => service.importSyncFile(file.path));
    }
  });

  test('已取消费用历史仍保护 AA 父行及旧 CNY 结算转账，拒绝后六表原样', () async {
    await transfer();
    await transfer(
      feeAmount: 0,
      expectedTransfer: await bill(_transferId),
      expectedFee: await bill(_feeId),
    );
    expect((await bill(_feeId)).deletedAt, isNotNull);
    expect((await bill(_feeId)).feeDeletedWithTransferAt, isNull);
    await group();
    // A CNY expense with legitimate AA fields would pass the old validator.
    // Only its retained, cancelled fee history makes this association unsafe.
    await db.customStatement(
      '''
UPDATE bills SET type = 0, to_account_id = NULL, to_account_amount = NULL,
  is_aa = 1, aa_group_id = 'linked-group' WHERE id = ?
''',
      [_transferId],
    );
    final groupFile = await incoming(groups: [incomingGroup()]);
    await rejectUnchanged(service.exportSyncFile);
    await rejectUnchanged(() => service.settle(accountId: 'acc_cash'));
    await rejectUnchanged(() => service.importSyncFile(groupFile.path));

    final settlement = await incomingSettlement('linked-settlement');
    await db.upsertSettlement(
      SettlementsCompanion.insert(
        id: 'linked-settlement',
        receiverUid: settlement['receiverUid']! as String,
        amount: 500,
        dateMs: 300,
        cutoffMs: 300,
        createdAtMs: 301,
      ),
    );
    await db.customStatement(
      '''
UPDATE bills SET type = 2, to_account_id = 'acc_bank', to_account_amount = amount,
  is_aa = 0, aa_group_id = NULL, settlement_id = 'linked-settlement'
WHERE id = ?
''',
      [_transferId],
    );
    final settlementFile = await incoming(settlements: [settlement]);
    await rejectUnchanged(service.exportSyncFile);
    await rejectUnchanged(() => service.importSyncFile(settlementFile.path));
  });

  test('合法外币转账及手续费不阻断无关 CNY AA 结算、导出和导入，原双行不改', () async {
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
    await transfer(source: 'usd', target: 'acc_cash', incoming: 7200);
    final originalTransfer = await bill(_transferId);
    final originalFee = await bill(_feeId);
    await db.upsertBill(
      id: 'unrelated-aa',
      type: 0,
      amount: 1001,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 100,
    );
    await service.createAaBillFor(
      billId: 'unrelated-aa',
      totalAmount: 1001,
      dateMs: 100,
      note: '无关普通 AA',
      categoryName: '餐饮',
      categoryEmoji: '🍚',
    );

    await service.settle(accountId: 'acc_cash');
    final exported = await service.exportSyncFile();
    final payload = await decryptAasContent(
      await File(exported).readAsString(),
      _secret,
    );
    expect(payload['groups'], hasLength(1));
    expect(payload['settlements'], hasLength(1));
    expect(payload.containsKey('bills'), isFalse);
    final file = await incoming(
      settlements: [await incomingSettlement('remote')],
    );
    await service.importSyncFile(file.path);

    expect(await bill(_transferId), originalTransfer);
    expect(await bill(_feeId), originalFee);
    final settlements = await db.getAllSettlements();
    expect(settlements, hasLength(2));
    expect((await db.getAllAaGroups()).single.settled, isTrue);
    expect(await db.getMeta('lastExportAt'), isNotNull);
    expect(await db.getMeta('lastImportAt'), isNotNull);
  });
}
