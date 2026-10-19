import 'dart:async';
import 'dart:convert';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

int _dateMs([int day = 8]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, day, 12).millisecondsSinceEpoch;
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

Future<void> _bill(
  AppDatabase db,
  String id, {
  int type = 0,
  required int amount,
  required String currency,
  required String accountId,
  String? categoryId = 'cat_food',
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  currency: currency,
  accountId: accountId,
  accountAmount: amount,
  categoryId: categoryId,
  dateMs: _dateMs(),
  note: id,
);

class _MapStore implements RateStore {
  _MapStore(this.data);
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async => data = value;
}

ExchangeRateService _serviceWithCache(String? cache) => ExchangeRateService(
  store: _MapStore(cache),
  // 断网语义：任何联网尝试都失败，服务保留旧缓存或无值。
  sourceFactory: () => throw StateError('offline test'),
);

String _cacheWith({bool stale = false}) {
  final now = DateTime.now().toUtc();
  final fetched = stale ? now.subtract(const Duration(days: 3)) : now;
  final snapshot = NetworkRateSnapshot(
    quotedAt: DateTime.utc(fetched.year, fetched.month, fetched.day),
    fetchedAt: fetched,
    rates: {
      Currency.eur: RateRatio.parse('1'),
      Currency.usd: RateRatio.parse('1.1'),
      Currency.cny: RateRatio.parse('7.7'),
      Currency.hkd: RateRatio.parse('10'),
      Currency.jpy: RateRatio.parse('154'),
      Currency.gbp: RateRatio.parse('0.7'),
    },
  );
  return jsonEncode({
    'version': 1,
    'network': snapshot.toJson(),
    'manual': <Object>[],
  });
}

Widget _bothPages() => Column(
  children: const [Expanded(child: BillsPage()), Expanded(child: StatsPage())],
);

String _summaryValue(WidgetTester tester, String label) => tester
    .widget<Text>(find.byKey(ValueKey('summary-$label')))
    .data!;

String _pieTotal(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('stats-expense-total')))
    .data!;

Future<void> _selectCurrency(
  WidgetTester tester,
  String label, {
  int index = 0,
}) async {
  await tester.tap(find.byKey(const ValueKey('currency-filter')).at(index));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _seed(AppDatabase db) async {
  await db.getAllAccounts();
  await _account(db, 'usd', 'USD');
  await _account(db, 'jpy', 'JPY');
  await _bill(db, 'cny-expense', amount: 1000, currency: 'CNY', accountId: 'acc_cash');
  await _bill(db, 'cny-income', type: 1, amount: 3000, currency: 'CNY', accountId: 'acc_cash');
  await _bill(db, 'usd-expense', amount: 2000, currency: 'USD', accountId: 'usd');
  await _bill(db, 'jpy-income', type: 1, amount: 2000, currency: 'JPY', accountId: 'jpy');
}

void main() {
  testWidgets('明细与图表默认折合CNY总览，两页金额一致且口径行可见', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, _bothPages(), db: db);

    // 固定测试汇率：USD×7、JPY×0.05；支出 = 10 + 140 = ¥150.00（单次舍入），
    // 收入 = 30 + 100 = ¥130.00。
    expect(_summaryValue(tester, '收入'), '+¥ 130.00');
    expect(_summaryValue(tester, '支出'), '¥ 150.00');
    expect(_summaryValue(tester, '结余'), '-¥ 20.00');

    final hints = tester.widgetList<Text>(
      find.byKey(const ValueKey('report-view-hint')),
    );
    expect(hints.length, 2);
    for (final hint in hints) {
      expect(hint.data!, contains('折合 CNY · 估算值'));
      expect(hint.data!, contains('Frankfurter / ECB'));
      expect(hint.data!, isNot(contains('未纳入')));
    }

    // 图表总览支出总额与明细支出一致（同一折算口径）。
    expect(_pieTotal(tester), '¥ 150.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('两页视图状态互不影响，切原币保留视图且另一页仍为总览', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, _bothPages(), db: db);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );

    await _selectCurrency(tester, '美元 USD');
    expect(
      container.read(billsViewProvider),
      const ReportViewCurrency.original('USD'),
    );
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.converted(),
    );

    // 明细切到美元原币：摘要只含美元账单。
    expect(_summaryValue(tester, '收入'), 'USD 0.00');
    expect(_summaryValue(tester, '支出'), 'USD 20.00');

    // 图表页自己切到日元：不影响明细。
    await _selectCurrency(tester, '日元 JPY', index: 1);
    expect(
      container.read(billsViewProvider),
      const ReportViewCurrency.original('USD'),
    );
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.original('JPY'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('总览下账单列表保持全币种原币展示，日小计与月支出一致', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, BillsPage(), db: db);

    expect(find.text('-10.00'), findsOneWidget);
    expect(find.text('-USD 20.00'), findsOneWidget);
    expect(find.text('+JPY 2,000'), findsOneWidget);
    // 全部账单同日：日小计 = 月支出（同一折算值的分区）。
    expect(find.text('支出 ¥ 150.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('缺汇率时明细与图表排除未纳入币种并明确提示', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(
      tester,
      _bothPages(),
      db: db,
      rateService: _serviceWithCache(null),
    );
    await tester.pumpAndSettle();

    // 只有 CNY 计入；USD / JPY 无汇率 → 未纳入提示。
    expect(_summaryValue(tester, '收入'), '+¥ 30.00');
    expect(_summaryValue(tester, '支出'), '¥ 10.00');
    final hints = tester.widgetList<Text>(
      find.byKey(const ValueKey('report-view-hint')),
    );
    expect(hints.length, 2);
    for (final hint in hints) {
      expect(hint.data!, contains('未纳入 JPY 1 笔、USD 1 笔'));
    }
    // 列表原币行仍在。
    expect(find.text('-USD 20.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('过期缓存标注已过期且金额仍按旧汇率折算', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(
      tester,
      _bothPages(),
      db: db,
      rateService: _serviceWithCache(_cacheWith(stale: true)),
    );
    await tester.pumpAndSettle();

    expect(_summaryValue(tester, '支出'), '¥ 150.00');
    final hint = tester
        .widget<Text>(find.byKey(const ValueKey('report-view-hint')).first)
        .data!;
    expect(hint, contains('汇率已过期'));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('总览下新增账单后摘要即时更新（编辑刷新）', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, BillsPage(), db: db);
    expect(_summaryValue(tester, '支出'), '¥ 150.00');

    await tester.runAsync(
      () => _bill(
        db,
        'cny-expense-2',
        amount: 500,
        currency: 'CNY',
        accountId: 'acc_cash',
      ),
    );
    await tester.pumpAndSettle();
    expect(_summaryValue(tester, '支出'), '¥ 155.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('图表切原币回到单币种口径', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, StatsPage(), db: db);
    expect(_pieTotal(tester), '¥ 150.00');

    await _selectCurrency(tester, '美元 USD');
    expect(_pieTotal(tester), 'USD 20.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('切换统计视图保留所选月份', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, BillsPage(), db: db);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );
    final monthBefore = container.read(selectedMonthProvider);

    await _selectCurrency(tester, '美元 USD');
    await _selectCurrency(tester, '总览 · 折合 CNY');
    expect(container.read(selectedMonthProvider), monthBefore);
    expect(_summaryValue(tester, '支出'), '¥ 150.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
