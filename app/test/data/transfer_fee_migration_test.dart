import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as legacy;

import 'package:aa_expense_splitter/data/app_database.dart';

typedef _Rows = Map<String, List<Map<String, Object?>>>;

const _tables = [
  'accounts',
  'categories',
  'bills',
  'aa_groups',
  'settlements',
  'meta_entries',
];

// An actual v5 schema, independent of the current Drift definitions. Setting
// user_version on a v6 database would hide missing-column migration errors.
_Rows _createV5(File file) {
  final raw = legacy.sqlite3.open(file.path);
  try {
    raw.execute('''
CREATE TABLE accounts (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  emoji TEXT NOT NULL DEFAULT '💰',
  type INTEGER NOT NULL DEFAULT 3,
  init_balance INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'CNY',
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
  currency TEXT NOT NULL DEFAULT 'CNY',
  account_amount INTEGER NOT NULL DEFAULT 0,
  to_account_amount INTEGER,
  category_id TEXT,
  account_id TEXT NOT NULL,
  to_account_id TEXT,
  date_ms INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  is_aa INTEGER NOT NULL DEFAULT 0,
  aa_group_id TEXT,
  settlement_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
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
  status_note TEXT,
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

    void insert(String table, Map<String, Object?> values) => raw.execute(
      'INSERT INTO $table (${values.keys.join(', ')}) '
      'VALUES (${List.filled(values.length, '?').join(', ')})',
      values.values.toList(),
    );

    for (final entry in [
      ('acc_cash', 'CNY', 0, 9007199254740993),
      ('acc_bank', 'CNY', 1, -135),
      ('acc_usd', 'USD', 3, 12345),
      ('acc_jpy', 'JPY', 3, 777),
      ('acc_aa_credit', 'CNY', 4, 0),
      ('acc_unknown', 'OLD', 3, 19),
    ].indexed) {
      final (id, code, type, initial) = entry.$2;
      insert('accounts', {
        'id': id,
        'name': '旧账户 $id',
        'emoji': '💵',
        'type': type,
        'init_balance': initial,
        'currency': code,
        'include_net_worth': entry.$1.isEven ? 1 : 0,
        'sort': entry.$1 + 7,
        'created_at': entry.$1 + 101,
      });
    }
    for (final entry in [
      ('cat_food', null, '三餐', '🍚', 0),
      ('cat_lunch', 'cat_food', '旧午餐', '🍱', 0),
      ('inc_salary', null, '工资', '💼', 1),
      ('cat_aa_marker', null, 'AA往来', '🤝', 2),
    ].indexed) {
      final (id, parent, name, emoji, kind) = entry.$2;
      insert('categories', {
        'id': id,
        'parent_id': parent,
        'name': name,
        'emoji': emoji,
        'kind': kind,
        'sort': entry.$1 + 8,
        'is_preset': entry.$1.isEven ? 1 : 0,
      });
    }

    void bill(
      String id,
      int type,
      int amount, {
      String currency = 'CNY',
      int? actual,
      int? incoming,
      String source = 'acc_cash',
      String? target,
      String? category = 'cat_lunch',
      bool isAa = false,
      String? group,
      String? settlement,
      int? deleted,
    }) => insert('bills', {
      'id': id,
      'type': type,
      'amount': amount,
      'currency': currency,
      'account_amount': actual ?? amount,
      'to_account_amount': incoming,
      'category_id': category,
      'account_id': source,
      'to_account_id': target,
      'date_ms': 1791624000123,
      'note': '旧备注 $id，手续费仅文字，不推断金额',
      'is_aa': isAa ? 1 : 0,
      'aa_group_id': group,
      'settlement_id': settlement,
      'created_at': 1791623000011,
      'updated_at': 1791623500022,
      'deleted_at': deleted,
    });

    bill('large-expense', 0, 9007199254740993);
    bill('income', 1, 29, category: 'inc_salary');
    bill('deleted-expense', 0, 371, deleted: 1791624500033);
    bill('usd-expense', 0, 1000, currency: 'USD', actual: 7200);
    bill('jpy-income', 1, 501, currency: 'JPY', actual: 2505);
    bill('adjustment', 3, -73, category: null);
    bill('unknown-expense', 0, 19, currency: 'OLD', source: 'acc_unknown');
    bill('blank-code-history', 1, 7, currency: '', category: null);
    bill(
      'same-transfer',
      2,
      529,
      target: 'acc_bank',
      incoming: 529,
      category: null,
    );
    bill('same-transfer-null', 2, 731, target: 'acc_bank', category: null);
    bill(
      'cross-transfer',
      2,
      7200,
      target: 'acc_usd',
      incoming: 1000,
      category: null,
    );
    bill('cross-transfer-null', 2, 777, target: 'acc_usd', category: null);
    bill('missing-target-transfer', 2, 173, target: 'absent', category: null);
    bill(
      'deleted-cross-transfer',
      2,
      1000,
      currency: 'USD',
      source: 'acc_usd',
      target: 'acc_jpy',
      incoming: 1500,
      category: null,
      deleted: 1791624500034,
    );
    bill('aa-original', 0, 2001, isAa: true, group: 'legacy-group');
    bill(
      'aa-share',
      0,
      1000,
      source: 'acc_aa_credit',
      category: 'cat_aa_marker',
      isAa: true,
      group: 'legacy-group',
    );
    bill(
      'settlement-income',
      1,
      1000,
      category: 'inc_salary',
      settlement: 'legacy-settlement',
    );
    // Historical CNY settlement transfers are not ordinary fee transfers.
    bill(
      'settlement-transfer',
      2,
      1000,
      target: 'acc_bank',
      category: null,
      settlement: 'legacy-settlement',
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
      'status_note': '保留历史说明',
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
      'pairSecret': 'fixture-only-secret',
      'aaSettleAccountId': 'acc_bank',
      'lastSyncAt': '1791628000077',
    }.entries) {
      insert('meta_entries', {'key': entry.key, 'value': entry.value});
    }
    raw.execute('PRAGMA user_version = 5');
    return _rawRows(raw);
  } finally {
    raw.close();
  }
}

_Rows _rawRows(legacy.Database raw) => {
  for (final table in _tables)
    table: [
      for (final row in raw.select(
        'SELECT * FROM $table ORDER BY ${table == 'meta_entries' ? 'key' : 'id'}',
      ))
        Map<String, Object?>.from(row),
    ],
};

Future<_Rows> _rows(AppDatabase db) async {
  final result = <String, List<Map<String, Object?>>>{};
  for (final table in _tables) {
    final rows = await db
        .customSelect(
          'SELECT * FROM $table ORDER BY ${table == 'meta_entries' ? 'key' : 'id'}',
        )
        .get();
    result[table] = [for (final row in rows) row.data];
  }
  return result;
}

Future<void> _expectPreserved(AppDatabase db, _Rows oldRows) async {
  for (final entry in oldRows.entries) {
    final rows = await db
        .customSelect(
          'SELECT ${entry.value.first.keys.join(', ')} FROM ${entry.key} '
          'ORDER BY ${entry.key == 'meta_entries' ? 'key' : 'id'}',
        )
        .get();
    expect(
      [for (final row in rows) row.data],
      entry.value,
      reason: 'v5 ${entry.key} 的每个旧字段和全部软删除记录原样保留',
    );
  }
  final bills = await db
      .customSelect(
        'SELECT fee_transfer_id, fee_deleted_with_transfer_at FROM bills',
      )
      .get();
  expect(bills, hasLength(oldRows['bills']!.length));
  for (final bill in bills) {
    expect(bill.data['fee_transfer_id'], isNull);
    expect(bill.data['fee_deleted_with_transfer_at'], isNull);
  }
  final version = await db.customSelect('PRAGMA user_version').getSingle();
  expect(version.read<int>('user_version'), 6);
}

Future<void> _expectIndex(AppDatabase db) async {
  final indexes = await db.customSelect('PRAGMA index_list(bills)').get();
  final index = indexes.singleWhere(
    (row) => row.data['name'] == 'idx_bills_fee_transfer',
  );
  expect(index.read<int>('unique'), 1);
  final columns = await db
      .customSelect('PRAGMA index_info(idx_bills_fee_transfer)')
      .get();
  expect([for (final row in columns) row.data['name']], ['fee_transfer_id']);
}

Future<void> _insertProbe(
  AppDatabase db,
  String id, {
  String? parent,
  int? deleted,
}) => db.customStatement(
  '''
INSERT INTO bills (
  id, type, amount, account_amount, currency, account_id,
  date_ms, created_at, updated_at, fee_transfer_id, deleted_at
) VALUES (?, 0, 1, 1, 'CNY', 'acc_cash', 101, 102, 103, ?, ?)
''',
  [id, parent, deleted],
);

void main() {
  test('真实 v5 升 v6：六表旧字段完全保留，新费用列为空且重开幂等', () async {
    final dir = Directory.systemTemp.createTempSync('fee_v5_upgrade_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/legacy.sqlite');
    final oldRows = _createV5(file);
    final first = AppDatabase(executor: NativeDatabase(file));
    late _Rows upgraded;
    try {
      await _expectPreserved(first, oldRows);
      await _expectIndex(first);
      upgraded = await _rows(first);
    } finally {
      await first.close();
    }

    final reopened = AppDatabase(executor: NativeDatabase(file));
    try {
      expect(await _rows(reopened), upgraded);
      await _expectPreserved(reopened, oldRows);
      await _expectIndex(reopened);
    } finally {
      await reopened.close();
    }
  });

  test('新建 v6 创建费用唯一索引：多笔无关联合法，软删除费用仍占用关联', () async {
    final db = AppDatabase(executor: NativeDatabase.memory());
    try {
      await db.getAllAccounts();
      await _expectIndex(db);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 6);
      await _insertProbe(db, 'unlinked-first');
      await _insertProbe(db, 'unlinked-second');
      await _insertProbe(db, 'old-fee', parent: 'parent', deleted: 104);
      final before = await _rows(db);
      await expectLater(
        _insertProbe(db, 'another-fee', parent: 'parent'),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('UNIQUE constraint failed'),
            'the actual SQLite unique constraint must reject the duplicate',
          ),
        ),
      );
      expect(await _rows(db), before);
    } finally {
      await db.close();
    }
  });

  test('v5 升级索引失败整体回滚列、版本、六表；移除故障后可重试', () async {
    final dir = Directory.systemTemp.createTempSync('fee_v5_rollback_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/legacy.sqlite');
    final oldRows = _createV5(file);
    final setup = legacy.sqlite3.open(file.path);
    try {
      // Index/table names share SQLite's schema namespace. The failure happens
      // after both ALTER TABLE statements, so they must roll back as well.
      setup.execute('CREATE TABLE idx_bills_fee_transfer (probe TEXT)');
      setup.execute("INSERT INTO idx_bills_fee_transfer VALUES ('preserve')");
    } finally {
      setup.close();
    }

    final failed = AppDatabase(executor: NativeDatabase(file));
    try {
      await expectLater(
        failed.getAllAccounts(),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('idx_bills_fee_transfer'),
            'the index creation must fail on the deliberately occupied name',
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
        5,
      );
      final columns = afterFailure
          .select('PRAGMA table_info(bills)')
          .map((row) => row['name'])
          .toSet();
      expect(columns, isNot(contains('fee_transfer_id')));
      expect(columns, isNot(contains('fee_deleted_with_transfer_at')));
      expect(_rawRows(afterFailure), oldRows);
      expect(
        afterFailure
            .select('SELECT probe FROM idx_bills_fee_transfer')
            .single['probe'],
        'preserve',
      );
      expect(
        afterFailure.select(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name = 'idx_bills_fee_transfer'",
        ),
        isEmpty,
      );
      afterFailure.execute('DROP TABLE idx_bills_fee_transfer');
    } finally {
      afterFailure.close();
    }

    final retry = AppDatabase(executor: NativeDatabase(file));
    try {
      await _expectPreserved(retry, oldRows);
      await _expectIndex(retry);
    } finally {
      await retry.close();
    }
  });
}
