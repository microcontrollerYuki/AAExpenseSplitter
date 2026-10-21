// R-04 专项：图表页收入 / 支出切换。覆盖默认支出回归、收入分类与占比、
// 内部分类收入排除、日期 / 币种一致性、收入空态、年粒度收入与折算收入。
// 数值均按精确断言：converted 默认（CNY 恒等 / USD×7）与原币 CNY（无前缀）。
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  int ms(int m, int d, [int hour = 12]) =>
      DateTime(2026, m, d, hour).millisecondsSinceEpoch;

  Future<void> addBill(
    AppDatabase db,
    String id, {
    required int type,
    required int amount,
    String? categoryId,
    String date = '0510',
    String currency = 'CNY',
    int? accountAmount,
  }) => db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    categoryId: categoryId,
    accountId: 'acc_cash',
    dateMs: ms(int.parse(date.substring(0, 2)), int.parse(date.substring(2))),
    note: 'r04-$id',
    currency: currency,
    accountAmount: accountAmount,
  );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(StatsPage)));

  Future<AppDatabase> pumpStats(WidgetTester tester) async {
    final db = await pumpPage(tester, const StatsPage());
    final container = containerOf(tester);
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2026, 5));
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.month);
    await settleProviders(tester);
    return db;
  }

  Future<void> tapType(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('stats-type')),
        matching: find.text(label),
      ),
    );
    await settleProviders(tester);
  }

  String totalText(WidgetTester tester, String key) => tester
      .widget<Text>(find.byKey(ValueKey(key)))
      .data!;

  testWidgets('默认仍为支出饼图，收入账单不影响', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'ex1', type: 0, amount: 100, categoryId: 'cat_food');
    await addBill(db, 'in1', type: 1, amount: 500, categoryId: 'inc_salary');
    await settleProviders(tester);

    expect(find.text('本月支出'), findsOneWidget);
    expect(totalText(tester, 'stats-expense-total'), '¥ 1.00');
    expect(find.textContaining('工资'), findsNothing);
    expect(find.byKey(const ValueKey('stats-income-total')), findsNothing);
    await disposePage(tester, db);
  });

  testWidgets('切收入显示收入分类、金额与占比', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'ex1', type: 0, amount: 100, categoryId: 'cat_food');
    await addBill(db, 'in1', type: 1, amount: 500, categoryId: 'inc_salary');
    await addBill(db, 'in2', type: 1, amount: 500, categoryId: 'inc_bonus');
    await settleProviders(tester);

    await tapType(tester, '收入');

    expect(find.text('本月收入'), findsOneWidget);
    expect(find.text('本月支出'), findsNothing);
    expect(totalText(tester, 'stats-income-total'), '¥ 10.00');
    // 分类排行：两类各 50%，支出分类行消失
    expect(find.textContaining('工资'), findsOneWidget);
    expect(find.textContaining('奖金'), findsOneWidget);
    expect(find.textContaining('占本月 50%'), findsNWidgets(2));
    expect(find.textContaining('餐饮'), findsNothing);
    await disposePage(tester, db);
  });

  testWidgets('内部分类收入（kind=2）不计入收入饼图', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'in1', type: 1, amount: 500, categoryId: 'inc_salary');
    // AA 往来（cat_aa_marker，kind=2）的内部应收不进收支统计
    await addBill(db, 'aa1', type: 1, amount: 999, categoryId: 'cat_aa_marker');
    await settleProviders(tester);

    await tapType(tester, '收入');

    expect(totalText(tester, 'stats-income-total'), '¥ 5.00');
    expect(find.textContaining('AA往来'), findsNothing);
    await disposePage(tester, db);
  });

  testWidgets('切月与切币种不改动收支维度，空月显示收入空态', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'in1', type: 1, amount: 500, categoryId: 'inc_salary');
    await settleProviders(tester);
    await tapType(tester, '收入');
    expect(find.text('本月收入'), findsOneWidget);

    final container = containerOf(tester);
    // 切到无收入的月份：类型保持收入，显示空态；币种切换同样不影响类型
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2026, 6));
    await settleProviders(tester);
    expect(find.text('本月收入'), findsOneWidget);
    expect(find.text('本月暂无收入'), findsOneWidget);
    // 空态下合计行仍在，数值为零
    expect(totalText(tester, 'stats-income-total'), '¥ 0.00');

    container
        .read(statsViewProvider.notifier)
        .select(const ReportViewCurrency.original('CNY'));
    await settleProviders(tester);
    expect(find.text('本月收入'), findsOneWidget);

    // 切回有收入的月份：收入类型保持（合计行恒带 ¥ 前缀，与支出合计一致）
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2026, 5));
    await settleProviders(tester);
    expect(find.text('本月收入'), findsOneWidget);
    expect(totalText(tester, 'stats-income-total'), '¥ 5.00');
    await disposePage(tester, db);
  });

  testWidgets('年粒度收入：仅统计当年收入分类', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'in1', type: 1, amount: 500, categoryId: 'inc_salary');
    // 去年的收入不计入本年
    await db.upsertBill(
      id: 'in-old',
      type: 1,
      amount: 900,
      categoryId: 'inc_salary',
      accountId: 'acc_cash',
      dateMs: DateTime(2025, 12, 20, 12).millisecondsSinceEpoch,
      note: 'r04-in-old',
    );
    final container = containerOf(tester);
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.year);
    await settleProviders(tester);

    await tapType(tester, '收入');

    expect(find.text('本年收入'), findsOneWidget);
    expect(totalText(tester, 'stats-income-total'), '¥ 5.00');
    expect(find.textContaining('占本年 100%'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('折算收入：USD 收入按冻结快照折合 CNY 汇入总额', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'in-cny', type: 1, amount: 500, categoryId: 'inc_salary');
    // $1.10 × 7 = ¥7.70（固定缓存快照 USD→CNY = 7）
    await addBill(
      db,
      'in-usd',
      type: 1,
      amount: 110,
      categoryId: 'inc_bonus',
      currency: 'USD',
      accountAmount: 110,
    );
    await settleProviders(tester);

    await tapType(tester, '收入');

    expect(totalText(tester, 'stats-income-total'), '¥ 12.70');
    expect(find.textContaining('工资'), findsOneWidget);
    expect(find.textContaining('奖金'), findsOneWidget);
    await disposePage(tester, db);
  });
}
