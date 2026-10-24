import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/calendar_report.dart';
import '../utils/currency.dart';
import '../utils/money.dart';
import '../widgets/currency_filter.dart';
import '../widgets/month_bar.dart';
import '../widgets/report_view_hint.dart';
import 'calendar_day_sheet.dart';

/// R-08 month calendar. The provider owns the one immutable report used here
/// and by the day sheet; this page never captures a second set of quotes.
class CalendarStatsPage extends ConsumerWidget {
  const CalendarStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(calendarMonthProvider);
    final view = ref.watch(statsViewProvider);
    final bills = ref.watch(allBillsProvider);
    final categories = ref.watch(categoriesProvider);
    final calendar = ref.watch(calendarReportProvider);

    Widget currencyFilter() => CurrencyFilter(
      bills: bills.value ?? const <Bill>[],
      view: view,
      onSelect: ref.read(statsViewProvider.notifier).select,
    );

    Widget frame(Widget body) => Scaffold(
      appBar: AppBar(
        title: MonthBar(
          month: month,
          onSelect: ref.read(calendarMonthProvider.notifier).selectMonth,
        ),
        centerTitle: true,
        actions: [
          IconButton(
            key: const ValueKey('calendar-mode-chart'),
            tooltip: '图表视图',
            onPressed: () =>
                ref.read(statsCalendarModeProvider.notifier).select(false),
            icon: const Icon(Icons.pie_chart_outline),
          ),
        ],
      ),
      body: body,
    );

    Widget status(String message) => frame(
      Column(
        children: [
          currencyFilter(),
          Expanded(child: Center(child: Text(message))),
        ],
      ),
    );

    // Category metadata determines internal-income exclusions. Retained
    // previous AsyncData must not make a loading/error state look complete.
    if (categories.hasError) return status('分类加载失败，暂无法统计');
    if (!categories.hasValue ||
        categories.isLoading ||
        categories.isReloading) {
      return status('正在加载分类…');
    }
    if (bills.hasError) return status('账单读取失败，请稍后重试');
    if (!bills.hasValue || bills.isLoading || bills.isReloading) {
      return status('账单加载中…');
    }
    if (calendar.hasError) return status('日历统计失败，请稍后重试');
    if (!calendar.hasValue || calendar.isLoading || calendar.isReloading) {
      return status('日历加载中…');
    }

    final report = calendar.value!;
    final yearMonth =
        '${report.month.year}-${report.month.month.toString().padLeft(2, '0')}';
    final leading = report.month.weekday - DateTime.monday;
    final cellCount = ((leading + report.days.length + 6) ~/ 7) * 7;

    return frame(
      ListView(
        key: ValueKey('calendar-month-$yearMonth'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        children: [
          currencyFilter(),
          if (report.isConverted)
            ReportViewHint(quotes: report.quotes!, excluded: report.excluded),
          _CalendarMonthSummary(report: report),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Row(
                    children: [
                      for (final label in const [
                        '周一',
                        '周二',
                        '周三',
                        '周四',
                        '周五',
                        '周六',
                        '周日',
                      ])
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                label,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = (constraints.maxWidth - 6 * 4) / 7;
                      final scale = math.max(
                        1.0,
                        MediaQuery.textScalerOf(context).scale(12) / 12,
                      );
                      final height = 98 * scale;
                      return GridView.builder(
                        shrinkWrap: true,
                        primary: false,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 7,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                          childAspectRatio: width / height,
                        ),
                        itemCount: cellCount,
                        itemBuilder: (context, index) {
                          final dayIndex = index - leading;
                          if (dayIndex < 0 || dayIndex >= report.days.length) {
                            return const SizedBox.shrink();
                          }
                          return _CalendarDayTile(
                            day: report.days[dayIndex],
                            currency: report.currency,
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (report.bills.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '本月暂无计入收支的账单，点选日期查看每日明细',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            const Text(
              '点击日期查看当天全部、收入或支出账单',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
        ],
      ),
    );
  }
}

String _calendarAmount(BigInt amount, String code, {bool signed = false}) {
  final currency = Currency.tryFromCode(code);
  if (currency == null) {
    final prefix = signed && amount > BigInt.zero ? '+' : '';
    return '$prefix$amount';
  }
  return formatBigMinorUnits(amount, currency, signed: signed);
}

class _CalendarMonthSummary extends StatelessWidget {
  const _CalendarMonthSummary({required this.report});

  final CalendarReport report;

  Widget _amount(
    String label,
    String key,
    BigInt value,
    Color color, {
    bool signed = false,
  }) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _calendarAmount(value, report.currency, signed: signed),
                key: ValueKey(key),
                style: TextStyle(
                  color: color,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            report.complete ? '本月收支' : '本月收支 · 部分合计',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (!report.complete)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${report.excludedBills.length} 笔缺少可用汇率或币种未知，未纳入合计',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _amount(
                '本月收入',
                'calendar-month-income',
                report.income,
                kIncomeColor,
              ),
              _amount(
                '本月支出',
                'calendar-month-expense',
                report.expense,
                kExpenseColor,
              ),
              _amount(
                '本月结余',
                'calendar-month-balance',
                report.balance,
                kPrimaryColor,
                signed: true,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _CalendarDayTile extends StatelessWidget {
  const _CalendarDayTile({required this.day, required this.currency});

  final CalendarReportDay day;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final date = day.date;
    final keyDate =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final income = _calendarAmount(day.income, currency);
    final expense = _calendarAmount(day.expense, currency);
    final unit = Currency.tryFromCode(currency) == null
        ? '$currency 最小单位'
        : currency;
    final state = day.bills.isEmpty
        ? '无账单'
        : day.complete
        ? '${day.bills.length}笔账单'
        : '部分合计，${day.excludedBills.length}笔未纳入';
    final description =
        '${date.year}年${date.month}月${date.day}日，'
        '收入$income，支出$expense，$unit，$state';
    void openDay() => showCalendarDaySheet(context, date: date);

    Widget moneyLine(String label, String amount, Color color, String kind) =>
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '$label $amount',
              key: ValueKey('calendar-day-$kind-$keyDate'),
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        );

    return Semantics(
      key: ValueKey('calendar-day-$keyDate'),
      label: description,
      button: true,
      excludeSemantics: true,
      onTap: openDay,
      child: Material(
        color: day.bills.isEmpty
            ? const Color(0xFFF7F8F7)
            : const Color(0xFFF0F6F2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: openDay,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${date.day}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                if (day.bills.isEmpty)
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '无账单',
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  )
                else ...[
                  moneyLine('收', income, kIncomeColor, 'income'),
                  const SizedBox(height: 2),
                  moneyLine('支', expense, kExpenseColor, 'expense'),
                  if (!day.complete)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '未纳入${day.excludedBills.length}笔',
                        style: const TextStyle(fontSize: 9, color: Colors.grey),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
