import 'dart:convert';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

class _MapStore implements RateStore {
  _MapStore(this.data);
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async {}
}

ExchangeRateService _rateService() {
  final now = DateTime.now().toUtc();
  final snapshot = NetworkRateSnapshot(
    quotedAt: DateTime.utc(now.year, now.month, now.day),
    fetchedAt: now,
    rates: {
      Currency.eur: RateRatio.parse('1'),
      Currency.usd: RateRatio.parse('1.1'),
      Currency.cny: RateRatio.parse('7.7'),
      Currency.hkd: RateRatio.parse('10'),
      Currency.jpy: RateRatio.parse('154'),
      Currency.gbp: RateRatio.parse('0.7'),
    },
  );
  return ExchangeRateService(
    store: _MapStore(
      jsonEncode({
        'version': 1,
        'network': snapshot.toJson(),
        'manual': <Object>[],
      }),
    ),
  );
}

class _FixedYear extends SelectedYearNotifier {
  _FixedYear(this.year);
  final int year;
  @override
  int build() => year;
}

class _FixedGranularity extends StatsGranularityNotifier {
  _FixedGranularity(this.granularity);
  final StatsGranularity granularity;
  @override
  StatsGranularity build() => granularity;
}

DateTime _ms(int year, int month, int day) =>
    DateTime(year, month, day, 12);

Future<Bill> _addBill(
  AppDatabase db,
  String id, {
  int type = 0,
  required int amount,
  required String currency,
  required String accountId,
  required int year,
  required int month,
  required int day,
}) async {
  await db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    currency: currency,
    accountId: accountId,
    accountAmount: amount,
    categoryId: type == 1 ? 'inc_salary' : 'cat_food',
    dateMs: _ms(year, month, day).millisecondsSinceEpoch,
  );
  return (await db.getAllBills()).singleWhere((b) => b.id == id);
}

Future<void> _account(AppDatabase db, String id, String currency) =>
    db.upsertAccount(
      id: id,
      name: '$currency 钱包',
      emoji: '💳',
      type: 3,
      initBalance: 0,
      includeNetWorth: true,
      sort: 20,
      currency: currency,
    );

Future<void> _openYearReport(WidgetTester tester, AppDatabase db) async {
  await pumpPage(
    tester,
    const StatsPage(),
    db: db,
    rateService: _rateService(),
    overrides: [
      selectedYearProvider.overrideWith(() => _FixedYear(2028)),
      statsGranularityProvider.overrideWith(
        () => _FixedGranularity(StatsGranularity.year),
      ),
    ],
  );
  await settleProviders(tester);
}

String _summaryValue(WidgetTester tester, String label) => tester
    .widget<Text>(find.byKey(ValueKey('year-summary-$label')))
    .data!;

String _pieTotal(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('stats-expense-total')))
    .data!;

Future<void> _selectCurrency(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('currency-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _toggleGranularity(
  WidgetTester tester,
  StatsGranularity granularity,
) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('stats-granularity')),
      matching: find.text(granularity == StatsGranularity.year ? '年' : '月'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('年粒度总览折合CNY：闰年2月29日计入本年，次年年界排除', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addBill(
      db,
      'leap',
      amount: 29000,
      currency: 'CNY',
      accountId: 'acc_cash',
      year: 2028,
      month: 2,
      day: 29,
    );
    await _addBill(
      db,
      'dec31',
      amount: 31000,
      currency: 'CNY',
      accountId: 'acc_cash',
      year: 2028,
      month: 12,
      day: 31,
    );
    await _addBill(
      db,
      'inc1',
      type: 1,
      amount: 10000,
      currency: 'CNY',
      accountId: 'acc_cash',
      year: 2028,
      month: 3,
      day: 5,
    );
    await _addBill(
      db,
      'inc2',
      type: 1,
      amount: 5000,
      currency: 'CNY',
      accountId: 'acc_cash',
      year: 2028,
      month: 12,
      day: 20,
    );
    await _openYearReport(tester, db);

    // 总览（折合 CNY = 原币）：收入 ¥150、支出 ¥600、结余 -¥450。
    expect(_summaryValue(tester, '收入'), '+¥ 150.00');
    expect(_summaryValue(tester, '支出'), '¥ 600.00');
    expect(_summaryValue(tester, '结余'), '-¥ 450.00');
    expect(_pieTotal(tester), '¥ 600.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('年粒度跨币折合与USD原币切换互不影响', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _addBill(
      db,
      'usd-e',
      amount: 2000,
      currency: 'USD',
      accountId: 'usd',
      year: 2028,
      month: 4,
      day: 5,
    );
    await _addBill(
      db,
      'usd-i',
      type: 1,
      amount: 1000,
      currency: 'USD',
      accountId: 'usd',
      year: 2028,
      month: 5,
      day: 5,
    );
    await _addBill(
      db,
      'cny-e',
      amount: 5000,
      currency: 'CNY',
      accountId: 'acc_cash',
      year: 2028,
      month: 6,
      day: 5,
    );
    await _openYearReport(tester, db);

    // 总览：CNY ¥50 + USD $20×7 = ¥140 → 支出 ¥190；USD 收入 $10×7 = ¥70。
    expect(_summaryValue(tester, '支出'), '¥ 190.00');
    expect(_summaryValue(tester, '收入'), '+¥ 70.00');

    // 切 USD 原币：仅 USD 账单。
    await _selectCurrency(tester, '美元 USD');
    expect(_summaryValue(tester, '支出'), 'USD 20.00');
    expect(_summaryValue(tester, '收入'), '+USD 10.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('粒度月年互切保留年选择，明细页月份不受影响', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _openYearReport(tester, db);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatsPage)),
    );
    expect(container.read(statsGranularityProvider), StatsGranularity.year);
    expect(container.read(selectedYearProvider), 2028);
    final monthBefore = container.read(selectedMonthProvider);

    // 切回月粒度：年选择保留；明细页月份选择不变。
    await _toggleGranularity(tester, StatsGranularity.month);
    expect(container.read(statsGranularityProvider), StatsGranularity.month);
    expect(container.read(selectedYearProvider), 2028);
    expect(
      container.read(selectedMonthProvider),
      monthBefore,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
