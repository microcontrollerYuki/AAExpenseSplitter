import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';

import '../helpers/test_support.dart';

DateTime get _month {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
}

Future<void> _account(AppDatabase db, String id, String currency) =>
    db.upsertAccount(
      id: id,
      name: id,
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
  String currency = 'CNY',
  int amount = 1000,
  int? actual,
  int type = 0,
  String account = 'acc_cash',
  String? category,
  String? toAccount,
  int? toActual,
  int monthOffset = 0,
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  currency: currency,
  accountAmount: actual,
  accountId: account,
  categoryId: category ?? (type == 1 ? 'inc_salary' : 'cat_food'),
  toAccountId: toAccount,
  toAccountAmount: toActual,
  dateMs: DateTime(
    _month.year,
    _month.month + monthOffset,
    5,
    12,
  ).millisecondsSinceEpoch,
);

Future<Map<String, Object>> _snapshot(AppDatabase db) async => {
  for (final table in [
    'accounts',
    'bills',
    'categories',
    'aa_groups',
    'settlements',
    'meta_entries',
  ])
    table: [
      for (final row
          in await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
        row.data,
    ],
};

Future<void> _select(WidgetTester tester, String label) async {
  final filter = find.byKey(const ValueKey('currency-filter'));
  await tester.ensureVisible(filter);
  await tester.tap(filter);
  await settleProviders(tester);
  await tester.tap(find.text(label).last);
  await settleProviders(tester);
}

String _total(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('stats-expense-total')))
    .data!;

BarChart _trend(WidgetTester tester) =>
    tester.widget<BarChart>(find.byType(BarChart));

String _tooltip(BarChart chart, int monthIndex, int rodIndex) {
  final group = chart.data.barGroups[monthIndex];
  return chart.data.barTouchData.touchTooltipData
      .getTooltipItem(group, monthIndex, group.barRods[rodIndex], rodIndex)!
      .text;
}

