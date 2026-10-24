// R-08：真实图表入口、月历与每日明细。所有数据来自内存数据库，
// 汇率使用固定缓存；不运行真实网络、设备或文件导入。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/calendar_day_sheet.dart';
import 'package:aa_expense_splitter/pages/calendar_stats_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/calendar_report.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

import '../helpers/test_support.dart';

typedef _CalendarHarness = ({AppDatabase db, ProviderContainer container});

Finder _key(String value) => find.byKey(ValueKey(value));

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data!;

Finder _inDaySheet(Finder finder) =>
    find.descendant(of: find.byType(CalendarDaySheet), matching: finder);

Future<_CalendarHarness> _pumpStats(
  WidgetTester tester, {
  AppDatabase? database,
  ExchangeRateService? rateService,
  List<dynamic> overrides = const [],
}) async {
  final db = await pumpPage(
    tester,
    const StatsPage(),
    db: database,
    rateService: rateService,
    overrides: overrides,
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(StatsPage)),
  );
  // 与日历刻意选不同月份，避免共享错误被同月样例掩盖。
  container.read(selectedMonthProvider.notifier).selectMonth(DateTime(2026, 5));
  container.read(calendarMonthProvider.notifier).selectMonth(DateTime(2024, 2));
  await settleProviders(tester);
  return (db: db, container: container);
}

Future<void> _enterCalendar(WidgetTester tester) async {
  expect(_key('stats-mode-calendar'), findsOneWidget);
  await tester.tap(_key('stats-mode-calendar'));
  await settleProviders(tester);
  expect(find.byType(CalendarStatsPage), findsOneWidget);
}

Future<_CalendarHarness> _pumpCalendar(
  WidgetTester tester, {
  AppDatabase? database,
  ExchangeRateService? rateService,
}) async {
  final harness = await _pumpStats(
    tester,
    database: database,
    rateService: rateService,
  );
  await _enterCalendar(tester);
  return harness;
}

Future<void> _bill(
  AppDatabase db,
  String id, {
  int type = 0,
  required int amount,
  DateTime? date,
  String currency = 'CNY',
  String? categoryId,
}) async {
  final accountId = currency == 'CNY' ? 'acc_cash' : 'r08-wallet-$currency';
  if (currency != 'CNY') {
    await db.upsertAccount(
      id: accountId,
      name: 'R08 $currency',
      emoji: '💳',
      type: 3,
      initBalance: 0,
      includeNetWorth: true,
      sort: 20,
      currency: currency,
    );
  }
  await db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    currency: currency,
    accountAmount: amount,
    categoryId: categoryId ?? (type == 1 ? 'inc_salary' : 'cat_food'),
    accountId: accountId,
    dateMs: (date ?? DateTime(2024, 2, 10, 12)).millisecondsSinceEpoch,
    note: 'r08-$id',
  );
}

Future<void> _monthTop(WidgetTester tester) async {
  final list = find.descendant(
    of: find.byType(CalendarStatsPage),
    matching: find.byType(ListView),
  );
  for (var i = 0; i < 3; i++) {
    await tester.drag(list.first, const Offset(0, 600));
    await settleProviders(tester);
  }
}

Future<void> _openDay(WidgetTester tester, DateTime date) async {
  final day = _key('calendar-day-${_dateKey(date)}');
  // Scroll the outer month list. ensureVisible alone targets the inner,
  // deliberately non-scrollable grid and can leave month-end dates offscreen.
  for (var i = 0; i < 8 && day.hitTestable().evaluate().isEmpty; i++) {
    final above = day.evaluate().isNotEmpty && tester.getCenter(day).dy < 100;
    await tester.drag(
      find
          .descendant(
            of: find.byType(CalendarStatsPage),
            matching: find.byType(ListView),
          )
          .first,
      Offset(0, above ? 240 : -240),
    );
    await settleProviders(tester);
  }
  expect(day.hitTestable(), findsOneWidget);
  await tester.tap(day.hitTestable());
  await settleProviders(tester);
  expect(find.byType(CalendarDaySheet), findsOneWidget);
}

Future<void> _closeDay(WidgetTester tester) async {
  await tester.tap(_key('calendar-day-close'));
  await settleProviders(tester);
  expect(find.byType(CalendarDaySheet), findsNothing);
}

