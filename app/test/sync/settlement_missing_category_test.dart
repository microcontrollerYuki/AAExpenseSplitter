import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';

import '../helpers/test_support.dart';

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
      secret: 'deleted-category-secret',
    );
    await db.setMeta('partnerUid', 'partner');
  });

  tearDown(() async {
    await db.close();
    PathProviderPlatform.instance = previousPaths;
    paths.cleanup();
  });

  Future<void> deleteDefault(int kind) async {
    final preview = await db.previewCategoryDeletion(
      kind == 1 ? 'inc_other' : 'cat_other_exp',
    );
    await db.deleteCategoryAndReassign(
      expected: preview,
      destination: const CategoryDeleteDestination.uncategorized(),
    );
  }

  for (final kind in [0, 1]) {
    test('默认分类删除后，类型 $kind 逐组结算落到未分类并保持幂等', () async {
      await deleteDefault(kind);
      final uid = (await db.getMeta('myUid'))!;
      final payer = kind == 1 ? uid : 'partner';
      await db.upsertAaGroup(
        AaGroupsCompanion.insert(
          id: 'group',
          ownerUid: payer,
          payerUid: payer,
          totalAmount: 1000,
          dateMs: 100,
          createdAtMs: 101,
          updatedAtMs: 102,
        ),
      );
      await service.settle(accountId: 'acc_cash');
      final bill = (await db.getAllBills()).single;
      final settlement = (await db.getAllSettlements()).single;
      expect(bill.type, kind);
      expect(bill.categoryId, isNull);
      expect(bill.amount, 500);
      expect(bill.accountId, 'acc_cash');
      expect(bill.dateMs, 100);
      expect(bill.settlementId, settlement.id);
      expect(bill.aaGroupId, isNull);
      expect((await db.getAaGroup('group'))!.settled, isTrue);
      expect(await service.computeNet(), 0);

      await service.settle(accountId: 'acc_cash');
      expect((await db.getAllBills()).single, bill);
      expect((await db.getAllSettlements()).single, settlement);
    });

    test('默认分类删除后，类型 $kind 旧版净额结算导入为未分类，重导不变', () async {
      await deleteDefault(kind);
      final uid = (await db.getMeta('myUid'))!;
      final payload = {
        'format': 1,
        'fromUid': 'partner',
        'fromName': '伙伴',
        'groups': [],
        'settlements': [
          {
            'id': 'legacy',
            'receiverUid': kind == 1 ? uid : 'partner',
            'amount': 1234,
            'dateMs': 100,
            'cutoffMs': 90,
            'createdAtMs': 101,
          },
        ],
      };
      final file = File('${paths.tempDir.path}/missing-category.aas');
      await file.writeAsString(
        await encryptToAasContent(payload, 'deleted-category-secret'),
      );
      await service.importSyncFile(file.path);
      final bill = (await db.getAllBills()).single;
      expect(bill.type, kind);
      expect(bill.categoryId, isNull);
      expect(bill.amount, 1234);
      expect(bill.accountId, 'acc_cash');
      expect(bill.dateMs, 100);
      expect(bill.settlementId, 'legacy');
      expect(bill.aaGroupId, isNull);

      await service.importSyncFile(file.path);
      expect((await db.getAllBills()).single, bill);
      expect(await db.getAllSettlements(), hasLength(1));
      expect(await db.getAllAaGroups(), isEmpty);
    });
  }
}
