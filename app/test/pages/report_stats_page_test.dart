import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';

import '../helpers/test_support.dart';

class _ReportMonth extends SelectedMonthNotifier {
  _ReportMonth(this.month);
  final DateTime month;

  @override
  DateTime build() => month;
}

class _ReportView extends StatsViewNotifier {
  _ReportView(this.view);
  final ReportViewCurrency view;

  @override
  ReportViewCurrency build() => view;
}

Category _category(String id, {String? parent, int sort = 0}) => Category(
  id: id,
  parentId: parent,
  name: id,
  emoji: '📦',
  kind: 0,
  sort: sort,
  isPreset: false,
);

Bill _bill(
  String id,
  DateTime date, {
  required int amount,
  String? category = 'food',
  int type = 0,
  String currency = 'CNY',
  int? actual,
  int? deletedAt,
}) => mkBill(
  id,
  dateMs: date.millisecondsSinceEpoch,
  amount: amount,
  categoryId: category,
  type: type,
  currency: currency,
  accountAmount: actual,
  deletedAt: deletedAt,
);

Future<AppDatabase> _pumpInjected(
  WidgetTester tester, {
  required DateTime month,
  required List<Bill> bills,
  List<Category>? categories,
  String currency = 'CNY',
}) => pumpPage(
  tester,
  const StatsPage(),
  overrides: [
    selectedMonthProvider.overrideWith(() => _ReportMonth(month)),
    statsViewProvider.overrideWith(
      () => _ReportView(ReportViewCurrency.original(currency)),
    ),
    categoriesProvider.overrideWith(
      (ref) => Stream.value(categories ?? [_category('food')]),
    ),
    // Deliberately pass the complete input to both streams. The report page
    // must apply its own period instead of trusting an upstream pre-filter.
    monthBillsProvider.overrideWith((ref) => Stream.value(bills)),
    allBillsProvider.overrideWith((ref) => Stream.value(bills)),
  ],
);

String _total(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('stats-expense-total')))
    .data!;

Future<BarChart> _trend(WidgetTester tester) async {
  if (find.byType(BarChart).evaluate().isEmpty) {
    final scrollable = find.descendant(
      of: find.byType(StatsPage),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byType(BarChart),
      400,
      scrollable: scrollable,
      maxScrolls: 8,
    );
    await settleProviders(tester);
  }
  return tester.widget<BarChart>(find.byType(BarChart));
}

String _tooltip(BarChart chart, int monthIndex, int rodIndex) {
  final group = chart.data.barGroups[monthIndex];
  return chart.data.barTouchData.touchTooltipData
      .getTooltipItem(group, monthIndex, group.barRods[rodIndex], rodIndex)!
      .text;
}

void _groupAmount(String id, String expected) {
  expect(
    find.descendant(
      of: find.byKey(ValueKey('category-stats-$id')),
      matching: find.text(expected),
    ),
    findsOneWidget,
  );
}

Future<void> _save(
  AppDatabase db,
  String id,
  DateTime date, {
  required int amount,
  String category = 'cat_food',
  int type = 0,
}) => db.upsertBill(
  id: id,
  dateMs: date.millisecondsSinceEpoch,
  amount: amount,
  categoryId: category,
  accountId: 'acc_cash',
  type: type,
);

