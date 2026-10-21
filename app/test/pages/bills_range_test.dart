// R-03 专项：明细页自定义日期范围。覆盖选择器确认与取消（保留选择）、
// 退出回按月（保留范围）、跨年与次日零点边界、跨月同日折算小计不合并、
// 范围空态。列表与摘要数值均按默认折合 CNY 断言。
// 范围状态经真实 notifier 在装配后驱动，不用 provider override。
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/report_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  int ms(int y, int m, int d, [int hour = 12, int minute = 0]) =>
      DateTime(y, m, d, hour, minute).millisecondsSinceEpoch;

  Future<void> addBill(
    AppDatabase db,
    String id,
    int dateMs, {
    int type = 0,
    int amount = 100,
    String note = '',
  }) => db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    accountId: 'acc_cash',
    dateMs: dateMs,
    note: note,
  );

  Future<void> seedRange(
    WidgetTester tester,
    ReportDateRange range,
  ) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );
    container
        .read(billsPeriodModeProvider.notifier)
        .select(BillsPeriodMode.range);
    container.read(selectedRangeProvider.notifier).select(range);
  }

  /// 有界泵：等待弹窗关闭动画与流重建；期间可能出现不自行结束的加载动画，
  /// 不能 pumpAndSettle。
  Future<void> settleRoute(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(BillsPage)));

  testWidgets('选择器确认进入范围模式，列表与摘要只含范围内账单', (tester) async {
    final now = DateTime.now();
    final y = now.year;
    final m = now.month;
    final db = await pumpPage(tester, const BillsPage());
    await addBill(db, 'd15', ms(y, m, 15), amount: 100, note: '范围首日');

    await addBill(db, 'd18', ms(y, m, 18), type: 1, amount: 500, note: '范围内收入');
    await addBill(db, 'd20', ms(y, m, 20), amount: 700, note: '范围外');
    await settleProviders(tester);

    await tester.tap(find.byKey(const ValueKey('bills-range-open')));
    await tester.pumpAndSettle();
    // 该版本范围选择器为连续双月网格，本月格子先于次月出现，取首个命中
    await tester.tap(find.text('15').first);
    await tester.pump();
    await tester.tap(find.text('18').first);
    await tester.pump();
    await tester.tap(find.text('确定'));
    await settleRoute(tester);

    expect(
      containerOf(tester).read(billsPeriodModeProvider),
      BillsPeriodMode.range,
    );
    expect(find.text('$y年$m月15日 ~ $m月18日'), findsOneWidget);
    expect(find.text('范围首日'), findsOneWidget);
    expect(find.text('范围内收入'), findsOneWidget);
    expect(find.text('范围外'), findsNothing);
    // 默认折合 CNY：首日支出 ¥1.00，收入 ¥5.00，结余 +¥4.00
    expect(find.text('支出 ¥ 1.00'), findsOneWidget);
    expect(find.text('+¥ 5.00'), findsOneWidget);
    expect(find.text('¥ 1.00'), findsOneWidget);
    expect(find.text('+¥ 4.00'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('取消选择器保留原范围与范围模式', (tester) async {
    final seeded = ReportDateRange(
      start: DateTime(2026, 5, 10),
      end: DateTime(2026, 5, 20),
    );
    final db = await pumpPage(tester, const BillsPage());
    await addBill(db, 'may12', ms(2026, 5, 12), amount: 300, note: '五月内');
    await seedRange(tester, seeded);
    await settleProviders(tester);
    expect(find.text('2026年5月10日 ~ 5月20日'), findsOneWidget);
    expect(find.text('五月内'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bills-range-open')));
    await tester.pumpAndSettle();
    // 该版本范围选择器的取消是左上角关闭按钮（无「取消」文本）
    await tester.tap(find.byType(CloseButton));
    await settleRoute(tester);

    expect(find.text('2026年5月10日 ~ 5月20日'), findsOneWidget);
    expect(find.text('五月内'), findsOneWidget);
    final container = containerOf(tester);
    expect(container.read(selectedRangeProvider), seeded);
    expect(
      container.read(billsPeriodModeProvider),
      BillsPeriodMode.range,
    );
    await disposePage(tester, db);
  });

  testWidgets('跨年范围含两端与次日零点边界，摘要为范围合计', (tester) async {
    final seeded = ReportDateRange(
      start: DateTime(2025, 12, 30),
      end: DateTime(2026, 1, 2),
    );
    final db = await pumpPage(tester, const BillsPage());
    await addBill(db, 'prev-eve', ms(2025, 12, 29, 23, 59), note: '范围前夜');
    await addBill(db, 'day1', ms(2025, 12, 30, 0, 0), type: 1, note: '跨年首日');
    await addBill(db, 'lastday', ms(2026, 1, 2, 23, 59), amount: 200, note: '跨年末日');
    await addBill(db, 'next-day', ms(2026, 1, 3, 0, 0), amount: 500, note: '次日零点');
    await seedRange(tester, seeded);
    await settleProviders(tester);

    // 跨年范围标题两侧都带年份
    expect(find.text('2025年12月30日 ~ 2026年1月2日'), findsOneWidget);
    expect(find.text('跨年首日'), findsOneWidget);
    expect(find.text('跨年末日'), findsOneWidget);
    expect(find.text('范围前夜'), findsNothing);
    expect(find.text('次日零点'), findsNothing);
    // 收入 ¥1.00、支出 ¥2.00、结余 -¥1.00
    expect(find.text('+¥ 1.00'), findsOneWidget);
    expect(find.text('¥ 2.00'), findsOneWidget);
    expect(find.text('-¥ 1.00'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('跨月范围同日折算小计不合并（10 月 5 日与 11 月 5 日）', (tester) async {
    final seeded = ReportDateRange(
      start: DateTime(2026, 10, 5),
      end: DateTime(2026, 11, 5),
    );
    final db = await pumpPage(tester, const BillsPage());
    await addBill(db, 'oct5', ms(2026, 10, 5), amount: 100, note: '十月五日');
    await addBill(db, 'nov5', ms(2026, 11, 5), amount: 200, note: '十一月五日');
    await seedRange(tester, seeded);
    await settleProviders(tester);

    expect(find.text('十月五日'), findsOneWidget);
    expect(find.text('十一月五日'), findsOneWidget);
    // 修复回归：按完整年月日匹配，两组小计各自只含本日账单
    expect(find.text('支出 ¥ 1.00'), findsOneWidget);
    expect(find.text('支出 ¥ 2.00'), findsOneWidget);
    expect(find.text('支出 ¥ 3.00'), findsNothing);
    await disposePage(tester, db);
  });

  testWidgets('退出范围回按月，范围选择保留供再次进入', (tester) async {
    final now = DateTime.now();
    final seeded = ReportDateRange(
      start: DateTime(2026, 5, 10),
      end: DateTime(2026, 5, 20),
    );
    final db = await pumpPage(tester, const BillsPage());
    await addBill(db, 'may12', ms(2026, 5, 12), note: '五月内');
    await addBill(
      db,
      'this-month',
      ms(now.year, now.month, 10),
      note: '本月账单',
    );
    await seedRange(tester, seeded);
    await settleProviders(tester);
    expect(find.text('本月账单'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('range-bar-exit')));
    await settleRoute(tester);

    // 回到按月：当月账单可见，范围账单隐藏
    expect(find.byTooltip('上一月'), findsOneWidget);
    expect(find.text('本月账单'), findsOneWidget);
    expect(find.text('五月内'), findsNothing);
    // 范围选择保留
    expect(containerOf(tester).read(selectedRangeProvider), seeded);
    await disposePage(tester, db);
  });

  testWidgets('范围内没有账单显示范围空态', (tester) async {
    final seeded = ReportDateRange(
      start: DateTime(2001, 1, 1),
      end: DateTime(2001, 1, 2),
    );
    final db = await pumpPage(tester, const BillsPage());
    await seedRange(tester, seeded);
    await settleProviders(tester);
    expect(find.text('该时间段内没有账单'), findsOneWidget);
    expect(find.text('点击下方 + 记一笔'), findsOneWidget);
    await disposePage(tester, db);
  });
}
