// R-05 专项：点击饼图 / 分类排行打开同一个账单明细窗口。覆盖一级（直属 +
// 二级）/ 二级 / 未细分 / 未分类口径、窗口合计与图项一致、行内容（日期 /
// 类型 / 路径 / 币种 / 金额）、饼图入口、编辑后窗口与图表同步刷新、缺率
// 未纳入、空态与关闭保留筛选。
import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/pages/category_bills_sheet.dart';
import 'package:aa_expense_splitter/pages/stats_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/utils/report_filter.dart';

import '../helpers/test_support.dart';

Future<AppDatabase> pumpStats(
  WidgetTester tester, {
  int type = 1,
}) async {
  final db = await pumpPage(tester, const StatsPage());
  final container = ProviderScope.containerOf(
    tester.element(find.byType(StatsPage)),
  );
  container
      .read(selectedMonthProvider.notifier)
      .selectMonth(DateTime(2026, 5));
  container
      .read(statsGranularityProvider.notifier)
      .select(StatsGranularity.month);
  // 明细窗口跟随当前收支维度；本文件用例默认在收入视图下点击图项
  container.read(statsTypeProvider.notifier).select(type);
  await settleProviders(tester);
  return db;
}

Future<void> addBill(
  AppDatabase db,
  String id, {
  required int type,
  required int amount,
  String? categoryId,
  int day = 10,
  String currency = 'CNY',
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  categoryId: categoryId,
  accountId: 'acc_cash',
  dateMs: DateTime(2026, 5, day, 12).millisecondsSinceEpoch,
  note: 'r05-$id',
  currency: currency,
);

Future<void> addChildCategory(AppDatabase db) => db
    .into(db.categories)
    .insert(
      CategoriesCompanion.insert(
        id: 'cat_sal_child',
        name: '季度奖',
        emoji: '🧧',
        kind: 1,
        parentId: const Value('inc_salary'),
      ),
    );

/// 在图表页上打开指定口径的明细窗口并等动画结束。
/// 用有界泵帧（pumpAndSettle 会被加载态转圈卡住）。
Future<void> openSheet(
  WidgetTester tester,
  ReportCategoryFilter category,
  String title,
) async {
  unawaited(
    showCategoryBillsSheet(
      tester.element(find.byType(StatsPage)),
      category: category,
      title: title,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder inSheet(Finder finder) =>
    find.descendant(of: find.byType(CategoryBillsSheet), matching: finder);

Future<void> closeSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('category-bills-close')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('一级行口径含直属与二级，窗口合计等于图项', (tester) async {
    final db = await pumpStats(tester);
    await addChildCategory(db);
    await addBill(db, 'direct1', type: 1, amount: 300, categoryId: 'inc_salary');
    await addBill(
      db,
      'child1',
      type: 1,
      amount: 200,
      categoryId: 'cat_sal_child',
      day: 12,
    );
    await addBill(db, 'other1', type: 1, amount: 400);
    await addBill(db, 'exp1', type: 0, amount: 100, categoryId: 'cat_food');
    await settleProviders(tester);

    // 图项（排行行）金额 = 直属 + 二级 = 5.00（行在视口外时先滚动列表）
    for (
      var i = 0;
      i < 8 && find.textContaining('5.00 · 占本月').evaluate().isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -260));
      await settleProviders(tester);
    }
    expect(find.textContaining('5.00 · 占本月'), findsOneWidget);
    await openSheet(
      tester,
      ReportCategoryFilter.root('inc_salary'),
      '💰 工资',
    );

    expect(inSheet(find.text('共 2 笔')), findsOneWidget);
    expect(inSheet(find.textContaining('2026年5月 · 收入')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 5.00',
    );
    expect(inSheet(find.text('r05-direct1')), findsOneWidget);
    expect(inSheet(find.text('r05-child1')), findsOneWidget);
    expect(inSheet(find.textContaining('工资 / 季度奖')), findsOneWidget);
    expect(inSheet(find.textContaining('5月10日 · 收入')), findsOneWidget);
    expect(inSheet(find.text('r05-other1')), findsNothing);
    expect(inSheet(find.text('r05-exp1')), findsNothing);
    await closeSheet(tester);
    await disposePage(tester, db);
  });

  testWidgets('二级行口径仅自身账单', (tester) async {
    final db = await pumpStats(tester);
    await addChildCategory(db);
    await addBill(db, 'direct1', type: 1, amount: 300, categoryId: 'inc_salary');
    await addBill(
      db,
      'child1',
      type: 1,
      amount: 200,
      categoryId: 'cat_sal_child',
      day: 12,
    );
    await settleProviders(tester);

    await openSheet(
      tester,
      ReportCategoryFilter.exact('cat_sal_child'),
      '🧧 季度奖',
    );

    expect(inSheet(find.text('共 1 笔')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 2.00',
    );
    expect(inSheet(find.text('r05-child1')), findsOneWidget);
    expect(inSheet(find.text('r05-direct1')), findsNothing);
    await closeSheet(tester);
    await disposePage(tester, db);
  });

  testWidgets('未细分口径仅直属账单，未分类口径仅空分类账单', (tester) async {
    final db = await pumpStats(tester);
    await addChildCategory(db);
    await addBill(db, 'direct1', type: 1, amount: 300, categoryId: 'inc_salary');
    await addBill(
      db,
      'child1',
      type: 1,
      amount: 200,
      categoryId: 'cat_sal_child',
      day: 12,
    );
    await addBill(db, 'other1', type: 1, amount: 400);
    await settleProviders(tester);

    await openSheet(
      tester,
      ReportCategoryFilter.direct('inc_salary'),
      '💰 工资 · 未细分',
    );
    expect(inSheet(find.text('共 1 笔')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 3.00',
    );
    expect(inSheet(find.text('r05-direct1')), findsOneWidget);
    expect(inSheet(find.text('r05-child1')), findsNothing);
    await closeSheet(tester);

    await openSheet(
      tester,
      const ReportCategoryFilter.uncategorized(),
      '📦 未分类',
    );
    expect(inSheet(find.text('共 1 笔')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 4.00',
    );
    expect(inSheet(find.text('r05-other1')), findsOneWidget);
    await closeSheet(tester);
    await disposePage(tester, db);
  });

  testWidgets('点击饼图打开同一窗口（单分类满圆）', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'direct1', type: 1, amount: 300, categoryId: 'inc_salary');
    await settleProviders(tester);

    final pieCenter = tester.getCenter(find.byType(PieChart));
    await tester.tapAt(pieCenter + const Offset(40, 0));
    await settleProviders(tester);

    expect(find.byType(CategoryBillsSheet), findsOneWidget);
    expect(inSheet(find.text('💰 工资')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 3.00',
    );
    await closeSheet(tester);
    await disposePage(tester, db);
  });

  testWidgets('窗口开着时账单被修改，窗口与图表同步刷新，关闭保留筛选', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'direct1', type: 1, amount: 300, categoryId: 'inc_salary');
    await addBill(db, 'other1', type: 1, amount: 400);
    await settleProviders(tester);
    await openSheet(
      tester,
      ReportCategoryFilter.root('inc_salary'),
      '💰 工资',
    );

    // 模拟编辑保存后的数据变更：明细窗口与图表都监听同一账单流
    await db.upsertBill(
      id: 'direct1',
      type: 1,
      amount: 800,
      categoryId: 'inc_salary',
      accountId: 'acc_cash',
      dateMs: DateTime(2026, 5, 10, 12).millisecondsSinceEpoch,
      note: 'r05-direct1',
    );
    await settleProviders(tester);

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 8.00',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatsPage)),
    );
    container.read(statsTypeProvider.notifier).select(1);
    await settleProviders(tester);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('stats-income-total')))
          .data,
      '¥ 12.00',
    );

    await closeSheet(tester);
    // 关闭窗口保留筛选：月份 / 维度 / 视图不变
    expect(container.read(selectedMonthProvider), DateTime(2026, 5));
    expect(container.read(statsTypeProvider), 1);
    expect(container.read(statsViewProvider).isConverted, isTrue);
    await disposePage(tester, db);
  });

  testWidgets('总览缺率账单显示未纳入且不计入窗口合计', (tester) async {
    final noJpyService = ExchangeRateService(store: _NoJpyRateStore());
    final db = await pumpPage(
      tester,
      const StatsPage(),
      rateService: noJpyService,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatsPage)),
    );
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2026, 5));
    container
        .read(statsGranularityProvider.notifier)
        .select(StatsGranularity.month);
    container.read(statsTypeProvider.notifier).select(1);
    await db.upsertBill(
      id: 'direct1',
      type: 1,
      amount: 300,
      categoryId: 'inc_salary',
      accountId: 'acc_cash',
      dateMs: DateTime(2026, 5, 10, 12).millisecondsSinceEpoch,
      note: 'r05-direct1',
    );
    await db.upsertBill(
      id: 'jpy1',
      type: 1,
      amount: 150,
      categoryId: 'inc_salary',
      accountId: 'acc_cash',
      dateMs: DateTime(2026, 5, 11, 12).millisecondsSinceEpoch,
      note: 'r05-jpy1',
      currency: 'JPY',
      accountAmount: 150,
    );
    await settleProviders(tester);

    await openSheet(
      tester,
      ReportCategoryFilter.root('inc_salary'),
      '💰 工资',
    );
    // CNY 账单计入合计，JPY 账单缺率显示未纳入
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 3.00',
    );
    expect(inSheet(find.text('r05-jpy1')), findsOneWidget);
    expect(inSheet(find.text('未纳入')), findsOneWidget);
    expect(inSheet(find.textContaining('JPY 150')), findsOneWidget);
    await closeSheet(tester);
    await disposePage(tester, db);
  });

  testWidgets('口径无账单时显示空态', (tester) async {
    final db = await pumpStats(tester);
    await addBill(db, 'direct1', type: 1, amount: 300, categoryId: 'inc_salary');
    await settleProviders(tester);

    await openSheet(
      tester,
      ReportCategoryFilter.exact('inc_bonus'),
      '🧧 奖金',
    );
    expect(inSheet(find.text('该分类暂无账单')), findsOneWidget);
    expect(inSheet(find.text('共 0 笔')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('category-bills-total')))
          .data,
      '合计 ¥ 0.00',
    );
    await closeSheet(tester);
    await disposePage(tester, db);
  });
}

/// 与 StaticRateStore 同构，但缺少 JPY 报价：JPY → CNY 视为缺率。
class _NoJpyRateStore implements RateStore {
  static String? _cache;

  @override
  Future<String?> read() async {
    if (_cache != null) return _cache;
    final now = DateTime.now().toUtc();
    final snapshot = NetworkRateSnapshot(
      quotedAt: DateTime.utc(now.year, now.month, now.day),
      fetchedAt: now,
      rates: {
        Currency.eur: RateRatio.parse('1'),
        Currency.usd: RateRatio.parse('1.1'),
        Currency.cny: RateRatio.parse('7.7'),
        Currency.hkd: RateRatio.parse('10'),
        Currency.gbp: RateRatio.parse('0.7'),
      },
    );
    _cache = jsonEncode({
      'version': 1,
      'network': snapshot.toJson(),
      'manual': <Object>[],
    });
    return _cache;
  }

  @override
  Future<void> write(String value) async {}
}
