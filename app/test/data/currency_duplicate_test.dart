import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

import '../helpers/test_support.dart';

final _dateMs = DateTime(2026, 10, 11, 12).millisecondsSinceEpoch;

Future<void> _bill(
  AppDatabase db,
  String id, {
  String currency = 'CNY',
  int type = 0,
  int amount = 1000,
  int? accountAmount,
  String? accountId,
  String? toAccountId,
  int? toAccountAmount,
  int? dateMs,
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  currency: currency,
  accountAmount: accountAmount,
  accountId: accountId ?? 'wallet_$currency',
  toAccountId: toAccountId,
  toAccountAmount: toAccountAmount,
  dateMs: dateMs ?? _dateMs,
);

Future<Map<String, Object?>> _snapshot(AppDatabase db) async => {
  'accounts': {
    for (final row in await db.select(db.accounts).get()) row.id: row.toJson(),
  },
  'bills': {
    for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
  },
  'categories': {
    for (final row in await db.select(db.categories).get())
      row.id: row.toJson(),
  },
  'aaGroups': {
    for (final row in await db.select(db.aaGroups).get()) row.id: row.toJson(),
  },
  'settlements': {
    for (final row in await db.select(db.settlements).get())
      row.id: row.toJson(),
  },
  'meta': {
    for (final row in await db.select(db.metaEntries).get())
      row.key: row.toJson(),
  },
};

void main() {
  late AppDatabase db;

  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
    for (final currency in Currency.values) {
      await db.upsertAccount(
        id: 'wallet_${currency.code}',
        name: currency.code,
        emoji: '💳',
        type: 3,
        initBalance: 0,
        includeNetWorth: true,
        sort: 20,
        currency: currency.code,
      );
    }
  });
  tearDown(() => db.close());

  test('六币种同类型同整数同日仅匹配交易币种自身', () async {
    for (final currency in Currency.values) {
      await _bill(db, currency.code, currency: currency.code);
    }
    for (final currency in Currency.values) {
      final rows = await db.findSimilarBills(
        type: 0,
        amount: 1000,
        dateMs: _dateMs,
        currency: currency.code,
      );
      expect(rows.map((bill) => bill.id).toSet(), {currency.code});
    }
  });

  test('旧调用默认人民币，已知代码大小写与空白规范化后隔离查重', () async {
    for (final code in ['CNY', 'USD', 'JPY']) {
      await _bill(db, code, currency: code);
    }
    final legacy = await db.findSimilarBills(
      type: 0,
      amount: 1000,
      dateMs: _dateMs,
    );
    expect(legacy.map((bill) => bill.id).toSet(), {'CNY'});
    for (final input in [' cny ', ' usd ', 'jPy']) {
      final rows = await db.findSimilarBills(
        type: 0,
        amount: 1000,
        dateMs: _dateMs,
        currency: input,
      );
      expect(rows.map((bill) => bill.id).toSet(), {input.trim().toUpperCase()});
    }
  });

  test('跨币支出按交易原币与原币金额查重，不误用账户实际扣款', () async {
    await _bill(
      db,
      'usd-paid-by-cny',
      currency: 'USD',
      accountId: 'wallet_CNY',
      accountAmount: 7200,
    );
    await _bill(db, 'usd-paid-by-usd', currency: 'USD');
    await _bill(db, 'cny-expense', amount: 7200);

    final dollars = await db.findSimilarBills(
      type: 0,
      amount: 1000,
      dateMs: _dateMs,
      currency: 'USD',
    );
    expect(dollars.map((bill) => bill.id).toSet(), {
      'usd-paid-by-cny',
      'usd-paid-by-usd',
    });
    final yuan = await db.findSimilarBills(
      type: 0,
      amount: 7200,
      dateMs: _dateMs,
    );
    expect(yuan.map((bill) => bill.id).toSet(), {'cny-expense'});
    expect(
      await db.findSimilarBills(type: 0, amount: 1000, dateMs: _dateMs),
      isEmpty,
    );
    expect(
      await db.findSimilarBills(
        type: 0,
        amount: 7200,
        dateMs: _dateMs,
        currency: 'USD',
      ),
      isEmpty,
    );
  });

  test('币种隔离仍按类型和原币金额筛选，转账按出账币种查重', () async {
    for (final code in ['CNY', 'USD']) {
      for (final type in [0, 1, 2, 3]) {
        await _bill(
          db,
          '$code-type-$type',
          currency: code,
          type: type,
          toAccountId: type == 2 ? 'wallet_JPY' : null,
          toAccountAmount: type == 2 ? 1531 : null,
        );
      }
      await _bill(db, '$code-other-amount', currency: code, amount: 1001);
      for (final type in [0, 1, 2, 3]) {
        final rows = await db.findSimilarBills(
          type: type,
          amount: 1000,
          dateMs: _dateMs,
          currency: code,
        );
        expect(rows.map((bill) => bill.id).toSet(), {'$code-type-$type'});
      }
    }
  });

  test('外币查重排除软删除和当前id，恢复后只在自身币种重新命中', () async {
    for (final code in ['CNY', 'USD', 'JPY']) {
      for (final suffix in ['self', 'deleted', 'other']) {
        await _bill(db, '$code-$suffix', currency: code);
      }
      await db.softDeleteBill('$code-deleted');
      final rows = await db.findSimilarBills(
        type: 0,
        amount: 1000,
        dateMs: _dateMs,
        excludeId: '$code-self',
        currency: code,
      );
      expect(rows.map((bill) => bill.id).toSet(), {'$code-other'});
      await db.restoreBill('$code-deleted');
      final restored = await db.findSimilarBills(
        type: 0,
        amount: 1000,
        dateMs: _dateMs,
        currency: code,
      );
      expect(restored.map((bill) => bill.id).toSet(), {
        '$code-self',
        '$code-deleted',
        '$code-other',
      });
    }
  });

  test('自然日区间跨年左闭右开，零点与当日最后毫秒各归属一天', () async {
    final start = DateTime(2026, 12, 31).millisecondsSinceEpoch;
    final end = DateTime(2027, 1, 1).millisecondsSinceEpoch;
    for (final code in ['CNY', 'USD', 'JPY']) {
      for (final entry in {
        'previous': start - 1,
        'first': start,
        'last': end - 1,
        'next': end,
      }.entries) {
        await _bill(
          db,
          '$code-${entry.key}',
          currency: code,
          dateMs: entry.value,
        );
      }
      for (final queryDate in [start, end - 1]) {
        final rows = await db.findSimilarBills(
          type: 0,
          amount: 1000,
          dateMs: queryDate,
          currency: code,
        );
        expect(rows.map((bill) => bill.id).toSet(), {
          '$code-first',
          '$code-last',
        });
      }
      final nextDay = await db.findSimilarBills(
        type: 0,
        amount: 1000,
        dateMs: end,
        currency: code,
      );
      expect(nextDay.map((bill) => bill.id).toSet(), {'$code-next'});
    }
  });

  test('超过浮点精度的相邻原币整数精确区分且不混入同数人民币', () async {
    const amount = 9007199254740993;
    await _bill(db, 'usd-exact', currency: 'USD', amount: amount);
    await _bill(db, 'usd-adjacent', currency: 'USD', amount: amount - 1);
    await _bill(db, 'cny-same-number', amount: amount);
    final rows = await db.findSimilarBills(
      type: 0,
      amount: amount,
      dateMs: _dateMs,
      currency: 'USD',
    );
    expect(rows.map((bill) => bill.id).toSet(), {'usd-exact'});
  });

  test('未知或含糊币种拒绝查重且六表不变，未知历史行不归人民币', () async {
    await _bill(db, 'known');
    await _bill(db, 'unknown-history');
    await db.customStatement('UPDATE bills SET currency = ? WHERE id = ?', [
      'BTC',
      'unknown-history',
    ]);
    await db.setMeta('duplicate-test', '保持原值');
    final before = await _snapshot(db);
    for (final code in ['', ' ', 'BTC', 'US D', '人民币', '¥']) {
      await expectLater(
        db.findSimilarBills(
          type: 0,
          amount: 1000,
          dateMs: _dateMs,
          currency: code,
        ),
        throwsStateError,
      );
      expect(await _snapshot(db), before);
    }
    final rows = await db.findSimilarBills(
      type: 0,
      amount: 1000,
      dateMs: _dateMs,
    );
    expect(rows.map((bill) => bill.id).toSet(), {'known'});
    expect(await _snapshot(db), before);
  });
}