Future<void> _filterDay(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: _key('calendar-day-type'), matching: find.text(label)),
  );
  await settleProviders(tester);
}

Future<void> _selectCurrency(WidgetTester tester, String label) async {
  await _monthTop(tester);
  await tester.tap(_key('currency-filter'));
  await settleProviders(tester);
  await tester.tap(find.text(label).last);
  await settleProviders(tester);
}

Future<void> _saveEditor(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
  });
  for (
    var i = 0;
    i < 50 && find.byType(EditBillPage).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(EditBillPage), findsNothing);
  await settleProviders(tester);
}

void main() {
  testWidgets('图表真实入口进入闰年完整月历，空日有日期与收支语义', (tester) async {
    final harness = await _pumpStats(tester);
    expect(find.byType(CalendarStatsPage), findsNothing);
    expect(find.byTooltip('日历视图'), findsOneWidget);
    expect(harness.container.read(statsCalendarModeProvider), isFalse);

    await _enterCalendar(tester);
    expect(harness.container.read(statsCalendarModeProvider), isTrue);
    expect(_key('calendar-month-2024-02'), findsOneWidget);
    expect(_text(tester, 'calendar-month-income'), '0.00');
    expect(_text(tester, 'calendar-month-expense'), '0.00');
    expect(_text(tester, 'calendar-month-balance'), '0.00');
    for (var day = 1; day <= 29; day++) {
      expect(
        _key('calendar-day-${_dateKey(DateTime(2024, 2, day))}'),
        findsOneWidget,
      );
    }
    expect(_key('calendar-day-2024-02-30'), findsNothing);
    expect(_key('calendar-day-2024-03-01'), findsNothing);
    final leapDay = tester.widget<Semantics>(_key('calendar-day-2024-02-29'));
    expect(leapDay.properties.label, contains('2024年2月29日'));
    expect(leapDay.properties.label, contains('收入0.00'));
    expect(leapDay.properties.label, contains('支出0.00'));
    expect(leapDay.properties.label, contains('无账单'));
    expect(tester.takeException(), isNull);
    await disposePage(tester, harness.db);
  });

  testWidgets('复用年月选择器跨年确认和取消，翻月只改变日历月份', (tester) async {
    final harness = await _pumpCalendar(tester);
    final container = harness.container;
    await tester.tap(_key('month-bar-select'));
    await settleProviders(tester);
    await tester.tap(find.byTooltip('下一年'));
    await tester.tap(_key('month-picker-month-1'));
    await tester.tap(_key('month-picker-confirm'));
    await settleProviders(tester);
    expect(container.read(calendarMonthProvider), DateTime(2025, 1));
    expect(container.read(selectedMonthProvider), DateTime(2026, 5));
    expect(_key('calendar-month-2025-01'), findsOneWidget);

    await tester.tap(find.byTooltip('上一月'));
    await settleProviders(tester);
    expect(container.read(calendarMonthProvider), DateTime(2024, 12));
    await tester.tap(_key('month-bar-select'));
    await settleProviders(tester);
    await tester.tap(_key('month-picker-month-6'));
    await tester.tap(find.text('取消'));
    await settleProviders(tester);
    expect(container.read(calendarMonthProvider), DateTime(2024, 12));
    expect(container.read(selectedMonthProvider), DateTime(2026, 5));
    expect(_key('calendar-month-2024-12'), findsOneWidget);
    await disposePage(tester, harness.db);
  });

  testWidgets('总览跨币日额与月额守恒，每日窗口复用同一月快照', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'cny', amount: 100);
    await _bill(harness.db, 'usd', amount: 200, currency: 'USD');
    await _bill(
      harness.db,
      'jpy-income',
      type: 1,
      amount: 200,
      currency: 'JPY',
      date: DateTime(2024, 2, 11, 12),
    );
    await settleProviders(tester);
    // 固定缓存：USD×7，JPY×0.05；支出1+14，收入10。
    expect(_text(tester, 'calendar-month-income'), '10.00');
    expect(_text(tester, 'calendar-month-expense'), '15.00');
    expect(_text(tester, 'calendar-month-balance'), '-5.00');
    expect(_text(tester, 'calendar-day-expense-2024-02-10'), '支 15.00');
    expect(_text(tester, 'calendar-day-income-2024-02-11'), '收 10.00');
    final report = harness.container.read(calendarReportProvider).value!;
    expect(report.income, BigInt.from(1000));
    expect(report.expense, BigInt.from(1500));
    expect(
      report.days.fold(BigInt.zero, (sum, day) => sum + day.income),
      report.income,
    );
    expect(
      report.days.fold(BigInt.zero, (sum, day) => sum + day.expense),
      report.expense,
    );
    await _openDay(tester, DateTime(2024, 2, 10));
    expect(_text(tester, 'calendar-day-count'), '共 2 笔');
    expect(_text(tester, 'calendar-day-total'), contains('支出 ¥ 15.00'));
    expect(_inDaySheet(find.textContaining('USD 2.00')), findsOneWidget);
    expect(
      identical(harness.container.read(calendarReportProvider).value, report),
      isTrue,
    );
    await _closeDay(tester);
    await disposePage(tester, harness.db);
  });

  testWidgets('日历切原币与图表共享币种，关闭每日窗口保留月份和币种', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'cny', amount: 100);
    await _bill(harness.db, 'usd', amount: 200, currency: 'USD');
    await settleProviders(tester);
    await _selectCurrency(tester, '美元 USD');
    expect(
      harness.container.read(statsViewProvider),
      const ReportViewCurrency.original('USD'),
    );
    expect(
      harness.container.read(billsViewProvider),
      const ReportViewCurrency.converted(),
    );
    expect(_text(tester, 'calendar-month-expense'), '2.00');
    expect(find.byKey(const ValueKey('report-view-hint')), findsNothing);
    await _openDay(tester, DateTime(2024, 2, 10));
    expect(_key('calendar-day-bill-usd'), findsOneWidget);
    expect(_key('calendar-day-bill-cny'), findsNothing);
    expect(_text(tester, 'calendar-day-total'), contains('支出 USD 2.00'));
    await _filterDay(tester, '支出');
    await _closeDay(tester);
    await _openDay(tester, DateTime(2024, 2, 10));
    expect(_text(tester, 'calendar-day-total'), '支出合计 USD 2.00');
    expect(harness.container.read(calendarDayTypeProvider), 0);
    expect(harness.container.read(statsTypeProvider), 0);
    await _closeDay(tester);
    expect(harness.container.read(calendarMonthProvider), DateTime(2024, 2));
    expect(
      harness.container.read(statsViewProvider),
      const ReportViewCurrency.original('USD'),
    );
    await disposePage(tester, harness.db);
  });

  testWidgets('空日真实入口和全部收入支出三过滤均显示零与明确空态', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _openDay(tester, DateTime(2024, 2, 9));
    expect(_text(tester, 'calendar-day-count'), '共 0 笔');
    expect(_text(tester, 'calendar-day-empty'), '当天暂无账单');
    expect(_text(tester, 'calendar-day-total'), contains('收入 ¥ 0.00'));
    expect(_text(tester, 'calendar-day-total'), contains('支出 ¥ 0.00'));
    await _filterDay(tester, '收入');
    expect(_text(tester, 'calendar-day-count'), '共 0 笔');
    expect(_text(tester, 'calendar-day-empty'), '当天暂无收入账单');
    expect(_text(tester, 'calendar-day-total'), '收入合计 ¥ 0.00');
    await _filterDay(tester, '支出');
    expect(_text(tester, 'calendar-day-empty'), '当天暂无支出账单');
    expect(_text(tester, 'calendar-day-total'), '支出合计 ¥ 0.00');
    await _closeDay(tester);
    await disposePage(tester, harness.db);
  });

  testWidgets('每日三过滤使用同一账单集合，内部收入不混入普通收支', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'expense', amount: 400);
    await _bill(harness.db, 'income', type: 1, amount: 1000);
    await _bill(
      harness.db,
      'internal',
      type: 1,
      amount: 999,
      categoryId: 'cat_aa_marker',
    );
    await settleProviders(tester);
    await _openDay(tester, DateTime(2024, 2, 10));
    expect(_text(tester, 'calendar-day-count'), '共 2 笔');
    expect(_key('calendar-day-bill-expense'), findsOneWidget);
    expect(_key('calendar-day-bill-income'), findsOneWidget);
    expect(_key('calendar-day-bill-internal'), findsNothing);
    await _filterDay(tester, '收入');
    expect(_text(tester, 'calendar-day-count'), '共 1 笔');
    expect(_text(tester, 'calendar-day-total'), '收入合计 ¥ 10.00');
    expect(_key('calendar-day-bill-expense'), findsNothing);
    expect(_key('calendar-day-bill-income'), findsOneWidget);
    await _filterDay(tester, '支出');
    expect(_text(tester, 'calendar-day-total'), '支出合计 ¥ 4.00');
    expect(_key('calendar-day-bill-expense'), findsOneWidget);
    expect(_key('calendar-day-bill-income'), findsNothing);
    await _filterDay(tester, '全部');
    expect(_text(tester, 'calendar-day-count'), '共 2 笔');
    expect(_text(tester, 'calendar-day-total'), contains('结余 +¥ 6.00'));
    await _closeDay(tester);
    await disposePage(tester, harness.db);
  });

  testWidgets('每日账单真实进入详情再修改金额，保存后窗口和月历同步刷新', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'editable', amount: 500);
    await settleProviders(tester);
    final oldReport = harness.container.read(calendarReportProvider).value!;
    await _openDay(tester, DateTime(2024, 2, 10));
    await tester.tap(_key('calendar-day-bill-editable'));
    await settleProviders(tester);
    expect(find.byType(BillDetailPage), findsOneWidget);
    expect(find.byType(EditBillPage), findsNothing);
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    expect(find.byType(EditBillPage), findsOneWidget);
    await tester.longPress(find.text('⌫'));
    await tester.tap(find.text('6'));
    await _saveEditor(tester);
    expect(find.byType(BillDetailPage), findsOneWidget);
    final saved = (await harness.db.getAllBills()).singleWhere(
      (bill) => bill.id == 'editable',
    );
    expect(saved.amount, 600);
    await tester.tap(find.byTooltip('关闭详情'));
    await settleProviders(tester);
    expect(_text(tester, 'calendar-day-count'), '共 1 笔');
    expect(_text(tester, 'calendar-day-total'), contains('支出 ¥ 6.00'));
    final refreshed = harness.container.read(calendarReportProvider).value!;
    expect(identical(oldReport, refreshed), isFalse);
    expect(oldReport.expense, BigInt.from(500));
    expect(refreshed.expense, BigInt.from(600));
    await _closeDay(tester);
    await _monthTop(tester);
    expect(_text(tester, 'calendar-month-expense'), '6.00');
    expect(_text(tester, 'calendar-day-expense-2024-02-10'), '支 6.00');
    expect(harness.container.read(calendarMonthProvider), DateTime(2024, 2));
    await disposePage(tester, harness.db);
  });

  testWidgets('日期保存移到另一日及另一月时，已打开旧日窗口不保留陈旧账单', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'move', amount: 500);
    await settleProviders(tester);
    await _openDay(tester, DateTime(2024, 2, 10));
    // 独立验证数据库 watch 刷新：等价于编辑器成功保存日期后的事件。
    await _bill(
      harness.db,
      'move',
      amount: 500,
      date: DateTime(2024, 2, 11, 12),
    );
    await settleProviders(tester);
    expect(_key('calendar-day-bill-move'), findsNothing);
    expect(_text(tester, 'calendar-day-count'), '共 0 笔');
    expect(_text(tester, 'calendar-day-empty'), '当天暂无账单');
    expect(
      harness.container.read(calendarReportProvider).value!.expense,
      BigInt.from(500),
    );
    await _closeDay(tester);
    await _openDay(tester, DateTime(2024, 2, 11));
    expect(_key('calendar-day-bill-move'), findsOneWidget);
    await _bill(harness.db, 'move', amount: 500, date: DateTime(2024, 3, 1));
    await settleProviders(tester);
    expect(_key('calendar-day-bill-move'), findsNothing);
    expect(_text(tester, 'calendar-day-count'), '共 0 笔');
    expect(
      harness.container.read(calendarReportProvider).value!.expense,
      BigInt.zero,
    );
    await _closeDay(tester);
    await _monthTop(tester);
    expect(_text(tester, 'calendar-month-expense'), '0.00');
    await disposePage(tester, harness.db);
  });

  testWidgets('每日窗口打开时删除账单，条数月额和日格自动回到零', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'delete', amount: 700);
    await settleProviders(tester);
    await _openDay(tester, DateTime(2024, 2, 10));
    await harness.db.softDeleteBill('delete');
    await settleProviders(tester);
    expect(_key('calendar-day-bill-delete'), findsNothing);
    expect(_text(tester, 'calendar-day-count'), '共 0 笔');
    expect(_text(tester, 'calendar-day-empty'), '当天暂无账单');
    expect(
      harness.container.read(calendarReportProvider).value!.billIds,
      isEmpty,
    );
    await _closeDay(tester);
    await _monthTop(tester);
    expect(_text(tester, 'calendar-month-expense'), '0.00');
    final day = tester.widget<Semantics>(_key('calendar-day-2024-02-10'));
    expect(day.properties.label, contains('无账单'));
    await disposePage(tester, harness.db);
  });

  testWidgets('缺率原币行仍在每日集合中，月日均明确标记部分合计', (tester) async {
    final service = _NoJpyService();
    final harness = await _pumpCalendar(tester, rateService: service);
    expect(service.cacheCorrupt, isFalse);
    expect(service.quote(Currency.usd, Currency.cny), isNotNull);
    expect(service.quote(Currency.jpy, Currency.cny), isNull);
    await _bill(harness.db, 'cny', amount: 300);
    await _bill(harness.db, 'jpy', amount: 150, currency: 'JPY');
    await settleProviders(tester);
    expect(find.text('本月收支 · 部分合计'), findsOneWidget);
    expect(_text(tester, 'calendar-month-expense'), '3.00');
    expect(_text(tester, 'report-view-hint'), contains('未纳入 JPY 1 笔'));
    final report = harness.container.read(calendarReportProvider).value!;
    expect(report.billIds, {'cny', 'jpy'});
    expect(report.complete, isFalse);
    await _openDay(tester, DateTime(2024, 2, 10));
    expect(_text(tester, 'calendar-day-count'), '共 2 笔');
    expect(_text(tester, 'calendar-day-total'), contains('支出 ¥ 3.00'));
    expect(_text(tester, 'calendar-day-total'), contains('部分合计'));
    expect(_key('calendar-day-bill-jpy'), findsOneWidget);
    expect(_inDaySheet(find.text('未纳入')), findsOneWidget);
    expect(_inDaySheet(find.textContaining('JPY 150')), findsOneWidget);
    await _filterDay(tester, '支出');
    expect(_text(tester, 'calendar-day-count'), '共 2 笔');
    expect(_text(tester, 'calendar-day-total'), contains('部分合计'));
    await _closeDay(tester);
    await disposePage(tester, harness.db);
  });

  testWidgets('日历模型加载时不显示旧月金额或可点击陈旧日期', (tester) async {
    final harness = await _pumpStats(
      tester,
      overrides: [
        calendarReportProvider.overrideWithValue(
          const AsyncValue<CalendarReport>.loading(),
        ),
      ],
    );
    await tester.tap(_key('stats-mode-calendar'));
    await tester.pump();
    expect(find.byType(CalendarStatsPage), findsOneWidget);
    expect(find.text('日历加载中…'), findsOneWidget);
    expect(_key('calendar-month-expense'), findsNothing);
    expect(_key('calendar-day-2024-02-10'), findsNothing);
    expect(_key('calendar-mode-chart'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, harness.db);
  });

  testWidgets('日历模型失败时显示错误且仍能返回原图表', (tester) async {
    final harness = await _pumpStats(
      tester,
      overrides: [
        calendarReportProvider.overrideWithValue(
          AsyncValue<CalendarReport>.error(
            StateError('r08 model failure'),
            StackTrace.current,
          ),
        ),
      ],
    );
    await _enterCalendar(tester);
    expect(find.text('日历统计失败，请稍后重试'), findsOneWidget);
    expect(_key('calendar-month-income'), findsNothing);
    expect(_key('calendar-day-2024-02-10'), findsNothing);
    await tester.tap(_key('calendar-mode-chart'));
    await settleProviders(tester);
    expect(find.byType(CalendarStatsPage), findsNothing);
    expect(_key('stats-mode-calendar'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, harness.db);
  });

  testWidgets('320窄屏双倍字号与两个int64最大金额在月格和每日窗口均不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 760);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = await _pumpCalendar(tester);
    const max = 9223372036854775807;
    await _bill(harness.db, 'max-a', amount: max, date: DateTime(2024, 2, 1));
    await _bill(harness.db, 'max-b', amount: max, date: DateTime(2024, 2, 1));
    await settleProviders(tester);
    expect(
      _text(tester, 'calendar-month-expense'),
      '184,467,440,737,095,516.14',
    );
    expect(tester.takeException(), isNull);
    await _openDay(tester, DateTime(2024, 2, 1));
    expect(_text(tester, 'calendar-day-count'), '共 2 笔');
    expect(
      _text(tester, 'calendar-day-total'),
      contains('支出 ¥ 184,467,440,737,095,516.14'),
    );
    expect(tester.takeException(), isNull);
    await _closeDay(tester);
    await disposePage(tester, harness.db);
  });

  testWidgets('从日历返回图表保留原年收入状态，日历月份不覆盖首页', (tester) async {
    final harness = await _pumpStats(tester);
    final container = harness.container;
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.year);
    container.read(selectedYearProvider.notifier).selectYear(2025);
    container.read(statsTypeProvider.notifier).select(1);
    await settleProviders(tester);
    expect(find.text('本年收入'), findsOneWidget);
    await _enterCalendar(tester);
    await tester.tap(find.byTooltip('下一月'));
    await settleProviders(tester);
    await _selectCurrency(tester, '美元 USD');
    expect(container.read(calendarMonthProvider), DateTime(2024, 3));
    await tester.tap(_key('calendar-mode-chart'));
    await settleProviders(tester);
    expect(find.byType(CalendarStatsPage), findsNothing);
    expect(container.read(statsGranularityProvider), StatsGranularity.year);
    expect(container.read(selectedYearProvider), 2025);
    expect(container.read(statsTypeProvider), 1);
    expect(container.read(selectedMonthProvider), DateTime(2026, 5));
    expect(container.read(calendarMonthProvider), DateTime(2024, 3));
    expect(
      container.read(statsViewProvider),
      const ReportViewCurrency.original('USD'),
    );
    expect(find.text('本年收入'), findsOneWidget);
    expect(find.text('2025年'), findsOneWidget);
    expect(_key('stats-mode-calendar'), findsOneWidget);
    await disposePage(tester, harness.db);
  });

  testWidgets('月首零点和闰月末毫秒只进入各自日期，邻月零点不泄入', (tester) async {
    final harness = await _pumpCalendar(tester);
    await _bill(harness.db, 'first', amount: 100, date: DateTime(2024, 2, 1));
    await _bill(
      harness.db,
      'last',
      type: 1,
      amount: 500,
      date: DateTime(2024, 3, 1).subtract(const Duration(milliseconds: 1)),
    );
    await _bill(
      harness.db,
      'before',
      amount: 999,
      date: DateTime(2024, 2, 1).subtract(const Duration(milliseconds: 1)),
    );
    await _bill(harness.db, 'after', amount: 888, date: DateTime(2024, 3, 1));
    await settleProviders(tester);
    expect(_text(tester, 'calendar-month-income'), '5.00');
    expect(_text(tester, 'calendar-month-expense'), '1.00');
    expect(_text(tester, 'calendar-month-balance'), '+4.00');
    final report = harness.container.read(calendarReportProvider).value!;
    expect(report.billIds, {'first', 'last'});
    await _openDay(tester, DateTime(2024, 2, 29));
    expect(_text(tester, 'calendar-day-count'), '共 1 笔');
    expect(_key('calendar-day-bill-last'), findsOneWidget);
    expect(_key('calendar-day-bill-after'), findsNothing);
    expect(_key('calendar-day-bill-before'), findsNothing);
    await _closeDay(tester);
    await disposePage(tester, harness.db);
  });
}

/// 完整有效缓存上仅屏蔽 JPY→CNY 报价，区别于损坏缓存或全币缺率。
class _NoJpyService extends ExchangeRateService {
  _NoJpyService()
    : super(
        store: StaticRateStore(),
        sourceFactory: () => throw StateError('R08 must not use network'),
      );

  @override
  RateQuote? quote(Currency base, Currency quote) {
    if (base == Currency.jpy && quote == Currency.cny) return null;
    return super.quote(base, quote);
  }
}
