import 'dart:async';
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
import '../widgets/range_bar.dart';
import '../widgets/report_view_hint.dart';
import '../widgets/year_bar.dart';
import 'category_bills_sheet.dart';

/// 图表页：本月分类支出饼图 + 近 6 个月收支趋势。
/// 默认折合 CNY（R-09 折算模型，饼图与趋势共用同一冻结快照）；可切到
/// 任一原币视图，视图状态与明细页相互独立。
class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(selectedMonthProvider);
    final granularity = ref.watch(statsGranularityProvider);
    final year = ref.watch(selectedYearProvider);
    final range = ref.watch(selectedRangeProvider);
    final view = ref.watch(statsViewProvider);
    final statsType = ref.watch(statsTypeProvider);
    final isIncome = statsType == 1;
    final isYear = granularity == StatsGranularity.year;
    final isRange = granularity == StatsGranularity.range;
    Widget titleBar() => switch (granularity) {
      StatsGranularity.year => const YearBar(),
      StatsGranularity.range => RangeBar(
        onExit: () => ref
            .read(statsGranularityProvider.notifier)
            .select(StatsGranularity.month),
      ),
      _ => const MonthBar(),
    };
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
        appBar: AppBar(title: titleBar(), centerTitle: true),
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
        appBar: AppBar(title: titleBar(), centerTitle: true),
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
    final statsPeriod = statsPeriodOf(
      granularity: granularity,
      month: m,
      year: year,
      range: range,
    );
    final period = statsPeriod.period;
    // 周期前缀与占比标签：本月 / 本年 / 范围内
    final periodPrefix = switch (granularity) {
      StatsGranularity.year => '本年',
      StatsGranularity.range => '范围内',
      _ => '本月',
    };
    final periodKey = switch (granularity) {
      StatsGranularity.year => 'y$year',
      StatsGranularity.range => 'r${period.startMs}-${period.endMs}',
      _ => '${m.year}-${m.month}',
    };

    final List<_MonthSum> trend;
    CategoryStats? pieStats;
    List<CnyExcludedCurrency> excluded = const [];
    FrozenCnyQuotes? frozen;
    BigInt income = BigInt.zero;
    BigInt expense = BigInt.zero;
    if (view.isConverted) {
      // 一次同步冻结：本月饼图与趋势共用同一汇率快照。
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
      pieStats = aggregateCategoryStats(
        bills: convertedBills,
        categories: categories,
        type: statsType,
        currency: null,
        amountOf: (bill) => monthConverted.values[bill.id]!,
      );
      income = monthConverted.sumFor(
        convertedBills.where((b) => b.type == 1).toList(),
      );
      expense = monthConverted.sumFor(
        convertedBills.where((b) => b.type == 0).toList(),
      );
      if (isYear || isRange) {
        // 年 / 范围粒度趋势：按账单日历年月分区复用同一逐笔折算值，
        // 分区之和与总额守恒。
        final months = isYear
            ? [for (var month = 1; month <= 12; month++) (year, month)]
            : _monthSpan(range!);
        trend = <_MonthSum>[
          for (final (y, mo) in months)
            _monthSumFromConvertedIn(y, mo, convertedBills, monthConverted),
        ];
      } else {
        trend = <_MonthSum>[
          for (var i = 5; i >= 0; i--)
            _monthSumConverted(
              DateTime(m.year, m.month - i, 1),
              allBills,
              categories,
              frozen,
            ),
        ];
      }
    } else {
      final report = buildReport(
        // Both the category chart and trend use one database snapshot, so a
        // delayed monthly stream cannot briefly disagree with the trend.
        bills: allBills,
        categories: categories,
        filter: ReportFilter(period: period, currency: view.code!),
      );
      income = report.income;
      expense = report.expense;
      pieStats = isIncome ? report.incomeStats : report.expenseStats;
      // 趋势月分区：范围模式按范围边界裁剪首末月桶，
      // 保证分区之和与报表总额守恒（年 / 月模式为整月桶）。
      final List<(ReportPeriod, int)> trendParts;
      if (isYear) {
        trendParts = [
          for (var month = 1; month <= 12; month++)
            (ReportPeriod.month(DateTime(year, month, 1)), month),
        ];
      } else if (isRange && range != null) {
        trendParts = [
          for (final (y, mo) in _monthSpan(range))
            (
              _clipPeriodToMonth(range.period, y, mo),
              mo,
            ),
        ];
      } else {
        trendParts = [
          for (var i = 5; i >= 0; i--)
            (
              ReportPeriod.month(DateTime(m.year, m.month - i, 1)),
              DateTime(m.year, m.month - i, 1).month,
            ),
        ];
      }
      trend = <_MonthSum>[
        for (final (part, month) in trendParts)
          _monthSumOriginalPeriod(part, month, allBills, categories, view.code!),
      ];
    }

    return Scaffold(
      appBar: AppBar(title: titleBar(), centerTitle: true),
      body: ListView(
        key: ValueKey(
          'stats-$periodKey-${view.code ?? 'converted'}',
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        children: [
          SegmentedButton<StatsGranularity>(
            key: const ValueKey('stats-granularity'),
            segments: const [
              ButtonSegment(
                value: StatsGranularity.month,
                label: Text('月'),
                icon: Icon(Icons.calendar_month),
              ),
              ButtonSegment(
                value: StatsGranularity.year,
                label: Text('年'),
                icon: Icon(Icons.event),
              ),
              ButtonSegment(
                value: StatsGranularity.range,
                label: Text('范围'),
                icon: Icon(Icons.date_range),
              ),
            ],
            selected: {granularity},
            onSelectionChanged: (selection) {
              final next = selection.first;
              if (next != StatsGranularity.range) {
                ref.read(statsGranularityProvider.notifier).select(next);
                return;
              }
              if (ref.read(selectedRangeProvider) != null) {
                // 已有范围选择：直接进入范围粒度
                ref
                    .read(statsGranularityProvider.notifier)
                    .select(StatsGranularity.range);
                return;
              }
              // 首次进入：先选范围，取消则保持原粒度
              unawaited(() async {
                final picked = await pickDateRange(context, ref);
                if (picked == null) return;
                ref.read(selectedRangeProvider.notifier).select(
                  ReportDateRange(start: picked.start, end: picked.end),
                );
                ref
                    .read(statsGranularityProvider.notifier)
                    .select(StatsGranularity.range);
              }());
            },
          ),
          const SizedBox(height: 4),
          CurrencyFilter(
            bills: allBills,
            view: view,
            onSelect: ref.read(statsViewProvider.notifier).select,
          ),
          SegmentedButton<int>(
            key: const ValueKey('stats-type'),
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('支出'),
                icon: Icon(Icons.south_east),
              ),
              ButtonSegment(
                value: 1,
                label: Text('收入'),
                icon: Icon(Icons.north_west),
              ),
            ],
            selected: {statsType},
            onSelectionChanged: (selection) => ref
                .read(statsTypeProvider.notifier)
                .select(selection.first),
          ),
          if (view.isConverted)
            ReportViewHint(quotes: frozen!, excluded: excluded),
          if (isYear || isRange)
            _YearSummaryRow(
              key: const ValueKey('year-summary'),
              income: income,
              expense: expense,
              currency: displayCode,
              converted: view.isConverted,
            ),
          _CategoryPieCard(
            key: ValueKey('$periodKey-${view.code ?? 'converted'}'),
            stats: pieStats,
            currency: displayCode,
            title: '$periodPrefix${isIncome ? '收入' : '支出'}',
            emptyTitle: '$periodPrefix暂无${isIncome ? '收入' : '支出'}',
            periodLabel: periodPrefix,
            isIncome: isIncome,
            onOpenBills: (category, label) => showCategoryBillsSheet(
              context,
              category: category,
              title: label,
            ),
          ),
          const SizedBox(height: 12),
          _TrendCard(
            trend: trend,
            currency: displayCode,
            title: switch (granularity) {
              StatsGranularity.year => '$year年逐月收支趋势',
              StatsGranularity.range => '${statsPeriod.label}逐月收支趋势',
              _ => '近6个月收支趋势',
            },
          ),
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
    // 选集已限定在该月内，全部折算值即该月分区。
    return _MonthSum(
      month: month.month,
      expense: converted.sumFor(selection.where((b) => b.type == 0).toList()),
      income: converted.sumFor(selection.where((b) => b.type == 1).toList()),
    );
  }

  /// 年 / 范围粒度趋势分区：各日历月复用同一逐笔折算值（选集折算一次）。
  /// 按年 + 月双字段匹配，跨年范围不会合并不同年份的同名月份。
  _MonthSum _monthSumFromConvertedIn(
    int year,
    int month,
    List<Bill> convertedBills,
    CnyConvertedBills converted,
  ) {
    final inMonth = convertedBills
        .where((bill) {
          final d = DateTime.fromMillisecondsSinceEpoch(bill.dateMs);
          return d.year == year && d.month == month;
        })
        .toList();
    return _MonthSum(
      month: month,
      expense: converted.sumFor(inMonth.where((b) => b.type == 0).toList()),
      income: converted.sumFor(inMonth.where((b) => b.type == 1).toList()),
    );
  }

  /// 范围模式的月分区：把范围区间裁剪到指定日历月内（首末月为部分月）。
  ReportPeriod _clipPeriodToMonth(ReportPeriod period, int year, int month) {
    final monthStart = DateTime(year, month, 1).millisecondsSinceEpoch;
    final monthEnd = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    final start = period.startMs > monthStart ? period.startMs : monthStart;
    final end = period.endMs < monthEnd ? period.endMs : monthEnd;
    return ReportPeriod(startMs: start, endMs: end);
  }

  _MonthSum _monthSumOriginalPeriod(
    ReportPeriod part,
    int month,
    List<Bill> allBills,
    List<Category> categories,
    String currency,
  ) {
    final summary = buildReport(
      bills: allBills,
      categories: categories,
      filter: ReportFilter(period: part, currency: currency),
    );
    return _MonthSum(
      month: month,
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

/// 自定义范围覆盖的日历月序列（首月到末月，含跨年）。
List<(int, int)> _monthSpan(ReportDateRange range) {
  final months = <(int, int)>[];
  var y = range.firstDay.year;
  var mo = range.firstDay.month;
  while (y < range.lastDay.year ||
      (y == range.lastDay.year && mo <= range.lastDay.month)) {
    months.add((y, mo));
    mo++;
    if (mo > 12) {
      mo = 1;
      y++;
    }
  }
  return months;
}

/// 年粒度收支结余摘要：总览带 ¥ 前缀，原币 CNY 沿用无前缀规则。
class _YearSummaryRow extends StatelessWidget {
  const _YearSummaryRow({
    super.key,
    required this.income,
    required this.expense,
    required this.currency,
    required this.converted,
  });

  final BigInt income;
  final BigInt expense;
  final String currency;
  final bool converted;

  Widget _stat(String label, BigInt value, Color color, {bool signed = false}) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              displayCurrencyAmount(
                value,
                currency,
                signed: signed,
                prefix: converted || currency != 'CNY',
              ),
              key: ValueKey('year-summary-$label'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final balance = income - expense;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _stat('收入', income, kIncomeColor, signed: true),
          _stat('支出', expense, kExpenseColor),
          _stat(
            '结余',
            balance,
            balance >= BigInt.zero ? kIncomeColor : kExpenseColor,
            signed: true,
          ),
        ],
      ),
    );
  }
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
    required this.title,
    required this.emptyTitle,
    required this.periodLabel,
    required this.isIncome,
    required this.onOpenBills,
  });

  final CategoryStats stats;
  final String currency;
  final String title;
  final String emptyTitle;
  final String periodLabel;
  final bool isIncome;
  final void Function(ReportCategoryFilter category, String label) onOpenBills;

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

  // 点击图项打开明细窗口：一级组含直属与二级（root），未分类组为 uncategorized。
  void openGroup(int index) {
    final group = widget.stats.groups[index];
    final category = group.category == null
        ? const ReportCategoryFilter.uncategorized()
        : ReportCategoryFilter.root(group.category!.id);
    final label =
        '${group.category?.emoji ?? '📦'} ${group.category?.name ?? '未分类'}';
    widget.onOpenBills(category, label);
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
                Text(
                  widget.title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Text(
                  displayCurrencyAmount(stats.total, currency),
                  key: ValueKey(
                    widget.isIncome ? 'stats-income-total' : 'stats-expense-total',
                  ),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: widget.isIncome ? kIncomeColor : kExpenseColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (stats.total == BigInt.zero)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(widget.emptyTitle, style: const TextStyle(color: Colors.grey)),
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
                              if (event is FlTapUpEvent) {
                                openGroup(index);
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
                    '按一级分类汇总，点行或扇区查看账单明细',
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
                      periodLabel: widget.periodLabel,
                      onOpenBills: widget.onOpenBills,
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
    required this.periodLabel,
    required this.onOpenBills,
  });

  final CategoryStatGroup group;
  final BigInt total;
  final String currency;
  final Color color;
  final String periodLabel;
  final void Function(ReportCategoryFilter category, String label) onOpenBills;

  void _open() {
    final category = group.category == null
        ? const ReportCategoryFilter.uncategorized()
        : ReportCategoryFilter.root(group.category!.id);
    final label =
        '${group.category?.emoji ?? '📦'} ${group.category?.name ?? '未分类'}';
    onOpenBills(category, label);
  }

  @override
  Widget build(BuildContext context) {
    final label =
        '${group.category?.emoji ?? '📦'} ${group.category?.name ?? '未分类'}';
    final title = Text(label, maxLines: 2, overflow: TextOverflow.ellipsis);
    final subtitle = Text(
      '${displayCurrencyAmount(group.amount, currency, prefix: false)} · '
      '占$periodLabel ${_percent(group.amount, total)}%',
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
        onTap: _open,
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
            onTap: () => onOpenBills(
              ReportCategoryFilter.direct(group.category!.id),
              '$label · 未细分',
            ),
          ),
        for (final child in group.children)
          _LegendRow(
            color: color,
            label: '${child.category.emoji} ${child.category.name}',
            amount: child.amount,
            currency: currency,
            percent: _percent(child.amount, group.amount),
            onTap: () => onOpenBills(
              ReportCategoryFilter.exact(child.category.id),
              '${child.category.emoji} ${child.category.name}',
            ),
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
    this.onTap,
  });

  final Color color;
  final String label;
  final BigInt amount;
  final String currency;
  final String percent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
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
            const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({
    required this.trend,
    required this.currency,
    required this.title,
  });

  final List<_MonthSum> trend;
  final String currency;
  final String title;

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
                Text(
                  title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
