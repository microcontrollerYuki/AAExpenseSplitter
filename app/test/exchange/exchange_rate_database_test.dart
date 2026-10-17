import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

import '../helpers/test_support.dart';

class _ImmediateSource implements RateSource {
  @override
  Future<NetworkRateSnapshot> fetch() async => NetworkRateSnapshot(
    quotedAt: DateTime.utc(2026, 10, 16),
    fetchedAt: DateTime.utc(2026, 10, 16, 12),
    rates: {
      Currency.eur: RateRatio.parse('1'),
      Currency.cny: RateRatio.parse('7.7'),
      Currency.usd: RateRatio.parse('1.1'),
      Currency.hkd: RateRatio.parse('8.5'),
      Currency.jpy: RateRatio.parse('165'),
      Currency.gbp: RateRatio.parse('0.85'),
    },
  );
  @override
  void cancel() {}
  @override
  void dispose() {}
}

void main() {
  late TestAppDatabase db;
  late ExchangeRateService rates;
  late FakePathProvider paths;
  late AaSyncService aa;

  Future<String> businessSnapshot() async {
    final result = <String, Object>{};
    for (final table in [
      'bills',
      'accounts',
      'categories',
      'aa_groups',
      'settlements',
    ]) {
      result[table] = [
        for (final row
            in await db.customSelect('SELECT * FROM $table ORDER BY id').get())
          row.data,
      ];
    }
    result['meta_entries'] = [
      for (final row
          in await db
              .customSelect(
                "SELECT * FROM meta_entries WHERE key <> '$exchangeRateMetaKey' ORDER BY key",
              )
              .get())
        row.data,
    ];
    return jsonEncode(result);
  }

  setUp(() async {
    paths = FakePathProvider();
    PathProviderPlatform.instance = paths;
    db = TestAppDatabase();
    await db.getAllAccounts();
    aa = AaSyncService(db);
    await aa.setupPairing(
      myName: 'Local',
      partnerName: 'Partner',
      secret: 'fx-guard-test',
    );
    final uid = (await db.getMeta('myUid'))!;
    await db.upsertAaGroup(
      AaGroupsCompanion.insert(
        id: 'g-guard',
        ownerUid: uid,
        payerUid: uid,
        totalAmount: 101,
        dateMs: 100,
        createdAtMs: 100,
        updatedAtMs: 101,
      ),
    );
    await db.upsertSettlement(
      SettlementsCompanion.insert(
        id: 's-guard',
        receiverUid: uid,
        amount: 50,
        dateMs: 102,
        cutoffMs: 100,
        createdAtMs: 102,
      ),
    );
    await db.upsertBill(
      id: 'ordinary',
      type: 0,
      amount: 1234,
      accountId: 'acc_cash',
      dateMs: 100,
    );
    rates = ExchangeRateService(
      store: DatabaseRateStore(db),
      sourceFactory: _ImmediateSource.new,
      now: () => DateTime.utc(2026, 10, 16, 12),
    );
  });

  tearDown(() async {
    rates.dispose();
    await db.close();
    paths.cleanup();
  });

  test(
    'network/manual/restart touch only the namespaced FX meta record',
    () async {
      final before = await businessSnapshot();
      await rates.initialize();
      await rates.setManual(Currency.usd, Currency.cny, '7.23456789123456789');
      expect(await businessSnapshot(), before);
      expect(await db.getMeta(exchangeRateMetaKey), isNotNull);
      final restarted = ExchangeRateService(
        store: DatabaseRateStore(db),
        sourceFactory: () =>
            throw StateError('fresh persisted cache must not fetch'),
        now: () => DateTime.utc(2026, 10, 16, 12, 1),
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(
        restarted.quote(Currency.usd, Currency.cny)!.ratio,
        RateRatio.parse('7.23456789123456789'),
      );
      expect(restarted.quote(Currency.cny, Currency.usd)!.isManual, isTrue);
      await restarted.useNetwork(Currency.cny, Currency.usd);
      expect(restarted.quote(Currency.usd, Currency.cny)!.isManual, isFalse);
      expect(await businessSnapshot(), before);
    },
  );

  test(
    'AA export contains its original protocol fields and no FX settings',
    () async {
      await rates.initialize();
      await rates.setManual(Currency.usd, Currency.cny, '7.23456789123456789');
      final cache = await db.getMeta(exchangeRateMetaKey);
      final path = await aa.exportSyncFile();
      final payload = await decryptAasContent(
        File(path).readAsStringSync(),
        'fx-guard-test',
      );
      expect(payload.keys.toSet(), {
        'format',
        'fromUid',
        'fromName',
        'exportedAtMs',
        'groups',
        'settlements',
      });
      expect((payload['groups'] as List).single['id'], 'g-guard');
      expect((payload['settlements'] as List).single['id'], 's-guard');
      expect(jsonEncode(payload), isNot(contains(exchangeRateMetaKey)));
      expect(jsonEncode(payload), isNot(contains('7.23456789123456789')));
      expect(await db.getMeta(exchangeRateMetaKey), cache);
    },
  );
}
