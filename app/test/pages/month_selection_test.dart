import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/home_shell.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/widgets/month_bar.dart';

import '../helpers/test_support.dart';

Finder _monthKey(String value) => find.byKey(ValueKey(value));

ProviderContainer _homeContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

Future<void> _chooseMonth(
  WidgetTester tester,
  ProviderContainer container,
  DateTime target,
) async {
  var draftYear = container.read(selectedMonthProvider).year;
  await tester.tap(_monthKey('month-bar-select'));
  await settleProviders(tester);
  while (draftYear != target.year) {
    final forward = draftYear < target.year;
    await tester.tap(find.byTooltip(forward ? '下一年' : '上一年'));
    await settleProviders(tester);
    draftYear += forward ? 1 : -1;
  }
  await tester.tap(_monthKey('month-picker-month-${target.month}'));
  await tester.tap(_monthKey('month-picker-confirm'));
  await settleProviders(tester);
}

void _expectSummary(String label, String value) {
  final column = find
      .ancestor(of: find.text(label), matching: find.byType(Column))
      .first;
  expect(
    find.descendant(of: column, matching: find.text(value)),
    findsOneWidget,
  );
}

Future<void> _seedBill(
  AppDatabase db,
  String id,
  int amount,
  int dateMs, {
  int type = 0,
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  categoryId: type == 1 ? 'inc_salary' : 'cat_food',
  accountId: 'acc_cash',
  dateMs: dateMs,
  note: id,
);

void main() {
  test('默认月份规范到当地月首零点', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final selected = container.read(selectedMonthProvider);
    final now = DateTime.now();
    expect(selected, DateTime(now.year, now.month, 1));
    expect(selected.isUtc, isFalse);
  });

  test('选择闰日和月末都锚定月首，随后跨年翻页不会跳月', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(selectedMonthProvider.notifier);

    notifier.selectMonth(DateTime(2024, 2, 29, 23, 59, 59, 999));
    expect(container.read(selectedMonthProvider), DateTime(2024, 2, 1));
    notifier.shift(1);
    expect(container.read(selectedMonthProvider), DateTime(2024, 3, 1));
    notifier.selectMonth(DateTime(2024, 12, 31, 23, 59));
    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
    notifier.shift(1);
    expect(container.read(selectedMonthProvider), DateTime(2025, 1, 1));
    notifier.shift(-1);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
  });

  testWidgets('年月选择跨年共享明细图表，月末零点不重复，空月正常', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    final year = DateTime.now().year;
    final januaryStart = DateTime(year, 1, 1).millisecondsSinceEpoch;
    await _seedBill(
      db,
      '十二月月初',
      1000,
      DateTime(year - 1, 12, 1).millisecondsSinceEpoch,
    );
    await _seedBill(db, '十二月最后一毫秒', 2000, januaryStart - 1);
    await _seedBill(
      db,
      '十二月收入',
      4000,
      DateTime(year - 1, 12, 15).millisecondsSinceEpoch,
      type: 1,
    );
    await _seedBill(db, '一月零点收入', 7000, januaryStart, type: 1);
    await _seedBill(
      db,
      '一月支出',
      500,
      DateTime(year, 1, 10).millisecondsSinceEpoch,
    );
    await pumpPage(tester, const HomeShell(), db: db);
    final container = _homeContainer(tester);

    await _chooseMonth(tester, container, DateTime(year - 1, 12));
    expect(container.read(selectedMonthProvider), DateTime(year - 1, 12, 1));
    _expectSummary('收入', '+40.00');
    _expectSummary('支出', '30.00');
    _expectSummary('结余', '+10.00');
    expect(find.text('十二月最后一毫秒'), findsOneWidget);
    expect(find.text('一月零点收入'), findsNothing);

    await tester.tap(find.text('图表'));
    await settleProviders(tester);
    expect(find.text('${year - 1}年12月'), findsOneWidget);
    final decemberPie = tester.widget<PieChart>(find.byType(PieChart));
    expect(decemberPie.data.sections.single.value, 30);
    final decemberTrend = tester.widget<BarChart>(find.byType(BarChart));
    expect(decemberTrend.data.barGroups.last.barRods.first.toY, 30);
    expect(decemberTrend.data.barGroups.last.barRods.last.toY, 40);

    // 在图表中选择一月；返回明细仍须沿用同一已确认月份。
    await _chooseMonth(tester, container, DateTime(year, 1));
    expect(find.text('¥ 5.00'), findsOneWidget);
    final januaryPie = tester.widget<PieChart>(find.byType(PieChart));
    expect(januaryPie.data.sections.single.value, 5);
    final januaryTrend = tester.widget<BarChart>(find.byType(BarChart));
    expect(januaryTrend.data.barGroups.last.barRods.first.toY, 5);
    expect(januaryTrend.data.barGroups.last.barRods.last.toY, 70);
    expect(januaryTrend.data.barGroups[4].barRods.first.toY, 30);
    expect(januaryTrend.data.barGroups[4].barRods.last.toY, 40);

    await tester.tap(find.text('明细'));
    await settleProviders(tester);
    _expectSummary('收入', '+70.00');
    _expectSummary('支出', '5.00');
    _expectSummary('结余', '+65.00');
    expect(find.text('一月零点收入'), findsOneWidget);
    expect(find.text('十二月最后一毫秒'), findsNothing);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await settleProviders(tester);
    expect(find.text('本月还没有账单'), findsOneWidget);
    await tester.tap(find.text('图表'));
    await settleProviders(tester);
    expect(find.text('本月暂无支出'), findsOneWidget);
    final emptyTrend = tester.widget<BarChart>(find.byType(BarChart));
    expect(emptyTrend.data.barGroups.last.barRods.first.toY, 0);
    expect(emptyTrend.data.barGroups.last.barRods.last.toY, 0);
    expect(emptyTrend.data.barGroups[4].barRods.last.toY, 70);
    await disposePage(tester, db);
  });

  testWidgets('修改年月草稿再取消不改变共享月份或报表', (tester) async {
    final db = await pumpPage(tester, const HomeShell());
    final container = _homeContainer(tester);
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2024, 12));
    await settleProviders(tester);
    await tester.tap(_monthKey('month-bar-select'));
    await settleProviders(tester);
    await tester.tap(find.byTooltip('下一年'));
    await tester.tap(_monthKey('month-picker-month-6'));
    await settleProviders(tester);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
    await tester.tap(find.text('取消'));
    await settleProviders(tester);

    expect(find.text('2024年12月'), findsOneWidget);
    await tester.tap(find.text('图表'));
    await settleProviders(tester);
    expect(find.text('2024年12月'), findsOneWidget);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
    await disposePage(tester, db);
  });

  testWidgets('年月选择后左右切月仍跨年正确且明细图表同步', (tester) async {
    final db = await pumpPage(tester, const HomeShell());
    final container = _homeContainer(tester);
    await _chooseMonth(tester, container, DateTime(2024, 12));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await settleProviders(tester);
    expect(container.read(selectedMonthProvider), DateTime(2025, 1, 1));
    await tester.tap(find.text('图表'));
    await settleProviders(tester);
    expect(find.text('2025年1月'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await settleProviders(tester);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
    await tester.tap(find.text('明细'));
    await settleProviders(tester);
    expect(find.text('2024年12月'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await settleProviders(tester);
    expect(container.read(selectedMonthProvider), DateTime(2024, 11, 1));
    await disposePage(tester, db);
  });

  testWidgets('取消和同月确认保留明细位置，换月回到新账单顶部', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    // 两个月都足够长，避免旧偏移仅因新列表太短而被自动截到零。
    for (var day = 1; day <= 28; day++) {
      await _seedBill(
        db,
        '原月份第$day日',
        100,
        DateTime(2024, 12, day, 12).millisecondsSinceEpoch,
      );
      await _seedBill(
        db,
        '目标月份第$day日',
        200,
        DateTime(2025, 1, day, 12).millisecondsSinceEpoch,
      );
    }
    await pumpPage(tester, const HomeShell(), db: db);
    final container = _homeContainer(tester);
    await _chooseMonth(tester, container, DateTime(2024, 12));
    final decemberList = _monthKey('bills-2024-12');
    double listOffset(Finder list) => tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position
        .pixels;
    await tester.drag(decemberList, const Offset(0, -700));
    await settleProviders(tester);
    final previousOffset = listOffset(decemberList);
    expect(previousOffset, greaterThan(0));

    await tester.tap(_monthKey('month-bar-select'));
    await settleProviders(tester);
    await tester.tap(find.byTooltip('下一年'));
    await tester.tap(_monthKey('month-picker-month-1'));
    await tester.tap(find.text('取消'));
    await settleProviders(tester);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
    expect(listOffset(decemberList), closeTo(previousOffset, 0.01));

    await _chooseMonth(tester, container, DateTime(2024, 12));
    expect(listOffset(decemberList), closeTo(previousOffset, 0.01));
    await _chooseMonth(tester, container, DateTime(2025, 1));
    expect(container.read(selectedMonthProvider), DateTime(2025, 1, 1));
    expect(listOffset(_monthKey('bills-2025-1')), 0);
    expect(find.text('目标月份第28日'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('选择窗口等待期间卸载月份栏，确认不再写共享状态', (tester) async {
    final container = ProviderContainer();
    final visible = ValueNotifier(true);
    addTearDown(container.dispose);
    addTearDown(visible.dispose);
    addTearDown(() async {
      // 断言提前失败时也先卸载弹窗和消费者，避免容器清理后的异步回调。
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
    });
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2024, 12));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedApp(
          ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, showBar, _) =>
                showBar ? const MonthBar() : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await settleProviders(tester);
    await tester.tap(_monthKey('month-bar-select'));
    await settleProviders(tester);
    await tester.tap(_monthKey('month-picker-month-6'));
    visible.value = false;
    await tester.pump();
    expect(find.byType(MonthBar), findsNothing);
    await tester.tap(_monthKey('month-picker-confirm'));
    await settleProviders(tester);

    expect(container.read(selectedMonthProvider), DateTime(2024, 12, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets('320宽大字体明细顶部月份和账本入口无布局溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await pumpPage(
      tester,
      MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 640),
          textScaler: TextScaler.linear(1.6),
        ),
        child: const BillsPage(),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2099, 12));
    await settleProviders(tester);

    expect(_monthKey('month-bar-select'), findsOneWidget);
    expect(find.text('2099年12月'), findsOneWidget);
    expect(find.byTooltip('账本'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
