import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as legacy;

import 'package:aa_expense_splitter/data/app_database.dart';

typedef _Rows = Map<String, List<Map<String, Object?>>>;

// These are the historical SQL schemas, deliberately independent of Drift's
// current table definitions. Merely changing user_version on a new database
// would miss duplicate-column and missing-column migration failures.
_Rows _createLegacyDatabase(File file, int version) {
  final raw = legacy.sqlite3.open(file.path);
  try {
    raw.execute('''
CREATE TABLE accounts (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  emoji TEXT NOT NULL DEFAULT '💰',
  type INTEGER NOT NULL DEFAULT 3,
  init_balance INTEGER NOT NULL DEFAULT 0,
  include_net_worth INTEGER NOT NULL DEFAULT 1,
  sort INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
    raw.execute('''
CREATE TABLE categories (
  id TEXT NOT NULL PRIMARY KEY,
  parent_id TEXT,
  name TEXT NOT NULL,
  emoji TEXT NOT NULL,
  kind INTEGER NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0,
  is_preset INTEGER NOT NULL DEFAULT 1
)
''');
    raw.execute('''
CREATE TABLE bills (
  id TEXT NOT NULL PRIMARY KEY,
  type INTEGER NOT NULL,
  amount INTEGER NOT NULL,
  category_id TEXT,
  account_id TEXT NOT NULL,
  to_account_id TEXT,
  date_ms INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  is_aa INTEGER NOT NULL DEFAULT 0,
  aa_group_id TEXT,
  ${version >= 2 ? 'settlement_id TEXT,' : ''}
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
    if (version >= 2) {
      raw.execute('''
CREATE TABLE aa_groups (
  id TEXT NOT NULL PRIMARY KEY,
  owner_uid TEXT NOT NULL,
  payer_uid TEXT NOT NULL,
  total_amount INTEGER NOT NULL,
  date_ms INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  category_name TEXT NOT NULL DEFAULT '',
  category_emoji TEXT NOT NULL DEFAULT '🤝',
  status INTEGER NOT NULL DEFAULT 0,
  status_by_uid TEXT,
  status_at_ms INTEGER,
  ${version >= 3 ? 'status_note TEXT,' : ''}
  settled INTEGER NOT NULL DEFAULT 0,
  settlement_id TEXT,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
)
''');
      raw.execute('''
CREATE TABLE settlements (
  id TEXT NOT NULL PRIMARY KEY,
  receiver_uid TEXT NOT NULL,
  amount INTEGER NOT NULL,
  date_ms INTEGER NOT NULL,
  cutoff_ms INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_at_ms INTEGER NOT NULL
)
''');
      raw.execute('''
CREATE TABLE meta_entries (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');
    }

    void insert(String table, Map<String, Object?> values) {
      final columns = values.keys.join(', ');
      final placeholders = List.filled(values.length, '?').join(', ');
      raw.execute(
        'INSERT INTO $table ($columns) VALUES ($placeholders)',
        values.values.toList(),
      );
    }

    insert('accounts', {
      'id': 'acc_cash',
      'name': '旧现金',
      'emoji': '💵',
      'type': 0,
      'init_balance': 9007199254740993,
      'include_net_worth': 1,
      'sort': 7,
      'created_at': 101,
    });
    insert('accounts', {
      'id': 'acc_bank',
      'name': '旧银行卡',
      'emoji': '💳',
      'type': 1,
      'init_balance': -135,
      'include_net_worth': 0,
      'sort': 11,
      'created_at': 102,
    });
    if (version >= 2) {
      insert('accounts', {
        'id': 'acc_aa_credit',
        'name': 'AA挂账',
        'emoji': '🤝',
        'type': 4,
        'init_balance': 0,
        'include_net_worth': 0,
        'sort': 99,
        'created_at': 103,
      });
    }
    for (final category in [
      {'id': 'cat_food', 'name': '三餐', 'emoji': '🍚', 'kind': 0},
      {'id': 'inc_salary', 'name': '工资', 'emoji': '💼', 'kind': 1},
      {'id': 'cat_aa_marker', 'name': 'AA往来', 'emoji': '🤝', 'kind': 2},
    ]) {
      insert('categories', {
        ...category,
        'parent_id': null,
        'sort': 8,
        'is_preset': 0,
      });
    }
    insert('categories', {
      'id': 'cat_lunch',
      'parent_id': 'cat_food',
      'name': '旧午餐',
      'emoji': '🍱',
      'kind': 0,
      'sort': 19,
      'is_preset': 0,
    });

    void bill(
      String id,
      int type,
      int amount, {
      String accountId = 'acc_cash',
      String? toAccountId,
      String? categoryId = 'cat_lunch',
      String? groupId,
      String? settlementId,
      int? deletedAt,
    }) {
      insert('bills', {
        'id': id,
        'type': type,
        'amount': amount,
        'category_id': categoryId,
        'account_id': accountId,
        'to_account_id': toAccountId,
        'date_ms': 1791624000123,
        'note': '旧备注 $id，含中文与逗号',
        'is_aa': groupId == null ? 0 : 1,
        'aa_group_id': groupId,
        if (version >= 2) 'settlement_id': settlementId,
        'created_at': 1791623000011,
        'updated_at': 1791623500022,
        'deleted_at': deletedAt,
      });
    }

    bill('large-expense', 0, 9007199254740993);
    bill('income', 1, 29, categoryId: 'inc_salary');
    bill('deleted-expense', 0, 371, deletedAt: 1791624500033);
    bill('transfer', 2, 777, toAccountId: 'acc_bank', categoryId: null);
    if (version >= 2) {
      // The historical normalization already agrees with these amounts, so an
      // upgrade must preserve even the original updated_at timestamps.
      bill('aa-original', 0, 2001, groupId: 'legacy-group');
      bill(
        'aa-share',
        0,
        1000,
        accountId: 'acc_aa_credit',
        categoryId: 'cat_aa_marker',
        groupId: 'legacy-group',
      );
      bill(
        'settlement-income',
        1,
        1000,
        categoryId: 'inc_salary',
        settlementId: 'legacy-settlement',
      );
      insert('aa_groups', {
        'id': 'legacy-group',
        'owner_uid': 'old-owner',
        'payer_uid': 'old-owner',
        'total_amount': 2001,
        'date_ms': 1791624000123,
        'note': '旧共享备注',
        'category_name': '三餐 / 旧午餐',
        'category_emoji': '🍱',
        'status': 1,
        'status_by_uid': 'old-partner',
        'status_at_ms': 1791625000044,
        if (version >= 3) 'status_note': '保留历史说明',
        'settled': 1,
        'settlement_id': 'legacy-settlement',
        'created_at_ms': 1791623000011,
        'updated_at_ms': 1791626000055,
      });
      insert('settlements', {
        'id': 'legacy-settlement',
        'receiver_uid': 'old-owner',
        'amount': 1000,
        'date_ms': 1791627000066,
        'cutoff_ms': 1791626000055,
        'note': '旧结算备注',
        'created_at_ms': 1791627000066,
      });
      for (final entry in {
        'myUid': 'old-owner',
        'myName': '旧昵称',
        'aaSettleAccountId': 'acc_bank',
        'lastSyncAt': '1791628000077',
      }.entries) {
        insert('meta_entries', {'key': entry.key, 'value': entry.value});
      }
    }
    raw.execute('PRAGMA user_version = $version');
    return {
      for (final table in [
        'accounts',
        'categories',
        'bills',
        if (version >= 2) ...['aa_groups', 'settlements', 'meta_entries'],
      ])
        table: [
          for (final row in raw.select(
            'SELECT * FROM $table ORDER BY ${table == 'meta_entries' ? 'key' : 'id'}',
          ))
            Map<String, Object?>.from(row),
        ],
    };
  } finally {
    raw.close();
  }
}

Future<void> _expectLegacyRowsUnchanged(AppDatabase db, _Rows expected) async {
  for (final entry in expected.entries) {
    final columns = entry.value.first.keys.join(', ');
    final orderBy = entry.key == 'meta_entries' ? 'key' : 'id';
    final rows = await db
        .customSelect('SELECT $columns FROM ${entry.key} ORDER BY $orderBy')
        .get();
    expect(
      rows.map((row) => row.data).toList(),
      entry.value,
      reason: '旧 ${entry.key} 的全部字段应保留',
    );
  }
}

Future<_Rows> _currentRows(AppDatabase db) async {
  final result = <String, List<Map<String, Object?>>>{};
  for (final table in [
    'accounts',
    'categories',
    'bills',
    'aa_groups',
    'settlements',
    'meta_entries',
  ]) {
    final orderBy = table == 'meta_entries' ? 'key' : 'id';
    final rows = await db
        .customSelect('SELECT * FROM $table ORDER BY $orderBy')
        .get();
    result[table] = rows.map((row) => row.data).toList();
  }
  return result;
}

void main() {
  for (final version in [1, 2, 3]) {
    test('真实 v$version 文件库升至 v4：CNY 原值、双金额和重开保持一致', () async {
      final directory = Directory.systemTemp.createTempSync(
        'currency_v${version}_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/legacy.sqlite');
      final legacyRows = _createLegacyDatabase(file, version);
      final first = AppDatabase(executor: NativeDatabase(file));
      late _Rows afterWrite;
      try {
        // Opening through a real query executes onUpgrade and beforeOpen.
        final accounts = await first.getAllAccounts();
        expect(accounts.every((account) => account.currency == 'CNY'), isTrue);
        await _expectLegacyRowsUnchanged(first, legacyRows);
        final rows = await first.customSelect('SELECT * FROM bills').get();
        for (final row in rows) {
          expect(row.read<String>('currency'), 'CNY');
          expect(row.read<int>('account_amount'), row.read<int>('amount'));
        }
        final deleted = rows.singleWhere(
          (row) => row.read<String>('id') == 'deleted-expense',
        );
        expect(deleted.read<int>('account_amount'), 371);
        expect(deleted.read<int>('deleted_at'), 1791624500033);
        final large = rows.singleWhere(
          (row) => row.read<String>('id') == 'large-expense',
        );
        expect(large.read<int>('account_amount'), 9007199254740993);
        final userVersion = await first
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(userVersion.read<int>('user_version'), 4);
        // Also detect the v1 → latest / v2 → latest status_note branch error.
        await first.getAllAaGroups();
        await first.getAllSettlements();
        await first.setMeta('currency-upgrade-probe', '正常');

        for (final amount in [29, 57]) {
          await first.upsertBill(
            id: 'new-cny-after-upgrade',
            type: 0,
            amount: amount,
            categoryId: 'cat_lunch',
            accountId: 'acc_cash',
            dateMs: 1791629000088,
            note: '升级后普通 CNY 新增及编辑',
            createdAt: 1791629000088,
          );
          final saved = (await first.getAllBills()).singleWhere(
            (bill) => bill.id == 'new-cny-after-upgrade',
          );
          expect(saved.currency, 'CNY');
          expect(saved.amount, amount);
          expect(saved.accountAmount, amount);
        }
        afterWrite = await _currentRows(first);
      } finally {
        await first.close();
      }

      final second = AppDatabase(executor: NativeDatabase(file));
      try {
        expect(await _currentRows(second), afterWrite);
      } finally {
        await second.close();
      }
    });
  }

  test('回填失败回滚新增列与旧数据，移除故障后可重新升级', () async {
    final directory = Directory.systemTemp.createTempSync('currency_rollback_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');
    final legacyRows = _createLegacyDatabase(file, 3);
    final setup = legacy.sqlite3.open(file.path);
    try {
      setup.execute('''
CREATE TRIGGER abort_currency_backfill
BEFORE UPDATE ON bills
BEGIN
  SELECT RAISE(ABORT, 'currency migration aborted');
END
''');
    } finally {
      setup.close();
    }

    final failed = AppDatabase(executor: NativeDatabase(file));
    try {
      await expectLater(
        failed.getAllAccounts(),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('currency migration aborted'),
            'backfill trigger abort',
          ),
        ),
      );
    } finally {
      await failed.close();
    }

    final afterFailure = legacy.sqlite3.open(file.path);
    try {
      expect(
        afterFailure.select('PRAGMA user_version').single['user_version'],
        3,
      );
      final accountColumns = afterFailure
          .select('PRAGMA table_info(accounts)')
          .map((row) => row['name'])
          .toSet();
      final billColumns = afterFailure
          .select('PRAGMA table_info(bills)')
          .map((row) => row['name'])
          .toSet();
      expect(accountColumns, isNot(contains('currency')));
      expect(billColumns, isNot(contains('currency')));
      expect(billColumns, isNot(contains('account_amount')));
      for (final entry in legacyRows.entries) {
        final orderBy = entry.key == 'meta_entries' ? 'key' : 'id';
        final rows = afterFailure.select(
          'SELECT * FROM ${entry.key} ORDER BY $orderBy',
        );
        expect(
          rows.map((row) => Map<String, Object?>.from(row)).toList(),
          entry.value,
          reason: '迁移失败后旧 ${entry.key} 全部字段应回滚',
        );
      }
      afterFailure.execute('DROP TRIGGER abort_currency_backfill');
    } finally {
      afterFailure.close();
    }

    final retry = AppDatabase(executor: NativeDatabase(file));
    try {
      final accounts = await retry.getAllAccounts();
      expect(accounts.every((account) => account.currency == 'CNY'), isTrue);
      await _expectLegacyRowsUnchanged(retry, legacyRows);
      final rows = await retry.customSelect('SELECT * FROM bills').get();
      for (final row in rows) {
        expect(row.read<String>('currency'), 'CNY');
        expect(row.read<int>('account_amount'), row.read<int>('amount'));
      }
      final userVersion = await retry
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(userVersion.read<int>('user_version'), 4);
    } finally {
      await retry.close();
    }
  });
}
