import 'dart:io';

import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/test_support.dart';

const _secret = 'currency-protocol-secret';

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
      partnerName: '既有伙伴',
      secret: _secret,
    );
    await db.setMeta('partnerUid', 'known-partner');
    await db.setMeta('lastImportAt', '未导入');
  });

  tearDown(() async {
    await db.close();
    PathProviderPlatform.instance = previousPaths;
    paths.cleanup();
  });

  // 直接读取六张真实 SQLite 表，拒绝导入时也核对偏好、账户和分类。
  Future<Map<String, Object?>> snapshot() async {
    final result = <String, Object?>{};
    for (final table in [
      'accounts',
      'categories',
      'bills',
      'aa_groups',
      'settlements',
      'meta_entries',
    ]) {
      final key = table == 'meta_entries' ? 'key' : 'id';
      result[table] = [
        for (final row
            in await db
                .customSelect('SELECT * FROM "$table" ORDER BY "$key"')
                .get())
          Map<String, Object?>.from(row.data),
      ];
    }
    return result;
  }

  Future<Map<String, Object?>> payload() async {
    final uid = (await db.getMeta('myUid'))!;
    return {
      'format': 1,
      'fromUid': 'incoming-partner',
      'fromName': '新的伙伴',
      'groups': <Map<String, Object?>>[
        {
          'id': 'incoming-group',
          'ownerUid': uid,
          'payerUid': uid,
          'totalAmount': 1001,
          'dateMs': 100,
          'settled': true,
          'settlementId': 'incoming-settlement',
          'createdAtMs': 101,
          'updatedAtMs': 102,
        },
      ],
      'settlements': <Map<String, Object?>>[
        {
          'id': 'incoming-settlement',
          'receiverUid': uid,
          'amount': 500,
          'dateMs': 200,
          'cutoffMs': 200,
          'createdAtMs': 201,
        },
      ],
    };
  }

  Future<File> encryptedFile(Map<String, Object?> data) async {
    final file = File('${paths.tempDir.path}/protocol-guard.aas');
    await file.writeAsString(await encryptToAasContent(data, _secret));
    return file;
  }

  Future<void> expectRejected(Map<String, Object?> data, String reason) async {
    final before = await snapshot();
    final file = await encryptedFile(data);
    await expectLater(
      service.importSyncFile(file.path),
      throwsStateError,
      reason: reason,
    );
    expect(await snapshot(), before, reason: '$reason：六表必须零写入');
  }

  // 成功导入可刷新时间提示，除此之外重导不得改变业务行或配对偏好。
  Map<String, Object?> withoutMetaTime(
    Map<String, Object?> state,
    String timeKey,
  ) => {
    ...state,
    'meta_entries': [
      for (final row in state['meta_entries'] as List<Map<String, Object?>>)
        if (row['key'] != timeKey) row,
    ],
  };

  test('显式格式只接受整数 1，未知版本和错误类型在写入前整份拒绝', () async {
    for (final invalid in <Object?>[2, 0, '1', null, true, 1.0]) {
      final data = await payload();
      data['format'] = invalid;
      await expectRejected(data, 'format=$invalid (${invalid.runtimeType})');
    }
  });

  test('顶层币种不得将外币、未知值或错误类型作为人民币导入', () async {
    for (final invalid in <Object?>['USD', 'JPY', 'XTS', '', null, 1]) {
      final data = await payload();
      data['currency'] = invalid;
      await expectRejected(data, '顶层 currency=$invalid');
    }
  });

  test('列表末尾外币组使前面的合法组和结算也全部拒绝', () async {
    final data = await payload();
    final groups = data['groups'] as List<Map<String, Object?>>;
    groups.add({...groups.first, 'id': 'foreign-group', 'currency': 'USD'});
    await expectRejected(data, '合法结算和组之后出现外币组');
  });

  test('列表末尾错误币种结算使整份文件零写入', () async {
    for (final invalid in <Object?>['EUR', null, false]) {
      final data = await payload();
      final settlements = data['settlements'] as List<Map<String, Object?>>;
      settlements.add({
        ...settlements.first,
        'id': 'foreign-settlement',
        'currency': invalid,
      });
      await expectRejected(data, '第二笔结算 currency=$invalid');
    }
  });

  test('比本机旧的外币组仍拒绝，不能借陈旧记录跳过协议校验', () async {
    final first = await encryptedFile(await payload());
    await service.importSyncFile(first.path);
    final data = await payload();
    final groups = data['groups'] as List<Map<String, Object?>>;
    groups.first['updatedAtMs'] = 1;
    groups.first['currency'] = 'HKD';
    groups.add({...groups.first, 'id': 'new-valid-group', 'currency': 'CNY'});
    await expectRejected(data, '陈旧外币组与新的合法组混合');
  });

  test('已导入的结算若改为外币仍拒绝，不因已有 ID 而静默忽略', () async {
    final first = await encryptedFile(await payload());
    await service.importSyncFile(first.path);
    final data = await payload();
    final settlements = data['settlements'] as List<Map<String, Object?>>;
    settlements.first['currency'] = 'GBP';
    final groups = data['groups'] as List<Map<String, Object?>>;
    groups.add({...groups.first, 'id': 'new-valid-group'});
    await expectRejected(data, '重复结算 ID 带外币');
  });

  test('本机发出的文件也先校验协议，不以自己导出为由吞掉外币', () async {
    final data = await payload();
    data['fromUid'] = await db.getMeta('myUid');
    data['currency'] = 'USD';
    await expectRejected(data, '自己导出的外币文件');
  });

  test('组或结算列表结构错误时不留下元信息和先前记录', () async {
    for (final item in <(String, Object?)>[
      ('groups', 'not-a-list'),
      ('groups', <Object?>[null]),
      ('settlements', <String, Object?>{}),
      ('settlements', <Object?>[5]),
    ]) {
      final data = await payload();
      data[item.$1] = item.$2;
      await expectRejected(data, '${item.$1}结构错误：${item.$2}');
    }
  });

  for (final variant in ['legacy', 'v1', 'explicit-cny']) {
    test('人民币同步兼容 $variant，落账双金额正确且重复导入幂等', () async {
      final data = await payload();
      if (variant == 'legacy') data.remove('format');
      if (variant == 'explicit-cny') {
        data['currency'] = ' cny ';
        for (final key in ['groups', 'settlements']) {
          for (final row in data[key] as List<Map<String, Object?>>) {
            row['currency'] = ' CnY ';
          }
        }
      }
      final file = await encryptedFile(data);

      await service.importSyncFile(file.path);

      expect(await db.getAllAaGroups(), hasLength(1));
      expect(await db.getAllSettlements(), hasLength(1));
      final bill = (await db.getAllBills()).single;
      expect(bill.currency, 'CNY');
      expect(bill.amount, 500);
      expect(bill.accountAmount, 500);
      expect(bill.toAccountAmount, isNull);
      expect(bill.accountId, 'acc_cash');
      expect(bill.type, 1);
      expect(bill.dateMs, 100);
      expect(bill.settlementId, 'incoming-settlement');
      expect(await db.getMeta('partnerUid'), 'incoming-partner');
      expect(await db.getMeta('partnerName'), '新的伙伴');
      expect(await db.getMeta('lastImportAt'), isNot('未导入'));
      final before = await snapshot();

      await service.importSyncFile(file.path);

      expect(
        withoutMetaTime(await snapshot(), 'lastImportAt'),
        withoutMetaTime(before, 'lastImportAt'),
      );
    });
  }

  test('六币种普通账和跨币转账保留本地双金额，解密导出仅有人民币 AA', () async {
    await db.upsertBill(
      id: 'cny-aa',
      type: 0,
      amount: 1001,
      accountId: 'acc_cash',
      dateMs: 100,
    );
    await service.createAaBillFor(
      billId: 'cny-aa',
      totalAmount: 1001,
      dateMs: 100,
      note: '人民币 AA',
      categoryName: '餐饮',
      categoryEmoji: '🍜',
    );
    final currencies = Currency.values;
    for (var index = 0; index < currencies.length; index++) {
      final code = currencies[index].code;
      await db.upsertAccount(
        id: 'account-$code',
        name: code,
        emoji: '💳',
        type: 3,
        initBalance: 0,
        includeNetWorth: true,
        sort: 20 + index,
        currency: code,
      );
      await db.upsertBill(
        id: 'ordinary-$code',
        type: index.isEven ? 0 : 1,
        amount: 1234 + index,
        accountId: 'account-$code',
        currency: code,
        accountAmount: 1234 + index,
        dateMs: 300 + index,
      );
    }
    for (var index = 0; index < currencies.length; index++) {
      final code = currencies[index].code;
      final target = currencies[(index + 1) % currencies.length].code;
      await db.upsertBill(
        id: 'transfer-$code',
        type: 2,
        amount: 1000 + index,
        currency: code,
        accountAmount: 1000 + index,
        accountId: 'account-$code',
        toAccountId: 'account-$target',
        toAccountAmount: 3000 + index,
        dateMs: 400 + index,
      );
    }
    final before = await snapshot();

    final exported = await service.exportSyncFile();
    final clear = await decryptAasContent(
      await File(exported).readAsString(),
      _secret,
    );

    expect(
      clear.keys,
      unorderedEquals([
        'format',
        'fromUid',
        'fromName',
        'exportedAtMs',
        'groups',
        'settlements',
      ]),
    );
    expect(clear['format'], 1);
    expect(clear['settlements'], isEmpty);
    final groups = clear['groups'] as List;
    expect(groups, hasLength(1));
    expect((groups.single as Map)['totalAmount'], 1001);
    expect((groups.single as Map)['note'], '人民币 AA');
    expect(
      withoutMetaTime(await snapshot(), 'lastExportAt'),
      withoutMetaTime(before, 'lastExportAt'),
    );
    final bills = {for (final bill in await db.getAllBills()) bill.id: bill};
    expect(bills, hasLength(13));
    for (var index = 0; index < currencies.length; index++) {
      final code = currencies[index].code;
      final target = currencies[(index + 1) % currencies.length].code;
      final ordinary = bills['ordinary-$code']!;
      expect(ordinary.currency, code);
      expect(ordinary.amount, 1234 + index);
      expect(ordinary.accountAmount, 1234 + index);
      expect(ordinary.toAccountAmount, isNull);
      expect(ordinary.isAa, isFalse);
      final transfer = bills['transfer-$code']!;
      expect(transfer.currency, code);
      expect(transfer.amount, 1000 + index);
      expect(transfer.accountAmount, 1000 + index);
      expect(transfer.toAccountId, 'account-$target');
      expect(transfer.toAccountAmount, 3000 + index);
      expect(transfer.isAa, isFalse);
      expect(transfer.aaGroupId, isNull);
      expect(transfer.settlementId, isNull);
    }
  });
}