void main() {
  testWidgets('真实CNY USD JPY同额按币种隔离，跨币消费用原币且切换清空展开', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _account(db, 'jpy', 'JPY');
    await db.upsertCategory(
      id: 'lunch',
      name: '午餐',
      emoji: '🍜',
      kind: 0,
      sort: 0,
      parentId: 'cat_food',
    );
    await _bill(db, 'cny', category: 'lunch');
    await _bill(
      db,
      'usd-cross',
      currency: 'USD',
      actual: 7200,
      category: 'lunch',
    );
    await _bill(db, 'jpy', currency: 'JPY', account: 'jpy', category: 'lunch');
    await _bill(db, 'cny-income', type: 1, amount: 2000);
    await _bill(
      db,
      'usd-income',
      type: 1,
      amount: 2000,
      currency: 'USD',
      account: 'usd',
    );
    await _bill(
      db,
      'jpy-income',
      type: 1,
      amount: 2000,
      currency: 'JPY',
      account: 'jpy',
    );
    final before = await _snapshot(db);
    await pumpPage(tester, const StatsPage(), db: db);
    expect(_total(tester), '¥ 10.00');
    expect(_trend(tester).data.barGroups.last.barRods.first.toY, 10);
    expect(_trend(tester).data.barGroups.last.barRods.last.toY, 20);
    await tester.tap(find.byKey(const ValueKey('category-stats-cat_food')));
    await settleProviders(tester);
    expect(find.text('分项金额 · 占本分类'), findsOneWidget);

    await _select(tester, '美元 USD');
    expect(_total(tester), 'USD 10.00');
    expect(find.text('分项金额 · 占本分类'), findsNothing);
    expect(_trend(tester).data.barGroups.last.barRods.first.toY, 10);
    expect(_trend(tester).data.barGroups.last.barRods.last.toY, 20);
    expect(_tooltip(_trend(tester), 5, 0), '${_month.month}月 支出\nUSD 10.00');
    expect(find.textContaining('72.00'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('category-stats-cat_food')));
    await settleProviders(tester);
    expect(find.text('10.00 · 100%'), findsOneWidget);

    await _select(tester, '日元 JPY');
    expect(_total(tester), 'JPY 1,000');
    expect(find.text('分项金额 · 占本分类'), findsNothing);
    expect(_trend(tester).data.barGroups.last.barRods.first.toY, 1000);
    expect(_trend(tester).data.barGroups.last.barRods.last.toY, 2000);
    expect(_tooltip(_trend(tester), 5, 1), '${_month.month}月 收入\nJPY 2,000');
    expect(await _snapshot(db), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('近6月窗口与月分类原币一致，转账调账软删内部收入全部排除', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _account(db, 'usd-target', 'USD');
    await _bill(db, 'expense', currency: 'USD', account: 'usd');
    await _bill(
      db,
      'income',
      currency: 'USD',
      account: 'usd',
      type: 1,
      amount: 2000,
    );
    await _bill(
      db,
      'previous',
      currency: 'USD',
      account: 'usd',
      amount: 3000,
      monthOffset: -1,
    );
    await _bill(
      db,
      'first-window',
      currency: 'USD',
      account: 'usd',
      amount: 4000,
      monthOffset: -5,
    );
    await _bill(
      db,
      'too-old',
      currency: 'USD',
      account: 'usd',
      amount: 9000,
      monthOffset: -6,
    );
    await _bill(
      db,
      'future',
      currency: 'USD',
      account: 'usd',
      amount: 8000,
      monthOffset: 1,
    );
    await _bill(
      db,
      'transfer',
      currency: 'USD',
      account: 'usd',
      type: 2,
      amount: 5000,
      toAccount: 'usd-target',
    );
    await _bill(
      db,
      'adjustment',
      currency: 'USD',
      account: 'usd',
      type: 3,
      amount: 6000,
    );
    await _bill(db, 'deleted', currency: 'USD', account: 'usd', amount: 7000);
    await db.softDeleteBill('deleted');
    await _bill(
      db,
      'internal',
      type: 1,
      amount: 100000,
      category: 'cat_aa_marker',
    );
    await _bill(db, 'cny-income', type: 1, amount: 500);
    await pumpPage(tester, const StatsPage(), db: db);
    expect(_trend(tester).data.barGroups.last.barRods.last.toY, 5);
    await _select(tester, '美元 USD');
    expect(_total(tester), 'USD 10.00');
    final chart = _trend(tester);
    expect(chart.data.barGroups.map((group) => group.barRods.first.toY), [
      40,
      0,
      0,
      0,
      30,
      10,
    ]);
    expect(chart.data.barGroups.last.barRods.last.toY, 20);
    expect(
      _tooltip(chart, 4, 0),
      '${DateTime(_month.year, _month.month - 1).month}月 支出\nUSD 30.00',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('MAX+1月支出与收入精确展示，饼图触摸和趋势提示保留末位', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = TestAppDatabase();
    await _account(db, 'usd', 'USD');
    const max = 9223372036854775807;
    for (final type in [0, 1]) {
      await _bill(
        db,
        '$type-max',
        type: type,
        amount: max,
        currency: 'USD',
        account: 'usd',
      );
      await _bill(
        db,
        '$type-one',
        type: type,
        amount: 1,
        currency: 'USD',
        account: 'usd',
      );
    }
    await pumpPage(tester, const StatsPage(), db: db);
    await _select(tester, '美元 USD');
    const exact = 'USD 92,233,720,368,547,758.08';
    expect(_total(tester), exact);
    expect(find.text('92,233,720,368,547,758.08 · 占本月 100%'), findsOneWidget);
    final chart = _trend(tester);
    expect(chart.data.maxY.isFinite, isTrue);
    expect(_tooltip(chart, 5, 0), '${_month.month}月 支出\n$exact');
    expect(_tooltip(chart, 5, 1), '${_month.month}月 收入\n$exact');
    final pieFinder = find.byType(PieChart);
    await tester.ensureVisible(pieFinder);
    await tester.tapAt(tester.getCenter(pieFinder) + const Offset(55, 0));
    await settleProviders(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-pie-tooltip')))
          .data,
      '餐饮 · $exact',
    );
    final rect = tester.getRect(
      find.byKey(const ValueKey('stats-expense-total')),
    );
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('未知历史币种按原始最小单位展示，无账币种保持独立空态', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _bill(db, 'unknown', amount: 1234);
    await db.customStatement('UPDATE bills SET currency = ? WHERE id = ?', [
      'XTS',
      'unknown',
    ]);
    await pumpPage(tester, const StatsPage(), db: db);
    expect(_total(tester), '¥ 0.00');
    await _select(tester, 'XTS（最小单位）');
    expect(_total(tester), 'XTS 1234 最小单位');
    expect(find.text('XTS 1234 最小单位 · 占本月 100%'), findsOneWidget);
    expect(_trend(tester).data.barGroups.last.barRods.first.toY, 1234);
    expect(
      _tooltip(_trend(tester), 5, 0),
      '${_month.month}月 支出\nXTS 1234 最小单位',
    );
    await _select(tester, '日元 JPY');
    expect(_total(tester), 'JPY 0');
    expect(find.text('本月暂无支出'), findsOneWidget);
    expect(find.byType(PieChart), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('切换月份重置已展开分类和滚动，不复用旧月份金额', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertCategory(
      id: 'lunch',
      name: '午餐',
      emoji: '🍜',
      kind: 0,
      sort: 0,
      parentId: 'cat_food',
    );
    await _bill(db, 'current', category: 'lunch', amount: 1000);
    await _bill(
      db,
      'previous',
      category: 'lunch',
      amount: 2000,
      monthOffset: -1,
    );
    await pumpPage(tester, const StatsPage(), db: db);
    await tester.tap(find.byKey(const ValueKey('category-stats-cat_food')));
    await settleProviders(tester);
    expect(find.text('分项金额 · 占本分类'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await settleProviders(tester);
    final scrollable = find.descendant(
      of: find.byType(StatsPage),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatsPage)),
    );
    container.read(selectedMonthProvider.notifier).shift(-1);
    await settleProviders(tester);
    expect(_total(tester), '¥ 20.00');
    expect(find.text('分项金额 · 占本分类'), findsNothing);
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
    expect(_trend(tester).data.barGroups.last.barRods.first.toY, 20);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('分类尚未加载不绘收入趋势，元数据到达后排除内部收入', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _bill(
      db,
      'internal',
      type: 1,
      amount: 100000,
      category: 'cat_aa_marker',
    );
    await _bill(db, 'income', type: 1, amount: 500);
    final controller = StreamController<List<Category>>();
    addTearDown(controller.close);
    await pumpPage(
      tester,
      const StatsPage(),
      db: db,
      overrides: [categoriesProvider.overrideWith((ref) => controller.stream)],
    );
    expect(find.text('正在加载分类…'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(PieChart), findsNothing);
    controller.add(await db.getAllCategories());
    await settleProviders(tester);
    expect(_trend(tester).data.barGroups.last.barRods.last.toY, 5);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('分类加载失败不显示可能包含内部收入的统计数字', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _bill(
      db,
      'internal',
      type: 1,
      amount: 100000,
      category: 'cat_aa_marker',
    );
    await pumpPage(
      tester,
      const StatsPage(),
      db: db,
      overrides: [
        categoriesProvider.overrideWith(
          (ref) => Stream<List<Category>>.error(StateError('test')),
        ),
      ],
    );
    expect(find.text('分类加载失败，暂无法统计'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(PieChart), findsNothing);
    expect(find.byKey(const ValueKey('stats-expense-total')), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final waitingMonth in [true, false]) {
    for (final failed in [false, true]) {
      testWidgets(
        '${waitingMonth ? '月账单' : '全部账单'}${failed ? '读取失败' : '尚未加载'}不展示假零统计',
        (tester) async {
          final db = TestAppDatabase();
          await db.getAllAccounts();
          await _bill(db, '真实支出', amount: 1000);
          final bills = await db.getAllBills();
          final categories = await db.getAllCategories();
          final controller = StreamController<List<Bill>>();
          addTearDown(controller.close);
          if (failed) controller.addError(StateError('账单流测试异常'));
          await pumpPage(
            tester,
            const StatsPage(),
            db: db,
            overrides: [
              categoriesProvider.overrideWith(
                (ref) => Stream.value(categories),
              ),
              monthBillsProvider.overrideWith(
                (ref) => waitingMonth ? controller.stream : Stream.value(bills),
              ),
              allBillsProvider.overrideWith(
                (ref) => waitingMonth ? Stream.value(bills) : controller.stream,
              ),
            ],
          );

          expect(find.text(failed ? '账单读取失败，请稍后重试' : '账单加载中…'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('stats-expense-total')),
            findsNothing,
          );
          expect(find.byType(BarChart), findsNothing);
          expect(find.byType(PieChart), findsNothing);
          expect(find.text('本月暂无支出'), findsNothing);
          if (waitingMonth && !failed) {
            controller.add(bills);
            await settleProviders(tester);
            expect(find.text('账单加载中…'), findsNothing);
            expect(_total(tester), '¥ 10.00');
            expect(_trend(tester).data.barGroups.last.barRods.first.toY, 10);
          }
          expect(tester.takeException(), isNull);
          await disposePage(tester, db);
        },
      );
    }
  }

  testWidgets('换月等待新账单期间不把旧月金额和图表放在新月标题下', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _bill(db, '旧月份支出', amount: 1000);
    await _bill(db, '新月份支出', amount: 2000, monthOffset: -1);
    final bills = await db.getAllBills();
    final initialMonth = _month;
    final targetMonth = DateTime(initialMonth.year, initialMonth.month - 1);
    final controller = StreamController<List<Bill>>();
    addTearDown(controller.close);
    await pumpPage(
      tester,
      const StatsPage(),
      db: db,
      overrides: [
        monthBillsProvider.overrideWith((ref) {
          final selected = ref.watch(selectedMonthProvider);
          return selected == initialMonth
              ? Stream.value(bills.where((bill) => bill.id == '旧月份支出').toList())
              : controller.stream;
        }),
      ],
    );
    expect(_total(tester), '¥ 10.00');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatsPage)),
    );
    container.read(selectedMonthProvider.notifier).selectMonth(targetMonth);
    await settleProviders(tester);

    expect(
      find.text('${targetMonth.year}年${targetMonth.month}月'),
      findsOneWidget,
    );
    expect(find.text('账单加载中…'), findsOneWidget);
    expect(find.byKey(const ValueKey('stats-expense-total')), findsNothing);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(PieChart), findsNothing);
    expect(find.text('¥ 10.00'), findsNothing);

    controller.addError(StateError('新月份读取失败'));
    await settleProviders(tester);
    expect(find.text('账单读取失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('stats-expense-total')), findsNothing);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(PieChart), findsNothing);
    expect(find.text('¥ 10.00'), findsNothing);

    controller.add(bills.where((bill) => bill.id == '新月份支出').toList());
    await settleProviders(tester);
    expect(find.text('账单加载中…'), findsNothing);
    expect(find.text('账单读取失败，请稍后重试'), findsNothing);
    expect(_total(tester), '¥ 20.00');
    expect(_trend(tester).data.barGroups.last.barRods.first.toY, 20);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
