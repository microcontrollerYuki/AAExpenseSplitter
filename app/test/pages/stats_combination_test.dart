// R-06 专项：报表组合完整性与金额守恒。覆盖图表页自定义范围组合
//（范围 × 支出 / 收入 × 总览 / 原币）的分区守恒（趋势月分区、饼图扇区、
// 分类行合计都等于报表总额）、超十类完整展示、长名称与小屏、空态组合、
// 粒度互切与明细页隔离。
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/category_bills_sheet.dart';
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
    String currency = 'CNY',
    String accountId = 'acc_cash',
    required DateTime date,
  }) => db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    categoryId: categoryId,
    accountId: accountId,
    currency: currency,
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
    container.read(statsTypeProvider.notifier).select(type);
    if (originalCny) {
      container
          .read(statsViewProvider.notifier)
          .select(const ReportViewCurrency.original('CNY'));
    }
    container.read(selectedRangeProvider.notifier).select(range);
    await settleProviders(tester);
    return db;
  }

  /// 路由关闭后有界泵帧，避免数据库流的加载动画延长测试。
  Future<void> settleRoute(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(CategoryBillsSheet), matching: finder);

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
    // 使用分类行真实入口，不能仅直接调用开窗函数或假设 tap 已生效。
    final salaryRow = find.byKey(const ValueKey('category-stats-inc_salary'));
    await tester.ensureVisible(salaryRow);
    await tester.tap(salaryRow);
    await settleRoute(tester);
    expect(find.byType(CategoryBillsSheet), findsOneWidget);
    final sheet = tester.widget<CategoryBillsSheet>(
      find.byType(CategoryBillsSheet),
    );
    expect(sheet.category.mode, ReportCategoryMode.root);
    expect(sheet.category.id, 'inc_salary');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-condition')))
          .data,
      '2025年12月30日 ~ 2026年1月2日 · 收入 · 原币 CNY',
    );
    expect(inSheet(find.text('共 1 笔')), findsOneWidget);
    expect(inSheet(find.text('r06-i1')), findsOneWidget);
    expect(inSheet(find.text('r06-i2')), findsNothing);
    expect(inSheet(find.text('r06-out1')), findsNothing);
    expect(inSheet(find.text('r06-out2')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 3.00',
    );
    await tester.tap(find.byKey(const ValueKey('category-bills-close')));
    await settleRoute(tester);
    expect(find.byType(CategoryBillsSheet), findsNothing);
    final container = containerOf(tester);
    expect(container.read(statsGranularityProvider), StatsGranularity.range);
    expect(container.read(statsTypeProvider), 1);
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.original('CNY'),
    );
    expect(
      container.read(selectedRangeProvider),
      ReportDateRange(start: DateTime(2025, 12, 30), end: DateTime(2026, 1, 2)),
    );
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    // 跨年范围：12 月与 1 月两个分区之和 == 收入总额 5.00
    await scrollToTrend(tester);
    expect(find.text('2025年12月30日 ~ 2026年1月2日逐月收支趋势'), findsOneWidget);
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
      tester
          .widget<Text>(find.byKey(const ValueKey('stats-expense-total')))
          .data,
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
      tester
          .widget<Text>(find.byKey(const ValueKey('stats-income-total')))
          .data,
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
      tester
          .widget<Text>(find.byKey(const ValueKey('stats-income-total')))
          .data,
      '¥ 5.00',
    );
    container.read(statsTypeProvider.notifier).select(0);
    await settleProviders(tester);
    expect(find.text('本年暂无支出'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('点击范围标题确认新日期只更新图表范围，分类窗口沿用新条件', (tester) async {
    final db = await pumpStats(
      tester,
      range: ReportDateRange(
        start: DateTime(2026, 5, 1),
        end: DateTime(2026, 5, 31),
      ),
      type: 1,
      originalCny: true,
    );
    await addBill(
      db,
      'picked-first',
      type: 1,
      amount: 300,
      categoryId: 'inc_salary',
      date: DateTime(2026, 5, 15),
    );
    await addBill(
      db,
      'picked-last',
      type: 1,
      amount: 200,
      categoryId: 'inc_salary',
      date: DateTime(2026, 5, 18, 23, 59),
    );
    await addBill(
      db,
      'before-picked',
      type: 1,
      amount: 900,
      categoryId: 'inc_salary',
      date: DateTime(2026, 5, 14, 23, 59),
    );
    await addBill(
      db,
      'after-picked',
      type: 1,
      amount: 800,
      categoryId: 'inc_salary',
      date: DateTime(2026, 5, 19),
    );
    await addBill(
      db,
      'picked-expense',
      type: 0,
      amount: 100,
      categoryId: 'cat_food',
      date: DateTime(2026, 5, 16),
    );
    await settleProviders(tester);
    final container = containerOf(tester);
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);

    await tester.tap(find.byKey(const ValueKey('range-bar-select')));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    // 初始范围在同月，直接选择日期，不依赖长距离滚动。
    await tester.tap(find.text('15').first);
    await tester.pump();
    await tester.tap(find.text('18').first);
    await tester.pump();
    await tester.tap(find.text('确定'));
    await settleRoute(tester);

    final picked = ReportDateRange(
      start: DateTime(2026, 5, 15),
      end: DateTime(2026, 5, 18),
    );
    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(container.read(selectedRangeProvider), picked);
    expect(container.read(statsGranularityProvider), StatsGranularity.range);
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    expect(container.read(selectedMonthProvider), DateTime(2026, 5));
    expect(container.read(statsTypeProvider), 1);
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.original('CNY'),
    );
    expect(find.text('2026年5月15日 ~ 5月18日'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('stats-income-total')))
          .data,
      '¥ 5.00',
    );

    final salaryRow = find.byKey(const ValueKey('category-stats-inc_salary'));
    await tester.ensureVisible(salaryRow);
    await tester.tap(salaryRow);
    await settleRoute(tester);
    expect(find.byType(CategoryBillsSheet), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-condition')))
          .data,
      '2026年5月15日 ~ 5月18日 · 收入 · 原币 CNY',
    );
    expect(inSheet(find.text('共 2 笔')), findsOneWidget);
    expect(inSheet(find.text('r06-picked-first')), findsOneWidget);
    expect(inSheet(find.text('r06-picked-last')), findsOneWidget);
    expect(inSheet(find.text('r06-before-picked')), findsNothing);
    expect(inSheet(find.text('r06-after-picked')), findsNothing);
    expect(inSheet(find.text('r06-picked-expense')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 5.00',
    );
    await tester.tap(find.byKey(const ValueKey('category-bills-close')));
    await settleRoute(tester);
    expect(find.byType(CategoryBillsSheet), findsNothing);
    expect(container.read(selectedRangeProvider), picked);
    expect(container.read(statsGranularityProvider), StatsGranularity.range);
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    expect(container.read(statsTypeProvider), 1);
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.original('CNY'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('点击范围标题修改日期后取消，保留原范围及独立明细模式', (tester) async {
    final seeded = ReportDateRange(
      start: DateTime(2026, 5, 1),
      end: DateTime(2026, 5, 31),
    );
    final db = await pumpStats(
      tester,
      range: seeded,
      type: 1,
      originalCny: true,
    );
    await addBill(
      db,
      'unchanged-income',
      type: 1,
      amount: 700,
      categoryId: 'inc_salary',
      date: DateTime(2026, 5, 5),
    );
    await settleProviders(tester);
    final container = containerOf(tester);

    await tester.tap(find.byKey(const ValueKey('range-bar-select')));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.text('15').first);
    await tester.pump();
    await tester.tap(find.text('18').first);
    await tester.pump();
    await tester.tap(find.byType(CloseButton));
    await settleRoute(tester);

    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(container.read(selectedRangeProvider), seeded);
    expect(container.read(statsGranularityProvider), StatsGranularity.range);
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    expect(container.read(selectedMonthProvider), DateTime(2026, 5));
    expect(container.read(statsTypeProvider), 1);
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.original('CNY'),
    );
    expect(find.text('2026年5月1日 ~ 5月31日'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('stats-income-total')))
          .data,
      '¥ 7.00',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('范围选择器约束初始越界日期，取消不改变原月份及已平移范围', (tester) async {
    final db = await pumpPage(tester, const StatsPage());
    final container = containerOf(tester);
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(1999, 12));
    await settleProviders(tester);

    // 尚无共享范围：首次打开从越界月份生成合法草稿，取消不进入范围粒度。
    await tester.tap(find.text('范围'));
    await tester.pumpAndSettle();
    final firstDialog = tester.widget<DateRangePickerDialog>(
      find.byType(DateRangePickerDialog),
    );
    expect(firstDialog.initialDateRange!.start, DateTime(2000));
    expect(firstDialog.initialDateRange!.end, DateTime(2000));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(CloseButton));
    await settleRoute(tester);
    expect(container.read(selectedRangeProvider), isNull);
    expect(container.read(selectedMonthProvider), DateTime(1999, 12));
    expect(container.read(statsGranularityProvider), StatsGranularity.month);
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);

    // 范围平移越过下界或上界：仅选择器草稿截到允许日期，取消保留原范围。
    final cases = [
      (
        original: ReportDateRange(
          start: DateTime(2000, 1, 1),
          end: DateTime(2000, 1, 3),
        ).shiftDays(-1),
        start: DateTime(2000),
        end: DateTime(2000, 1, 2),
      ),
      (
        original: ReportDateRange(
          start: DateTime(2100, 12, 29),
          end: DateTime(2100, 12, 31),
        ).shiftDays(1),
        start: DateTime(2100, 12, 30),
        end: DateTime(2100, 12, 31),
      ),
    ];
    for (final testCase in cases) {
      container.read(selectedRangeProvider.notifier).select(testCase.original);
      container
          .read(statsGranularityProvider.notifier)
          .select(StatsGranularity.range);
      await settleProviders(tester);
      await tester.tap(find.byKey(const ValueKey('range-bar-select')));
      await tester.pumpAndSettle();
      final dialog = tester.widget<DateRangePickerDialog>(
        find.byType(DateRangePickerDialog),
      );
      expect(dialog.initialDateRange!.start, testCase.start);
      expect(dialog.initialDateRange!.end, testCase.end);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(CloseButton));
      await settleRoute(tester);
      expect(container.read(selectedRangeProvider), testCase.original);
      expect(container.read(selectedMonthProvider), DateTime(1999, 12));
      expect(container.read(statsGranularityProvider), StatsGranularity.range);
      expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    }
    await disposePage(tester, db);
  });

  testWidgets('范围×USD和JPY×二级及未分类折算守恒，真实原币切换保持隔离', (tester) async {
    final range = ReportDateRange(
      start: DateTime(2026, 5, 31),
      end: DateTime(2026, 6, 1),
    );
    // pumpStats 沿用固定汇率 helper：USD→CNY=7，JPY→CNY=0.05，不联网。
    final db = await pumpStats(tester, range: range);
    for (final code in ['USD', 'JPY']) {
      await db.upsertAccount(
        id: 'r06-$code',
        name: code,
        emoji: '💳',
        type: 3,
        initBalance: 0,
        includeNetWorth: true,
        sort: 20,
        currency: code,
      );
    }
    await db.upsertCategory(
      id: 'r06-meal',
      name: '精确午餐',
      emoji: '🥣',
      kind: 0,
      sort: 0,
      parentId: 'cat_food',
    );
    final entries = [
      (id: 'usd-child', amount: 101, code: 'USD', child: true, day: 0),
      (id: 'usd-none', amount: 102, code: 'USD', child: false, day: 1),
      (id: 'jpy-child', amount: 11, code: 'JPY', child: true, day: 0),
      (id: 'jpy-none', amount: 12, code: 'JPY', child: false, day: 1),
      (id: 'cny-child', amount: 31, code: 'CNY', child: true, day: 1),
    ];
    for (final entry in entries) {
      await addBill(
        db,
        entry.id,
        type: 0,
        amount: entry.amount,
        categoryId: entry.child ? 'r06-meal' : null,
        currency: entry.code,
        accountId: entry.code == 'CNY' ? 'acc_cash' : 'r06-${entry.code}',
        date: DateTime(2026, 5, 31 + entry.day, 12),
      );
    }
    await settleProviders(tester);
    final originalBills = [
      for (final bill in await db.getAllBills())
        (id: bill.id, amount: bill.amount, code: bill.currency),
    ];
    final container = containerOf(tester);

    Future<Finder> showCurrencyFilter() async {
      final filter = find.byKey(const ValueKey('currency-filter'));
      // ListView 懒加载会卸载顶部筛选；先有界回滚至节点构建，再定位。
      for (var i = 0; i < 8 && filter.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, 300));
        await settleProviders(tester);
      }
      expect(filter, findsOneWidget);
      await tester.ensureVisible(filter);
      await settleProviders(tester);
      return filter;
    }

    Future<void> checkPartition(
      String total,
      double pieTotal,
      List<double> monthly,
    ) async {
      await showCurrencyFilter();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('stats-expense-total')))
            .data,
        total,
      );
      final pie = tester.widget<PieChart>(find.byType(PieChart));
      expect(pie.data.sections.length, 2);
      expect(
        pie.data.sections.fold(0.0, (sum, section) => sum + section.value),
        closeTo(pieTotal, 0.000001),
      );
      await scrollToTrend(tester);
      final chart = tester.widget<BarChart>(find.byType(BarChart));
      expect(chart.data.barGroups.length, 2);
      for (var i = 0; i < monthly.length; i++) {
        expect(
          chart.data.barGroups[i].barRods[0].toY,
          closeTo(monthly[i], 0.000001),
        );
      }
      expect(sumRods(tester, rodIndex: 0), closeTo(pieTotal, 0.000001));
    }

    Future<void> selectCurrency(String label) async {
      final filter = await showCurrencyFilter();
      await tester.tap(filter);
      await settleProviders(tester);
      await tester.tap(find.text(label).last);
      await settleProviders(tester);
    }

    // 逐笔最小单位精确折算：707+714+55+60+31=1567 分。
    expect(find.textContaining('7.93 · 占范围内 51%'), findsOneWidget);
    expect(find.textContaining('7.74 · 占范围内 49%'), findsOneWidget);
    final root = find.byKey(const ValueKey('category-stats-cat_food'));
    await tester.ensureVisible(root);
    await tester.tap(root);
    await settleProviders(tester);
    final childRow = find.text('🥣 精确午餐');
    await tester.ensureVisible(childRow);
    await tester.tap(childRow);
    await settleRoute(tester);
    expect(find.byType(CategoryBillsSheet), findsOneWidget);
    final childSheet = tester.widget<CategoryBillsSheet>(
      find.byType(CategoryBillsSheet),
    );
    expect(childSheet.category.mode, ReportCategoryMode.exact);
    expect(childSheet.category.id, 'r06-meal');
    expect(inSheet(find.text('共 3 笔')), findsOneWidget);
    expect(inSheet(find.text('r06-usd-child')), findsOneWidget);
    expect(inSheet(find.text('r06-jpy-child')), findsOneWidget);
    expect(inSheet(find.text('r06-cny-child')), findsOneWidget);
    expect(inSheet(find.text('r06-usd-none')), findsNothing);
    expect(inSheet(find.text('r06-jpy-none')), findsNothing);
    expect(inSheet(find.text('¥ 7.07')), findsOneWidget);
    expect(inSheet(find.text('¥ 0.55')), findsOneWidget);
    expect(inSheet(find.text('¥ 0.31')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 7.93',
    );
    await tester.tap(find.byKey(const ValueKey('category-bills-close')));
    await settleRoute(tester);
    await checkPartition('¥ 15.67', 15.67, [7.62, 8.05]);

    await selectCurrency('美元 USD');
    expect(find.textContaining('1.01 · 占范围内 50%'), findsOneWidget);
    expect(find.textContaining('1.02 · 占范围内 50%'), findsOneWidget);
    await checkPartition('USD 2.03', 2.03, [1.01, 1.02]);

    await selectCurrency('日元 JPY');
    expect(find.textContaining('11 · 占范围内 48%'), findsOneWidget);
    expect(find.textContaining('12 · 占范围内 52%'), findsOneWidget);
    final uncategorized = find.byKey(
      const ValueKey('category-stats-uncategorized'),
    );
    await tester.ensureVisible(uncategorized);
    await tester.tap(uncategorized);
    await settleRoute(tester);
    expect(find.byType(CategoryBillsSheet), findsOneWidget);
    expect(inSheet(find.text('共 1 笔')), findsOneWidget);
    expect(inSheet(find.text('r06-jpy-none')), findsOneWidget);
    expect(inSheet(find.text('r06-usd-none')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-condition')))
          .data,
      '2026年5月31日 ~ 6月1日 · 支出 · 原币 JPY',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 JPY 12',
    );
    await tester.tap(find.byKey(const ValueKey('category-bills-close')));
    await settleRoute(tester);
    await checkPartition('JPY 23', 23, [11, 12]);

    await selectCurrency('总览 · 折合 CNY');
    await checkPartition('¥ 15.67', 15.67, [7.62, 8.05]);
    expect(container.read(statsGranularityProvider), StatsGranularity.range);
    expect(container.read(selectedRangeProvider), range);
    expect(container.read(statsTypeProvider), 0);
    expect(container.read(billsPeriodModeProvider), BillsPeriodMode.month);
    expect([
      for (final bill in await db.getAllBills())
        (id: bill.id, amount: bill.amount, code: bill.currency),
    ], originalBills);
    expect(tester.takeException(), isNull);
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