void main() {
  testWidgets('双流均就绪但快照不同时，月饼图与趋势使用同一最新账单列表', (tester) async {
    final month = DateTime(2026, 10);
    final previous = _bill('edited', month, amount: 1000);
    final latest = _bill('edited', month, amount: 2000);
    final db = await pumpPage(
      tester,
      const StatsPage(),
      overrides: [
        selectedMonthProvider.overrideWith(() => _ReportMonth(month)),
        categoriesProvider.overrideWith(
          (ref) => Stream.value([_category('food')]),
        ),
        monthBillsProvider.overrideWith((ref) => Stream.value([previous])),
        allBillsProvider.overrideWith((ref) => Stream.value([latest])),
      ],
    );

    expect(_total(tester), '¥ 20.00');
    _groupAmount('food', '20.00 · 占本月 100%');
    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.single.value, 20);
    final chart = await _trend(tester);
    expect(chart.data.barGroups.last.barRods.first.toY, 20);
    expect(_tooltip(chart, 5, 0), '10月 支出\n¥ 20.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final month in [DateTime(2024, 2), DateTime(2026, 12)]) {
    testWidgets('${month.year}-${month.month}月饼图与趋势使用同一半开边界', (tester) async {
      final end = DateTime(month.year, month.month + 1);
      final db = await _pumpInjected(
        tester,
        month: month,
        bills: [
          _bill(
            'before-start',
            month.subtract(const Duration(milliseconds: 1)),
            amount: 9900,
          ),
          _bill('at-start', month, amount: 111),
          _bill(
            'before-end',
            end.subtract(const Duration(milliseconds: 1)),
            amount: 912,
          ),
          _bill('at-end', end, amount: 8800),
        ],
      );

      expect(_total(tester), '¥ 10.23');
      _groupAmount('food', '10.23 · 占本月 100%');
      final chart = await _trend(tester);
      expect(chart.data.barGroups.last.barRods.first.toY, 10.23);
      expect(chart.data.barGroups[4].barRods.first.toY, 99);
      expect(_tooltip(chart, 5, 0), '${month.month}月 支出\n¥ 10.23');
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('11个一级分类全部保留，饼图金额和趋势不截断尾部分类', (tester) async {
    final month = DateTime(2026, 10);
    final db = await _pumpInjected(
      tester,
      month: month,
      categories: [for (var i = 1; i <= 11; i++) _category('root-$i', sort: i)],
      bills: [
        for (var i = 1; i <= 11; i++)
          _bill('bill-$i', month, amount: i * 100, category: 'root-$i'),
      ],
    );

    expect(_total(tester), '¥ 66.00');
    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.length, 11);
    expect(pie.data.sections.map((section) => section.value), [
      11,
      10,
      9,
      8,
      7,
      6,
      5,
      4,
      3,
      2,
      1,
    ]);
    _groupAmount('root-11', '11.00 · 占本月 17%');
    _groupAmount('root-1', '1.00 · 占本月 2%');
    final chart = await _trend(tester);
    expect(chart.data.barGroups.last.barRods.first.toY, 66);
    expect(_tooltip(chart, 5, 0), '10月 支出\n¥ 66.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('父级直记与二级并入同一分类，遗失分类和未分类只合计一次', (tester) async {
    final month = DateTime(2026, 10);
    final db = await _pumpInjected(
      tester,
      month: month,
      categories: [
        _category('food'),
        _category('lunch', parent: 'food'),
      ],
      bills: [
        _bill('direct', month, amount: 1001),
        _bill('child', month, amount: 2002, category: 'lunch'),
        _bill('missing', month, amount: 303, category: 'missing'),
        _bill('unassigned', month, amount: 404, category: null),
        _bill(
          'next-month-child',
          DateTime(2026, 11),
          amount: 9000,
          category: 'lunch',
        ),
      ],
    );

    expect(_total(tester), '¥ 37.10');
    _groupAmount('food', '30.03 · 占本月 81%');
    _groupAmount('uncategorized', '7.07 · 占本月 19%');
    await tester.tap(find.byKey(const ValueKey('category-stats-food')));
    await settleProviders(tester);
    expect(find.text('10.01 · 33%'), findsOneWidget);
    expect(find.text('20.02 · 67%'), findsOneWidget);
    expect((await _trend(tester)).data.barGroups.last.barRods.first.toY, 37.1);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('真实账单改金额再改到上月，月饼图和趋势均即时重算', (tester) async {
    final db = TestAppDatabase();
    final month = DateTime(2026, 10);
    await _save(db, 'editable', month, amount: 2500);
    await pumpPage(
      tester,
      const StatsPage(),
      db: db,
      overrides: [
        selectedMonthProvider.overrideWith(() => _ReportMonth(month)),
      ],
    );
    expect(_total(tester), '¥ 25.00');
    expect((await _trend(tester)).data.barGroups.last.barRods.first.toY, 25);

    await _save(db, 'editable', month, amount: 3456);
    await settleProviders(tester);
    expect(_total(tester), '¥ 34.56');
    _groupAmount('cat_food', '34.56 · 占本月 100%');
    expect((await _trend(tester)).data.barGroups.last.barRods.first.toY, 34.56);

    await _save(
      db,
      'editable',
      DateTime(2026, 9, 30, 23, 59, 59, 999),
      amount: 4321,
    );
    await settleProviders(tester);
    expect(_total(tester), '¥ 0.00');
    expect(find.byType(PieChart), findsNothing);
    final chart = await _trend(tester);
    expect(chart.data.barGroups.last.barRods.first.toY, 0);
    expect(chart.data.barGroups[4].barRods.first.toY, 43.21);
    expect(_tooltip(chart, 4, 0), '9月 支出\n¥ 43.21');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('真实二级分类迁移后改归新一级，报表总额和趋势不变', (tester) async {
    final db = TestAppDatabase();
    final month = DateTime(2026, 10);
    await db.getAllAccounts();
    for (final category in [
      _category('report-a'),
      _category('report-b'),
      _category('report-child', parent: 'report-a'),
    ]) {
      await db.upsertCategory(
        id: category.id,
        name: category.name,
        emoji: category.emoji,
        kind: category.kind,
        sort: category.sort,
        parentId: category.parentId,
      );
    }
    await _save(db, 'direct-a', month, amount: 1000, category: 'report-a');
    await _save(db, 'direct-b', month, amount: 2000, category: 'report-b');
    await _save(db, 'child', month, amount: 1500, category: 'report-child');
    await pumpPage(
      tester,
      const StatsPage(),
      db: db,
      overrides: [
        selectedMonthProvider.overrideWith(() => _ReportMonth(month)),
      ],
    );
    expect(_total(tester), '¥ 45.00');
    _groupAmount('report-a', '25.00 · 占本月 56%');
    _groupAmount('report-b', '20.00 · 占本月 44%');

    await db.moveSubcategory(
      id: 'report-child',
      expectedParentId: 'report-a',
      targetParentId: 'report-b',
    );
    await settleProviders(tester);
    expect(_total(tester), '¥ 45.00');
    _groupAmount('report-a', '10.00 · 占本月 22%');
    _groupAmount('report-b', '35.00 · 占本月 78%');
    expect((await _trend(tester)).data.barGroups.last.barRods.first.toY, 45);
    expect(
      (await db.getAllBills()).singleWhere((b) => b.id == 'child').categoryId,
      'report-child',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('真实账单软删后饼图和趋势同步减少，普通收入保留精确末位', (tester) async {
    final db = TestAppDatabase();
    final month = DateTime(2026, 10);
    await _save(db, 'keep', month, amount: 1001);
    await _save(db, 'delete', month, amount: 2029);
    await _save(
      db,
      'income',
      month,
      amount: 3037,
      type: 1,
      category: 'inc_salary',
    );
    await pumpPage(
      tester,
      const StatsPage(),
      db: db,
      overrides: [
        selectedMonthProvider.overrideWith(() => _ReportMonth(month)),
      ],
    );
    expect(_total(tester), '¥ 30.30');
    await db.softDeleteBill('delete');
    await settleProviders(tester);

    expect(_total(tester), '¥ 10.01');
    _groupAmount('cat_food', '10.01 · 占本月 100%');
    final chart = await _trend(tester);
    expect(chart.data.barGroups.last.barRods.first.toY, 10.01);
    expect(chart.data.barGroups.last.barRods.last.toY, 30.37);
    expect(_tooltip(chart, 5, 1), '10月 收入\n¥ 30.37');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('跨币账户实扣不混入原币报表，边界外和同额其他币种均排除', (tester) async {
    final month = DateTime(2026, 10);
    final db = await _pumpInjected(
      tester,
      month: month,
      currency: 'USD',
      bills: [
        _bill('cross', month, amount: 1023, currency: 'USD', actual: 7356),
        _bill(
          'income',
          month,
          amount: 2047,
          currency: 'USD',
          type: 1,
          actual: 14711,
        ),
        _bill('cny', month, amount: 1023),
        _bill('jpy', month, amount: 1023, currency: 'JPY'),
        _bill('outside', DateTime(2026, 11), amount: 5000, currency: 'USD'),
      ],
    );

    expect(_total(tester), 'USD 10.23');
    _groupAmount('food', '10.23 · 占本月 100%');
    final chart = await _trend(tester);
    expect(chart.data.barGroups.last.barRods.first.toY, 10.23);
    expect(chart.data.barGroups.last.barRods.last.toY, 20.47);
    expect(_tooltip(chart, 5, 0), '10月 支出\nUSD 10.23');
    expect(_tooltip(chart, 5, 1), '10月 收入\nUSD 20.47');
    expect(find.textContaining('73.56'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('未知币种在月边界独立保留最小单位，不借用相邻币种精度', (tester) async {
    final month = DateTime(2026, 12);
    final db = await _pumpInjected(
      tester,
      month: month,
      currency: 'XTS',
      bills: [
        _bill(
          'unknown',
          DateTime(2026, 12, 31, 23, 59, 59, 999),
          amount: 1234,
          currency: 'XTS',
        ),
        _bill('next', DateTime(2027, 1), amount: 9000, currency: 'XTS'),
        _bill('different-unknown', month, amount: 5678, currency: 'XTA'),
        _bill('cny', month, amount: 1234),
      ],
    );

    expect(_total(tester), 'XTS 1234 最小单位');
    _groupAmount('food', 'XTS 1234 最小单位 · 占本月 100%');
    final chart = await _trend(tester);
    expect(chart.data.barGroups.last.barRods.first.toY, 1234);
    expect(_tooltip(chart, 5, 0), '12月 支出\nXTS 1234 最小单位');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('一月六个月趋势跨年按月归属，日元原额和提示始终整数', (tester) async {
    final month = DateTime(2027, 1);
    final db = await _pumpInjected(
      tester,
      month: month,
      currency: 'JPY',
      bills: [
        for (var offset = -5; offset <= 0; offset++)
          _bill(
            'month-$offset',
            DateTime(2027, 1 + offset),
            amount: 1000 + offset,
            currency: 'JPY',
            actual: 500,
          ),
        _bill(
          'too-old',
          DateTime(2026, 7, 31, 23, 59, 59, 999),
          amount: 9900,
          currency: 'JPY',
        ),
        _bill('future', DateTime(2027, 2), amount: 8800, currency: 'JPY'),
      ],
    );

    expect(_total(tester), 'JPY 1,000');
    _groupAmount('food', '1,000 · 占本月 100%');
    final chart = await _trend(tester);
    expect(chart.data.barGroups.map((group) => group.barRods.first.toY), [
      995,
      996,
      997,
      998,
      999,
      1000,
    ]);
    expect(_tooltip(chart, 0, 0), '8月 支出\nJPY 995');
    expect(_tooltip(chart, 4, 0), '12月 支出\nJPY 999');
    expect(_tooltip(chart, 5, 0), '1月 支出\nJPY 1,000');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
