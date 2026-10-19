import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/bill_money.dart';
import '../utils/category_stats.dart';
import '../utils/currency.dart';
import '../utils/report.dart';
import '../utils/report_conversion.dart';
import '../widgets/currency_filter.dart';
import '../widgets/month_bar.dart';
import '../widgets/report_view_hint.dart';

/// 图表页：本月分类支出饼图 + 近 6 个月收支趋势。
/// 默认折合 CNY（R-09 折算模型，饼图与趋势共用同一冻结快照）；可切到
/// 任一原币视图，视图状态与明细页相互独立。
class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(selectedMonthProvider);
    final view = ref.watch(statsViewProvider);
    final rateService = ref.watch(exchangeRateReadyProvider);
    ref.watch(exchangeRateVersionProvider);
    final monthBillsAsync = ref.watch(monthBillsProvider);
    final allBillsAsync = ref.watch(allBillsProvider);
    final allBills = allBillsAsync.value ?? const <Bill>[];
    final categoriesAsync = ref.watch(categoriesProvider);
    // Internal-income exclusions require the category metadata. Never draw
    // provisional income totals while that metadata is missing or failed.
    if (categoriesAsync.isLoading || categoriesAsync.hasError) {
      return Scaffold(
        appBar: AppBar(title: const MonthBar(), centerTitle: true),
        body: Column(
          children: [
            CurrencyFilter(
              bills: allBills,
              view: view,
              onSelect: ref.read(statsViewProvider.notifier).select,
            ),
            Expanded(
              child: Center(
                child: categoriesAsync.hasError
                    ? const Text('分类加载失败，暂无法统计')
                    : const Text('正在加载分类…'),
              ),
            ),
          ],
        ),
      );
    }
    if (!monthBillsAsync.hasValue ||
        !allBillsAsync.hasValue ||
        monthBillsAsync.isReloading ||
        allBillsAsync.isReloading ||
        monthBillsAsync.hasError ||
        allBillsAsync.hasError) {
      final failed = monthBillsAsync.hasError || allBillsAsync.hasError;
      return Scaffold(
        appBar: AppBar(title: const MonthBar(), centerTitle: true),
        body: Column(
          children: [
            CurrencyFilter(
              bills: allBills,
              view: view,
              onSelect: ref.read(statsViewProvider.notifier).select,
            ),
            Expanded(
              child: Center(child: Text(failed ? '账单读取失败，请稍后重试' : '账单加载中…')),
            ),
          ],
        ),
      );
    }
    final categories = categoriesAsync.value ?? const <Category>[];
    final displayCode = view.isConverted ? 'CNY' : view.code!;
    final period = ReportPeriod.month(m);

    final List<_MonthSum> trend;
    CategoryStats? convertedExpenseStats;
    List<CnyExcludedCurrency> excluded = const [];
    FrozenCnyQuotes? frozen;
    if (view.isConverted) {
      // 一次同步冻结：本月饼图与 6 个月趋势共用同一汇率快照。
      frozen = FrozenCnyQuotes.capture(rateService.quote);
      final monthSelection = filterReportBills(
        bills: allBills,
        categories: categories,
        filter: ReportFilter.allCurrencies(period: period),
      );
      final monthConverted = CnyConvertedBills.convert(
        bills: monthSelection,
        quotes: frozen,
      );
      excluded = monthConverted.excludedView;
      final convertedBills = monthSelection
          .where((b) => monthConverted.values.containsKey(b.id))
          .toList();
      convertedExpenseStats = aggregateCategoryStats(
        bills: convertedBills,
        categories: categories,
        type: 0,
        currency: null,
        amountOf: (bill) => monthConverted.values[bill.id]!,
      );
      trend = <_MonthSum>[
        for (var i = 5; i >= 0; i--)
          _monthSumConverted(
            DateTime(m.year, m.month - i, 1),
            allBills,
            categories,
            frozen,
          ),
      ];
    } else {
      final report = buildReport(
        // Both the category chart and trend use one database snapshot, so a
        // delayed monthly stream cannot briefly disagree with the trend.
        bills: allBills,
        categories: categories,
        filter: ReportFilter(period: period, currency: view.code!),
      );
      convertedExpenseStats = report.expenseStats;
      trend = <_MonthSum>[
        for (var i = 5; i >= 0; i--)
          _monthSumOriginal(
            DateTime(m.year, m.month - i, 1),
            allBills,
            categories,
            view.code!,
          ),
      ];
    }

    return Scaffold(
      appBar: AppBar(title: const MonthBar(), centerTitle: true),
      body: ListView(
        key: ValueKey('stats-${m.year}-${m.month}-${view.code ?? 'converted'}'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        children: [
          CurrencyFilter(
            bills: allBills,
            view: view,
            onSelect: ref.read(statsViewProvider.notifier).select,
          ),
          if (view.isConverted)
            ReportViewHint(quotes: frozen!, excluded: excluded),
          _CategoryPieCard(
            key: ValueKey(
              '${m.year}-${m.month}-${view.code ?? 'converted'}',
            ),
            stats: convertedExpenseStats,
            currency: displayCode,
          ),
          const SizedBox(height: 12),
          _TrendCard(trend: trend, currency: displayCode),
        ],
      ),
    );
  }

  _MonthSum _monthSumConverted(
    DateTime month,
    List<Bill> allBills,
    List<Category> categories,
    FrozenCnyQuotes frozen,
  ) {
    final selection = filterReportBills(
      bills: allBills,
      categories: categories,
      filter: ReportFilter.allCurrencies(
        period: ReportPeriod.month(month),
      ),
    );
    final converted = CnyConvertedBills.convert(
      bills: selection,
      quotes: frozen,
    );
    return _MonthSum(
      month: month.month,
      expense: converted.sumFor(
        selection.where((b) => b.type == 0).toList(),
      ),
      income: converted.sumFor(
        selection.where((b) => b.type == 1).toList(),
      ),
    );
  }

  _MonthSum _monthSumOriginal(
    DateTime month,
    List<Bill> allBills,
    List<Category> categories,
    String currency,
  ) {
    final summary = buildReport(
      bills: allBills,
      categories: categories,
      filter: ReportFilter(
        period: ReportPeriod.month(month),
        currency: currency,
      ),
    );
    return _MonthSum(
      month: month.month,
      expense: summary.expense,
      income: summary.income,
    );
  }
}

