import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';

import '../helpers/test_support.dart';

void main() {
  int ms(int day, [int hour = 12]) => DateTime(
    DateTime.now().year,
    DateTime.now().month,
    day,
    hour,
  ).millisecondsSinceEpoch;

  testWidgets('无支出显示空态提示', (tester) async {
    final db = await pumpPage(tester, const StatsPage());
    expect(find.text('本月暂无支出'), findsOneWidget);
    expect(find.text('近6个月收支趋势'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('多分类支出渲染图例与饼图', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    Future<void> add(String id, String? catId, int amount, int day) =>
        db.upsertBill(
          id: id,
          type: 0,
          amount: amount,
          categoryId: catId,
          accountId: 'acc_cash',
          dateMs: ms(day),
        );
    await add('b1', 'cat_food', 8800, 1);
    await add('b2', 'cat_food', 1200, 2); // 同类累加
    await add('b3', 'cat_transport', 3000, 3);
    await add('b4', null, 500, 4);
    // 模拟历史坏引用；正常保存接口已禁止写入不存在的分类。
    await db.customStatement('UPDATE bills SET category_id = ? WHERE id = ?', [
      'ghost_cat',
      'b4',
    ]);
    await add('b5', null, 100, 5); // 无分类 → 未分类

    await pumpPage(tester, const StatsPage(), db: db);

    expect(find.text('本月暂无支出'), findsNothing);
    expect(find.text('¥ 136.00'), findsOneWidget); // 总支出
    // 图例行：餐饮 100.00 · 74%；交通 30.00 · 22%；未分类 6.00 · 4%
    expect(find.textContaining('餐饮'), findsOneWidget);
    expect(find.textContaining('交通'), findsOneWidget);
    expect(find.textContaining('未分类'), findsOneWidget);
    expect(find.text('6.00 · 占本月 4%'), findsOneWidget);
    // 候选 chip 值与趋势卡
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.text('近6个月收支趋势'), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('趋势含 AA 往来收入不计入收入柱', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'aa',
      type: 1,
      amount: 100000, // 1000.00 但属于内部挂账
      categoryId: 'cat_aa_marker',
      accountId: 'acc_cash',
      dateMs: ms(2),
    );
    await db.upsertBill(
      id: 'real',
      type: 1,
      amount: 5000,
      categoryId: 'inc_salary',
      accountId: 'acc_bank',
      dateMs: ms(3),
    );

    await pumpPage(tester, const StatsPage(), db: db);
    expect(find.text('本月暂无支出'), findsOneWidget);
    expect(find.text('近6个月收支趋势'), findsOneWidget);
    final trend = tester.widget<BarChart>(find.byType(BarChart));
    expect(trend.data.barGroups.last.barRods.last.toY, 50);

    await disposePage(tester, db);
  });

  testWidgets('跨月账单只计入对应月（趋势窗口）', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    final now = DateTime.now();
    await db.upsertBill(
      id: 'prev',
      type: 0,
      amount: 20000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: DateTime(now.year, now.month - 1, 10).millisecondsSinceEpoch,
    );
    await db.upsertBill(
      id: 'cur',
      type: 0,
      amount: 3000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(4),
    );

    await pumpPage(tester, const StatsPage(), db: db);
    // 本月饼图只统计本月 30.00
    expect(find.text('¥ 30.00'), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('下月零点支出不进入本月饼图，本月总额与趋势支出一致', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    final now = DateTime.now();
    await db.upsertBill(
      id: 'current-month',
      type: 0,
      amount: 1500,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: DateTime(now.year, now.month, 1).millisecondsSinceEpoch,
    );
    await db.upsertBill(
      id: 'next-month-midnight',
      type: 0,
      amount: 90000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: DateTime(now.year, now.month + 1, 1).millisecondsSinceEpoch,
    );

    await pumpPage(tester, const StatsPage(), db: db);
    expect(find.text('¥ 15.00'), findsOneWidget);
    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.single.value, 15);
    final trend = tester.widget<BarChart>(find.byType(BarChart));
    expect(trend.data.barGroups, hasLength(6));
    expect(trend.data.barGroups.last.barRods.first.toY, 15);

    await disposePage(tester, db);
  });
}
