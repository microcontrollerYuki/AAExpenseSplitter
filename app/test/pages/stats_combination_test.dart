// R-06 专项：报表组合完整性与金额守恒。覆盖图表页自定义范围组合
//（范围 × 支出 / 收入 × 总览 / 原币）的分区守恒（趋势月分区、饼图扇区、
// 分类行合计都等于报表总额）、超十类完整展示、长名称与小屏、空态组合、
// 粒度互切与明细页隔离。
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/report_filter.dart';

import '../helpers/test_support.dart';

void main() {
  Future<void> addBill(
    AppDatabase db,
    String id, {
    required int type,
    required int amount,
    String? categoryId,
    required DateTime date,
  }) => db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    categoryId: categoryId,
    accountId: 'acc_cash',
    dateMs: date.millisecondsSinceEpoch,
    note: 'r06-$id',
  );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(StatsPage)));

  Future<AppDatabase> pumpStats(
    WidgetTester tester, {
    required ReportDateRange range,
    int type = 0,
    bool originalCny = false,
  }) async {
    final db = await pumpPage(tester, const StatsPage());
    final container = containerOf(tester);
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2026, 5));
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.range);
    container
        .read(statsTypeProvider.notifier)
        .select(type);
    if (originalCny) {
      container
          .read(statsViewProvider.notifier)
          .select(const ReportViewCurrency.original('CNY'));
    }
    container.read(selectedRangeProvider.notifier).select(range);
    await settleProviders(tester);
    return db;
  }

  double sumRods(WidgetTester tester, {required int rodIndex}) {
    final chart = tester.widget<BarChart>(find.byType(BarChart));
    var sum = 0.0;
    for (final group in chart.data.barGroups) {
      sum += group.barRods[rodIndex].toY;
    }
    return sum;
  }

  /// 趋势卡在懒加载列表下方，滚动直到柱状图构建。
  Future<void> scrollToTrend(WidgetTester tester) async {
    for (var i = 0; i < 8 && find.byType(BarChart).evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await settleProviders(tester);
    }
    expect(find.byType(BarChart), findsOneWidget);
  }

  testWidgets('范围×支出×总览：月分区、扇区与分类行合计都等于报表总额', (tester) async {
    final db = await pumpStats(
      tester,
      range: ReportDateRange(
        start: DateTime(2026, 9, 28),
        end: DateTime(2026, 11, 3),
      ),
    );
    await addBill(
      db,
      'e1',
      type: 0,
      amount: 100,
      categoryId: 'cat_food',
      date: DateTime(2026, 9, 28),
    );
    await addBill(
      db,
      'i1',
      type: 1,
      amount: 500,
      categoryId: 'inc_salary',
      date: DateTime(2026, 10, 5),
    );
    await addBill(
      db,
      'e2',
      type: 0,
      amount: 200,
      categoryId: 'cat_transport',
      date: DateTime(2026, 11, 3),
    );
    // 范围外：开始前与结束日次日
    await addBill(
      db,
      'out1',
      type: 0,
      amount: 999,
      categoryId: 'cat_food',
      date: DateTime(2026, 9, 27),
    );
    await addBill(
      db,
      'out2',
      type: 1,
      amount: 888,
      date: DateTime(2026, 11, 4),
    );
    await settleProviders(tester);

    expect(find.text('范围内支出'), findsOneWidget);
    expect(find.text('范围内暂无支出'), findsNothing);
    // 分类行合计 = 报表总额 = 3.00（范围外账单不计入）
    expect(find.textContaining('1.00 · 占范围内 33%'), findsOneWidget);
    expect(find.textContaining('2.00 · 占范围内 67%'), findsOneWidget);
    // 摘要行（范围模式展示全年式合计）
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('year-summary-收入'))).data,
      '+¥ 5.00',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('year-summary-支出'))).data,
      '¥ 3.00',
    );
    // 守恒：饼图扇区之和 == 报表总额
    final pie = tester.widget<PieChart>(find.byType(PieChart));
    var pieSum = 0.0;
    for (final section in pie.data.sections) {
      pieSum += section.value;
    }
    expect(pieSum, closeTo(3.0, 0.001));
    // 趋势月分区（9/10/11 三个月）之和 == 报表总额
    await scrollToTrend(tester);
    expect(sumRods(tester, rodIndex: 0), closeTo(3.0, 0.001));
    expect(sumRods(tester, rodIndex: 1), closeTo(5.0, 0.001));
    await disposePage(tester, db);
  });

  testWidgets('范围×收入×原币CNY：跨年范围趋势分月守恒，窗口条件随范围', (tester) async {
    final db = await pumpStats(
      tester,
      range: ReportDateRange(
        start: DateTime(2025, 12, 30),
        end: DateTime(2026, 1, 2),
      ),
      type: 1,
      originalCny: true,
    );
    await addBill(
      db,
      'i1',
      type: 1,
      amount: 300,
      categoryId: 'inc_salary',
      date: DateTime(2025, 12, 30),
    );
    await addBill(
      db,
      'i2',
      type: 1,
      amount: 200,
      categoryId: 'inc_bonus',
      date: DateTime(2026, 1, 2),
    );
    await addBill(
      db,
      'out1',
      type: 1,
      amount: 400,
      date: DateTime(2025, 12, 29),
    );
    await addBill(
      db,
      'out2',
      type: 0,
      amount: 100,
      categoryId: 'cat_food',
      date: DateTime(2026, 1, 3),
    );
    await settleProviders(tester);

    expect(find.text('范围内收入'), findsOneWidget);
    expect(find.textContaining('3.00 · 占范围内 60%'), findsOneWidget);
    expect(find.textContaining('2.00 · 占范围内 40%'), findsOneWidget);
    expect(
      find.text('2025年12月30日 ~ 2026年1月2日逐月收支趋势'),
      findsNothing, // 标题在视口外，滚动后断言
    );
    // 跨年范围：12 月与 1 月两个分区之和 == 收入总额 5.00
    await scrollToTrend(tester);
    expect(
      find.text('2025年12月30日 ~ 2026年1月2日逐月收支趋势'),
      findsOneWidget,
    );
    expect(sumRods(tester, rodIndex: 1), closeTo(5.0, 0.001));
    expect(sumRods(tester, rodIndex: 0), closeTo(0.0, 0.001));
    await disposePage(tester, db);
  });

  testWidgets('超十类完整展示且金额守恒（12 个一级分类）', (tester) async {
    final db = await pumpStats(
      tester,
      range: ReportDateRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 31),
      ),
    );
    const categories = [
      'cat_food',
      'cat_shopping',
      'cat_daily',
      'cat_transport',
      'cat_housing',
      'cat_fun',
      'cat_medical',
      'cat_edu',
      'cat_social',
      'cat_pet',
      'cat_comm',
      'cat_other_exp',
    ];
    for (var i = 0; i < categories.length; i++) {
      await addBill(
        db,
        'c$i',
        type: 0,
        amount: 100,
        categoryId: categories[i],
        date: DateTime(2026, 5, 10),
      );
    }
    await settleProviders(tester);

    final pie = tester.widget<PieChart>(find.byType(PieChart));
    expect(pie.data.sections.length, 12);
    var pieSum = 0.0;
    for (final section in pie.data.sections) {
      pieSum += section.value;
    }
    expect(pieSum, closeTo(12.0, 0.001));
    // 每个一级分类的行都存在（完整展示，无静默丢弃）
    for (final category in categories) {
      expect(
        find.byKey(ValueKey('category-stats-$category')),
        findsOneWidget,
        reason: '缺少分类行：$category',
      );
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('stats-expense-total'))).data,
      '¥ 12.00',
    );
    expect(find.textContaining('1.00 · 占范围内 8%'), findsNWidgets(12));
    await disposePage(tester, db);
  });

  testWidgets('小屏 + 长分类名称不溢出（范围×收入）', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await pumpStats(
      tester,
      range: ReportDateRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 31),
      ),
      type: 1,
    );
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: 'cat_long_name',
            name: '一个特别特别长的分类名称用来验证窄屏与长名称不会溢出渲染',
            emoji: '📜',
            kind: 1,
          ),
        );
    await addBill(
      db,
      'ln1',
      type: 1,
      amount: 500,
      categoryId: 'cat_long_name',
      date: DateTime(2026, 5, 10),
    );
    await settleProviders(tester);

    expect(find.textContaining('一个特别特别长的分类名称'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('stats-income-total'))).data,
      '¥ 5.00',
    );
    // 列表滚动到底部也不产生溢出异常
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await settleProviders(tester);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('空态组合：范围支出 / 范围收入 / 年粒度空态', (tester) async {
    final db = await pumpStats(
      tester,
      range: ReportDateRange(
        start: DateTime(2001, 1, 1),
        end: DateTime(2001, 1, 2),
      ),
    );
    await db.upsertBill(
      id: 'may-income',
      type: 1,
      amount: 500,
      categoryId: 'inc_salary',
      accountId: 'acc_cash',
      dateMs: DateTime(2026, 5, 10, 12).millisecondsSinceEpoch,
      note: 'r06-may-income',
    );
    await settleProviders(tester);

    expect(find.text('范围内暂无支出'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('year-summary-结余'))).data,
      '¥ 0.00',
    );
    // 切收入：范围（2001）内同样无收入 → 收入空态
    final container = containerOf(tester);
    container.read(statsTypeProvider.notifier).select(1);
    await settleProviders(tester);
    expect(find.text('范围内收入'), findsOneWidget);
    expect(find.text('范围内暂无收入'), findsOneWidget);
    // 切年粒度（2026 年 5 月有收入）→ 年收入有数据；再切回支出 → 年支出空态
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.year);
    container.read(selectedYearProvider.notifier).selectYear(2026);
    await settleProviders(tester);
    expect(find.text('本年收入'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('stats-income-total'))).data,
      '¥ 5.00',
    );
    container.read(statsTypeProvider.notifier).select(0);
    await settleProviders(tester);
    expect(find.text('本年暂无支出'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('粒度互切保留范围选择，明细页模式不受影响', (tester) async {
    final range = ReportDateRange(
      start: DateTime(2026, 5, 1),
      end: DateTime(2026, 5, 31),
    );
    final db = await pumpStats(tester, range: range);
    await addBill(
      db,
      'i1',
      type: 1,
      amount: 500,
      categoryId: 'inc_salary',
      date: DateTime(2026, 5, 10),
    );
    await settleProviders(tester);

    final container = containerOf(tester);
    // 范围条显示共享范围；切年再切回，范围保留
    expect(find.text('2026年5月1日 ~ 5月31日'), findsOneWidget);
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.year);
    await settleProviders(tester);
    expect(find.text('2026年'), findsOneWidget);
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.range);
    await settleProviders(tester);
    expect(find.text('2026年5月1日 ~ 5月31日'), findsOneWidget);
    expect(container.read(selectedRangeProvider), range);
    // 明细页周期模式保持按月（范围粒度只改图表页自身）
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    await disposePage(tester, db);
  });
}