class _MonthSum {
  final int month;
  final BigInt expense;
  final BigInt income;
  const _MonthSum({
    required this.month,
    required this.expense,
    required this.income,
  });
}

// Only chart geometry uses double; labels and percentages retain exact integers.
double _chartValue(BigInt units, String code) {
  final digits = Currency.tryFromCode(code)?.minorUnitDigits ?? 0;
  return units.toDouble() / pow(10, digits);
}

String _percent(BigInt amount, BigInt total) => total == BigInt.zero
    ? '0'
    : ((amount * BigInt.from(100) + total ~/ BigInt.two) ~/ total).toString();

class _CategoryPieCard extends StatefulWidget {
  const _CategoryPieCard({
    super.key,
    required this.stats,
    required this.currency,
  });

  final CategoryStats stats;
  final String currency;

  @override
  State<_CategoryPieCard> createState() => _CategoryPieCardState();
}

class _CategoryPieCardState extends State<_CategoryPieCard> {
  int? _touchedIndex;

  @override
  void didUpdateWidget(covariant _CategoryPieCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stats != widget.stats) _touchedIndex = null;
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final currency = widget.currency;
    final selected = _touchedIndex == null
        ? null
        : stats.groups[_touchedIndex!];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 12,
              runSpacing: 6,
              children: [
                const Text(
                  '本月支出',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Text(
                  displayCurrencyAmount(stats.total, currency),
                  key: const ValueKey('stats-expense-total'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: kExpenseColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (stats.total == BigInt.zero)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text('本月暂无支出', style: TextStyle(color: Colors.grey)),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: SizedBox(
                      width: 160,
                      height: 160,
                      child: PieChart(
                        PieChartData(
                          centerSpaceRadius: 30,
                          sectionsSpace: 2,
                          pieTouchData: PieTouchData(
                            touchCallback: (event, response) {
                              final index =
                                  response?.touchedSection?.touchedSectionIndex;
                              if (index == null ||
                                  index < 0 ||
                                  index >= stats.groups.length) {
                                return;
                              }
                              if (_touchedIndex != index) {
                                setState(() => _touchedIndex = index);
                              }
                            },
                          ),
                          sections: [
                            for (var i = 0; i < stats.groups.length; i++)
                              PieChartSectionData(
                                value: _chartValue(
                                  stats.groups[i].amount,
                                  currency,
                                ),
                                color: kPiePalette[i % kPiePalette.length],
                                radius: i == _touchedIndex ? 52 : 48,
                                showTitle: false,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (selected != null)
                    Text(
                      '${selected.category?.name ?? '未分类'} · '
                      '${displayCurrencyAmount(selected.amount, currency)}',
                      key: const ValueKey('category-pie-tooltip'),
                      textAlign: TextAlign.center,
                    ),
                  const Text(
                    '按一级分类汇总，点开查看二级',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  for (var i = 0; i < stats.groups.length; i++)
                    _CategoryGroupRow(
                      key: ValueKey(stats.groups[i].category?.id),
                      group: stats.groups[i],
                      total: stats.total,
                      currency: currency,
                      color: kPiePalette[i % kPiePalette.length],
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryGroupRow extends StatelessWidget {
  const _CategoryGroupRow({
    super.key,
    required this.group,
    required this.total,
    required this.currency,
    required this.color,
  });

  final CategoryStatGroup group;
  final BigInt total;
  final String currency;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label =
        '${group.category?.emoji ?? '📦'} ${group.category?.name ?? '未分类'}';
    final title = Text(label, maxLines: 2, overflow: TextOverflow.ellipsis);
    final subtitle = Text(
      '${displayCurrencyAmount(group.amount, currency, prefix: false)} · '
      '占本月 ${_percent(group.amount, total)}%',
      style: const TextStyle(fontSize: 12, color: Colors.grey),
    );
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!group.hasChildren) {
      return ListTile(
        key: ValueKey(
          'category-stats-${group.category?.id ?? 'uncategorized'}',
        ),
        contentPadding: EdgeInsets.zero,
        minLeadingWidth: 8,
        leading: dot,
        title: title,
        subtitle: subtitle,
      );
    }
    return ExpansionTile(
      key: ValueKey('category-stats-${group.category!.id}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
      minTileHeight: 64,
      leading: dot,
      title: title,
      subtitle: subtitle,
      shape: const Border(),
      collapsedShape: const Border(),
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '分项金额 · 占本分类',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
        if (group.directAmount != BigInt.zero)
          _LegendRow(
            color: color,
            label: '未细分',
            amount: group.directAmount,
            currency: currency,
            percent: _percent(group.directAmount, group.amount),
          ),
        for (final child in group.children)
          _LegendRow(
            color: color,
            label: '${child.category.emoji} ${child.category.name}',
            amount: child.amount,
            currency: currency,
            percent: _percent(child.amount, group.amount),
          ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.amount,
    required this.currency,
    required this.percent,
  });

  final Color color;
  final String label;
  final BigInt amount;
  final String currency;
  final String percent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  '${displayCurrencyAmount(amount, currency, prefix: false)} · $percent%',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.trend, required this.currency});

  final List<_MonthSum> trend;
  final String currency;

  @override
  Widget build(BuildContext context) {
    var maxVal = 0.0;
    for (final t in trend) {
      maxVal = max(maxVal, _chartValue(t.expense, currency));
      maxVal = max(maxVal, _chartValue(t.income, currency));
    }
    if (maxVal == 0) maxVal = 1;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '近6个月收支趋势',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                _dot(kExpenseColor, '支出'),
                _dot(kIncomeColor, '收入'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxVal * 1.25,
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      maxContentWidth: 280,
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final item = trend[group.x];
                        final expense = rodIndex == 0;
                        return BarTooltipItem(
                          '${item.month}月 ${expense ? '支出' : '收入'}\n'
                          '${displayCurrencyAmount(expense ? item.expense : item.income, currency)}',
                          const TextStyle(color: Colors.white, fontSize: 12),
                        );
                      },
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < trend.length; i++)
                      BarChartGroupData(
                        x: i,
                        barsSpace: 4,
                        barRods: [
                          BarChartRodData(
                            toY: _chartValue(trend[i].expense, currency),
                            color: kExpenseColor,
                            width: 10,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          BarChartRodData(
                            toY: _chartValue(trend[i].income, currency),
                            color: kIncomeColor,
                            width: 10,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ],
                      ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 26,
                        getTitlesWidget: (v, meta) => SideTitleWidget(
                          meta: meta,
                          child: Text(
                            '${trend[v.toInt()].month}月',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                  ),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
