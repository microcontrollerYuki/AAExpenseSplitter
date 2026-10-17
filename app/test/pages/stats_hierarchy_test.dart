import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/home_shell.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';

import '../helpers/test_support.dart';

Finder _group(String id) => find.byKey(ValueKey('category-stats-$id'));

Future<void> _addCategory(
  AppDatabase db,
  String id,
  String name, {
  String? parent,
  int kind = 0,
}) => db.upsertCategory(
  id: id,
  name: name,
  emoji: '🍜',
  kind: kind,
  sort: 0,
  parentId: parent,
);

Future<void> _addBill(
  AppDatabase db,
  String id,
  String categoryId,
  int amount, {
  int type = 0,
}) {
  final now = DateTime.now();
  return db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    categoryId: categoryId,
    accountId: 'acc_cash',
    dateMs: DateTime(now.year, now.month, 5, 12).millisecondsSinceEpoch,
    note: '统计样例 $id',
    createdAt: 77,
  );
}

Future<void> _expand(WidgetTester tester, String id) async {
  await tester.ensureVisible(_group(id));
  await tester.tap(_group(id));
  await settleProviders(tester);
}

void main() {
  testWidgets('一级汇总直属与二级各一次，分项占父类而非全月', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addCategory(db, 'breakfast', '早餐', parent: 'cat_food');
    await _addCategory(db, 'dinner', '晚餐', parent: 'cat_food');
    await _addBill(db, 'direct', 'cat_food', 1000);
    await _addBill(db, 'breakfast', 'breakfast', 2000);
    await _addBill(db, 'dinner', 'dinner', 3000);
    // 另一一级让父类总额 60 与全月 120 不同，以识别错误分母。
    await _addBill(db, 'other', 'cat_transport', 6000);
    await pumpPage(tester, const StatsPage(), db: db);

    expect(find.text('¥ 120.00'), findsOneWidget);
    expect(
      find.descendant(
        of: _group('cat_food'),
        matching: find.text('60.00 · 占本月 50%'),
      ),
      findsOneWidget,
    );
    expect(find.text('🍜 早餐'), findsNothing);
    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.map((section) => section.value), [60, 60]);

    await _expand(tester, 'cat_food');
    expect(find.text('分项金额 · 占本分类'), findsOneWidget);
    expect(find.text('未细分'), findsOneWidget);
    expect(find.text('10.00 · 17%'), findsOneWidget);
    expect(find.text('🍜 早餐'), findsOneWidget);
    expect(find.text('20.00 · 33%'), findsOneWidget);
    expect(find.text('🍜 晚餐'), findsOneWidget);
    expect(find.text('30.00 · 50%'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('没有二级的一级分类保持单行，点击不会出现空展开区', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addBill(db, 'transport', 'cat_transport', 1200);
    await pumpPage(tester, const StatsPage(), db: db);

    expect(find.text('12.00 · 占本月 100%'), findsOneWidget);
    await tester.ensureVisible(_group('cat_transport'));
    await tester.tap(_group('cat_transport'));
    await settleProviders(tester);
    expect(find.text('分项金额 · 占本分类'), findsNothing);
    expect(find.text('未细分'), findsNothing);
    expect(find.text('¥ 12.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('只有二级账单时父类仍汇总，展开不增加零额未细分', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addCategory(db, 'breakfast', '早餐', parent: 'cat_food');
    await _addBill(db, 'breakfast', 'breakfast', 2000);
    await pumpPage(tester, const StatsPage(), db: db);

    expect(find.text('20.00 · 占本月 100%'), findsOneWidget);
    await _expand(tester, 'cat_food');
    expect(find.text('🍜 早餐'), findsOneWidget);
    expect(find.text('20.00 · 100%'), findsOneWidget);
    expect(find.text('未细分'), findsNothing);
    expect(find.text('¥ 20.00'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('收入直属与二级在月摘要和趋势各计一次，排除AA内部收入', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addCategory(
      db,
      'bonus-child',
      '奖金补贴',
      parent: 'inc_salary',
      kind: 1,
    );
    await _addCategory(db, 'part-time', '兼职', parent: 'inc_salary', kind: 1);
    await _addBill(db, 'salary', 'inc_salary', 1000, type: 1);
    await _addBill(db, 'bonus', 'bonus-child', 2000, type: 1);
    await _addBill(db, 'part-time', 'part-time', 3000, type: 1);
    await _addBill(db, 'internal', 'cat_aa_marker', 99900, type: 1);
    await _addBill(db, 'expense', 'cat_food', 1000);
    await pumpPage(tester, const HomeShell(), db: db);

    expect(find.text('+60.00'), findsOneWidget);
    expect(find.text('+50.00'), findsOneWidget);
    // 内部挂账仍有账单行，但不进入摘要及收入柱。
    expect(find.text('+999.00'), findsOneWidget);
    await tester.tap(find.text('图表'));
    await settleProviders(tester);
    final trend = tester.widget<BarChart>(find.byType(BarChart));
    expect(trend.data.barGroups.last.barRods.first.toY, 10);
    expect(trend.data.barGroups.last.barRods.last.toY, 60);
    expect(find.text('¥ 10.00'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('当前统计页随二级迁移及删除转移刷新，账单金额和总额不变', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addCategory(db, 'breakfast', '早餐', parent: 'cat_food');
    await _addBill(db, 'direct', 'cat_food', 1000);
    await _addBill(db, 'breakfast', 'breakfast', 2000);
    await _addBill(db, 'transport', 'cat_transport', 3000);
    final original = await db.getAllBills();
    await pumpPage(tester, const StatsPage(), db: db);
    expect(find.text('30.00 · 占本月 50%'), findsNWidgets(2));

    await tester.runAsync(
      () => db.moveSubcategory(
        id: 'breakfast',
        expectedParentId: 'cat_food',
        targetParentId: 'cat_transport',
      ),
    );
    await settleProviders(tester);
    expect(
      find.descendant(
        of: _group('cat_food'),
        matching: find.text('10.00 · 占本月 17%'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _group('cat_transport'),
        matching: find.text('50.00 · 占本月 83%'),
      ),
      findsOneWidget,
    );
    await _expand(tester, 'cat_transport');
    expect(find.text('20.00 · 40%'), findsOneWidget);
    expect(find.text('30.00 · 60%'), findsOneWidget);
    expect(await db.getAllBills(), original);

    await tester.runAsync(() async {
      final preview = await db.previewCategoryDeletion('breakfast');
      final target = (await db.getAllCategories()).singleWhere(
        (category) => category.id == 'cat_food',
      );
      await db.deleteCategoryAndReassign(
        expected: preview,
        destination: CategoryDeleteDestination.existing(target),
      );
    });
    await settleProviders(tester);
    expect(find.text('¥ 60.00'), findsOneWidget);
    expect(find.text('30.00 · 占本月 50%'), findsNWidgets(2));
    expect(find.text('🍜 早餐'), findsNothing);
    expect(find.text('分项金额 · 占本分类'), findsNothing);
    final movedBill = (await db.getAllBills()).singleWhere(
      (bill) => bill.id == 'breakfast',
    );
    expect(movedBill.categoryId, 'cat_food');
    final originalFields =
        original.singleWhere((bill) => bill.id == 'breakfast').toJson()
          ..remove('categoryId');
    final remainingFields = movedBill.toJson()..remove('categoryId');
    expect(remainingFields, originalFields);
    await disposePage(tester, db);
  });

  testWidgets('零额二级账单展开显示零百分比，不产生NaN或Infinity', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addCategory(db, 'zero-share', '零额份额', parent: 'cat_food');
    // AA 奇数分平分可能产生合法零份额；其他分类有支出时仍会展示此组。
    await _addBill(db, 'zero-share', 'zero-share', 0);
    await _addBill(db, 'normal-expense', 'cat_transport', 1000);
    await pumpPage(tester, const StatsPage(), db: db);

    expect(find.text('¥ 10.00'), findsOneWidget);
    expect(
      find.descendant(
        of: _group('cat_food'),
        matching: find.text('0.00 · 占本月 0%'),
      ),
      findsOneWidget,
    );
    await _expand(tester, 'cat_food');
    expect(find.text('🍜 零额份额'), findsOneWidget);
    expect(find.text('0.00 · 0%'), findsOneWidget);
    expect(find.textContaining('NaN'), findsNothing);
    expect(find.textContaining('Infinity'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('超过十个有支出的分类仍全部进入饼图与分类列表', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    final categories = (await db.getAllCategories())
        .where((category) => category.kind == 0)
        .toList();
    expect(categories.length, greaterThan(10));
    for (var i = 0; i < categories.length; i++) {
      await _addBill(db, 'expense-$i', categories[i].id, (i + 1) * 100);
    }
    await pumpPage(tester, const StatsPage(), db: db);

    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections, hasLength(categories.length));
    expect(
      pie.data.sections.map((section) => section.value),
      unorderedEquals([for (var i = 1; i <= categories.length; i++) i]),
    );
    final expectedTotal = categories.length * (categories.length + 1) / 2;
    expect(
      pie.data.sections.fold<double>(0, (sum, section) => sum + section.value),
      expectedTotal,
    );
    expect(find.text('¥ ${expectedTotal.toStringAsFixed(2)}'), findsOneWidget);
    for (final category in categories) {
      expect(_group(category.id), findsOneWidget);
    }
    // 最小一类排在末尾，实际滚动也应能看到，不能只统计前十项。
    await tester.ensureVisible(_group(categories.first.id));
    await settleProviders(tester);
    expect(find.text('1.00 · 占本月 1%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('360×640窄屏长分类名可以展开和滚动且无布局溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _addCategory(db, 'long-parent', '家庭日常食品饮料餐饮聚餐外卖及其他超长一级分类名称');
    await _addCategory(
      db,
      'long-child',
      '早餐午餐晚餐下午茶甜品饮料及其他超长二级分类名称',
      parent: 'long-parent',
    );
    await _addBill(db, 'direct', 'long-parent', 1000);
    await _addBill(db, 'child', 'long-child', 2000);
    await pumpPage(tester, const StatsPage(), db: db);
    expect(tester.takeException(), isNull);

    await _expand(tester, 'long-parent');
    expect(find.text('20.00 · 67%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('近6个月收支趋势'));
    await settleProviders(tester);
    expect(find.byType(BarChart), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
