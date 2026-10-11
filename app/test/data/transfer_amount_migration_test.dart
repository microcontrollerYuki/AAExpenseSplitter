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

const _validAmounts = <String, int>{
  'valid-cny': 777,
  'valid-usd': 1001,
  'valid-jpy': 1531,
  'valid-large': 9007199254740993,
  'valid-deleted': 29,
  'valid-zero': 0,
};

String _orderBy(String table) => table == 'meta_entries' ? 'key' : 'id';

_Rows _rawRows(legacy.Database raw) => {
  for (final table in _tables)
    table: [
      for (final row in raw.select(
        'SELECT * FROM $table ORDER BY ${_orderBy(table)}',
      ))
        Map<String, Object?>.from(row),
    ],
};

_Rows _rawTableInfo(legacy.Database raw) => {
  for (final table in _tables)
    table: [
      for (final row in raw.select('PRAGMA table_info($table)'))
        Map<String, Object?>.from(row),
    ],
};

// Real schema v4 DDL, independent of the current Drift tables. A current
// database with one dropped column would not test the actual upgrade path.
_Rows _createV4(File file) {
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
  created_at INTEGER NOT NULL,
  currency TEXT NOT NULL DEFAULT 'CNY'
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
  settlement_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  currency TEXT NOT NULL DEFAULT 'CNY',
  account_amount INTEGER NOT NULL DEFAULT 0
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

    for (final code in ['CNY', 'USD', 'JPY', 'XTS']) {
      for (final side in ['from', 'to']) {
        insert('accounts', {
          'id': '${code.toLowerCase()}-$side',
          'name': '旧 $code $side 钱包',
          'emoji': '💳',
          'type': 3,
          'init_balance': side == 'from' ? 9007199254740993 : -1531,
          'currency': code,
          'include_net_worth': side == 'from' ? 1 : 0,
          'sort': side == 'from' ? 3 : 8,
          'created_at': 1791623000011,
        });
      }
    }
    insert('accounts', {
      'id': 'acc_aa_credit',
      'name': '旧 AA挂账',
      'emoji': '🤝',
      'type': 4,
      'init_balance': 0,
      'currency': 'CNY',
      'include_net_worth': 0,
      'sort': 99,
      'created_at': 1791623000012,
    });
    for (final category in [
      {'id': 'cat_food', 'name': '三餐', 'emoji': '🍚', 'kind': 0},
      {'id': 'inc_salary', 'name': '工资', 'emoji': '💼', 'kind': 1},
      {'id': 'cat_aa_marker', 'name': 'AA往来', 'emoji': '🤝', 'kind': 2},
    ]) {
      insert('categories', {
        ...category,
        'parent_id': null,
        'sort': 7,
        'is_preset': 0,
      });
    }

    void bill(
      String id, {
      int type = 2,
      int amount = 777,
      int? actual,
      String code = 'CNY',
      String source = 'cny-from',
      String? target = 'cny-to',
      String? category,
      bool isAa = false,
      String? groupId,
      String? settlementId,
      int? deletedAt,
    }) => insert('bills', {
      'id': id,
      'type': type,
      'amount': amount,
      'currency': code,
      'account_amount': actual ?? amount,
      'category_id': category,
      'account_id': source,
      'to_account_id': target,
      'date_ms': 1791624000123,
      'note': '保留旧备注 $id，含中文与逗号',
      'is_aa': isAa ? 1 : 0,
      'aa_group_id': groupId,
      'settlement_id': settlementId,
      'created_at': 1791623000011,
      'updated_at': 1791623500022,
      'deleted_at': deletedAt,
    });

    bill('valid-cny');
    bill(
      'valid-usd',
      code: 'USD',
      source: 'usd-from',
      target: 'usd-to',
      amount: 1001,
    );
    bill(
      'valid-jpy',
      code: 'JPY',
      source: 'jpy-from',
      target: 'jpy-to',
      amount: 1531,
    );
    bill(
      'valid-large',
      code: 'USD',
      source: 'usd-from',
      target: 'usd-to',
      amount: 9007199254740993,
    );
    bill('valid-deleted', amount: 29, deletedAt: 1791624500033);
    bill('valid-zero', amount: 0);
    bill(
      'ordinary-expense',
      type: 0,
      target: null,
      amount: 529,
      category: 'cat_food',
    );
    bill(
      'ordinary-income',
      type: 1,
      target: null,
      code: 'USD',
      source: 'usd-from',
      amount: 1001,
      category: 'inc_salary',
    );
    bill(
      'ordinary-cross',
      type: 0,
      target: null,
      code: 'USD',
      amount: 1000,
      actual: 7200,
      category: 'cat_food',
    );
    bill('adjustment', type: 3, target: null, amount: -9223372036854775808);
    bill('missing-source', source: 'missing');
    bill('missing-target', target: 'missing');
    bill('null-target', target: null);
    bill('old-cross', target: 'usd-to', amount: 7200);
    bill('wrong-transaction-currency', code: 'USD', amount: 1000, actual: 7200);
    bill('unequal-actual', amount: 1000, actual: 7200);
    bill('same-account', target: 'cny-from');
    bill('unknown-code', code: 'XTS', source: 'xts-from', target: 'xts-to');
    bill('negative-transfer', amount: -1);
    bill('aa-source', source: 'acc_aa_credit');
    bill('aa-target', target: 'acc_aa_credit');
    bill('is-aa-only', isAa: true);
    // Even a matching group with a different half-share must not normalize a
    // historical transfer as if it were an ordinary AA expense/income.
    bill('aa-linked', amount: 1500, groupId: 'legacy-group');
    bill('settlement-linked', settlementId: 'legacy-settlement');
    bill('internal-category', category: 'cat_aa_marker');

    insert('aa_groups', {
      'id': 'legacy-group',
      'owner_uid': 'old-owner',
      'payer_uid': 'old-owner',
      'total_amount': 2001,
      'date_ms': 1791624000123,
      'note': '旧共享备注',
      'category_name': '旧三餐',
      'category_emoji': '🍚',
      'status': 1,
      'status_by_uid': 'old-partner',
      'status_at_ms': 1791625000044,
      'status_note': '旧确认说明',
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
    insert('meta_entries', {'key': 'myName', 'value': '旧昵称，不触发配对补行'});
    raw.execute('PRAGMA user_version = 4');
    return _rawRows(raw);
  } finally {
    raw.close();
  }
}

Future<void> _expectUpgrade(AppDatabase db, _Rows oldRows) async {
  for (final entry in oldRows.entries) {
    final columns = entry.value.first.keys.join(', ');
    final actual = await db
        .customSelect(
          'SELECT $columns FROM ${entry.key} ORDER BY ${_orderBy(entry.key)}',
        )
        .get();
    expect(
      actual.map((row) => row.data).toList(),
      entry.value,
      reason: 'v4 ${entry.key} 全部旧字段与时间戳必须原样保留',
    );
  }
  final bills = await db.select(db.bills).get();
  expect(
    bills.map((bill) => bill.id).toSet(),
    oldRows['bills']!.map((row) => row['id']).toSet(),
  );
  for (final bill in bills) {
    expect(
      bill.toAccountAmount,
      _validAmounts[bill.id],
      reason: '${bill.id} 只有可确认的正常同币转账能回填，不能猜测跨币到账额',
    );
  }
  final columns = await db.customSelect('PRAGMA table_info(bills)').get();
  final added = columns.singleWhere(
    (row) => row.read<String>('name') == 'to_account_amount',
  );
  expect(added.read<int>('notnull'), 0);
  final version = await db.customSelect('PRAGMA user_version').getSingle();
  expect(version.read<int>('user_version'), 5);
}

Future<_Rows> _currentRows(AppDatabase db) async {
  final result = <String, List<Map<String, Object?>>>{};
  for (final table in _tables) {
    final rows = await db
        .customSelect('SELECT * FROM $table ORDER BY ${_orderBy(table)}')
        .get();
    result[table] = rows.map((row) => row.data).toList();
  }
  return result;
}

void main() {
  test('真实v4升v5仅回填安全同币转账，六表旧值及重开保持一致', () async {
    final directory = Directory.systemTemp.createTempSync('transfer_v4_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');
    final before = _createV4(file);
    final first = AppDatabase(executor: NativeDatabase(file));
    late _Rows upgraded;
    try {
      await _expectUpgrade(first, before);
      upgraded = await _currentRows(first);
    } finally {
      await first.close();
    }
    final second = AppDatabase(executor: NativeDatabase(file));
    try {
      await _expectUpgrade(second, before);
      expect(await _currentRows(second), upgraded);
    } finally {
      await second.close();
    }
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('到账额回填故障回滚DDL六表和版本，移除触发器后可完整重试', () async {
    final directory = Directory.systemTemp.createTempSync('transfer_rollback_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');
    final before = _createV4(file);
    final setup = legacy.sqlite3.open(file.path);
    late _Rows schemaBefore;
    try {
      schemaBefore = _rawTableInfo(setup);
      setup.execute('''
CREATE TRIGGER abort_transfer_backfill
BEFORE UPDATE ON bills
WHEN NEW.id = 'valid-usd'
BEGIN
  SELECT RAISE(ABORT, 'transfer migration aborted');
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
            (error) => error.toString().contains('transfer migration aborted'),
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
        4,
      );
      expect(_rawTableInfo(afterFailure), schemaBefore);
      expect(_rawRows(afterFailure), before);
      afterFailure.execute('DROP TRIGGER abort_transfer_backfill');
    } finally {
      afterFailure.close();
    }
    final retry = AppDatabase(executor: NativeDatabase(file));
    try {
      await _expectUpgrade(retry, before);
    } finally {
      await retry.close();
    }
  }, timeout: const Timeout(Duration(seconds: 15)));
}
