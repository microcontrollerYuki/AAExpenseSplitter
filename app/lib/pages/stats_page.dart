import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/month_bar.dart';

/// 图表页：本月分类支出饼图 + 近 6 个月收支趋势
class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(selectedMonthProvider);
    final monthBills = ref.watch(monthBillsProvider).value ?? const <Bill>[];
    final allBills = ref.watch(allBillsProvider).value ?? const <Bill>[];
    final categories =
        ref.watch(categoriesProvider).value ?? const <Category>[];
    final catBy = {for (final c in categories) c.id: c};
    // kind=2（AA往来）是内部挂账应收，不计入收支统计
    final internalCatIds = {
      for (final c in categories)
        if (c.kind == 2) c.id
    };

    // 本月分类支出汇总
    final byCat = <String, int>{};
    var totalExpense = 0;
    for (final b in monthBills) {
      if (b.type != 0) continue;
      final key = b.categoryId ?? '';
      byCat[key] = (byCat[key] ?? 0) + b.amount;
      totalExpense += b.amount;
    }
    final catEntries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 近 6 个月趋势（以选中月份为终点）
    final trend = <_MonthSum>[];
    for (var i = 5; i >= 0; i--) {
      final mm = DateTime(m.year, m.month - i, 1);
      var e = 0;
      var inc = 0;
      for (final b in allBills) {
        final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
        if (d.year == mm.year && d.month == mm.month) {
          if (b.type == 0) e += b.amount;
          if (b.type == 1 && !internalCatIds.contains(b.categoryId)) {
            inc += b.amount;
          }
        }
      }
      trend.add(_MonthSum(month: mm.month, expense: e, income: inc));
    }

    return Scaffold(
      appBar: AppBar(
        title: const MonthBar(),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        children: [
          _CategoryPieCard(
              entries: catEntries, catBy: catBy, totalExpense: totalExpense),
          const SizedBox(height: 12),
          _TrendCard(trend: trend),
        ],
      ),
    );
  }
}

class _MonthSum {
  final int month;
  final int expense;
  final int income;
  const _MonthSum(
      {required this.month, required this.expense, required this.income});
}

class _CategoryPieCard extends StatelessWidget {
  const _CategoryPieCard({
    required this.entries,
    required this.catBy,
    required this.totalExpense,
  });

  final List<MapEntry<String, int>> entries;
  final Map<String, Category> catBy;
  final int totalExpense;

  @override
  Widget build(BuildContext context) {
    final top = entries.take(10).toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('本月支出',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('¥ ${centsToText(totalExpense)}',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: kExpenseColor)),
              ],
            ),
            const SizedBox(height: 12),
            if (totalExpense == 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                    child: Text('本月暂无支出',
                        style: TextStyle(color: Colors.grey))),
              )
            else
              Row(
                children: [
                  SizedBox(
                    width: 140,
                    height: 140,
                    child: PieChart(PieChartData(
                      centerSpaceRadius: 26,
                      sectionsSpace: 2,
                      sections: [
                        for (var i = 0; i < top.length; i++)
                          PieChartSectionData(
                            value: top[i].value / 100,
                            color: kPiePalette[i % kPiePalette.length],
                            radius: 44,
                            showTitle: false,
                          ),
                      ],
                    )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      children: [
                        for (var i = 0; i < top.length; i++)
                          _LegendRow(
                            color: kPiePalette[i % kPiePalette.length],
                            label:
                                '${catBy[top[i].key]?.emoji ?? '📦'} ${catBy[top[i].key]?.name ?? '未分类'}',
                            amount: top[i].value,
                            percent: top[i].value / totalExpense * 100,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.amount,
    required this.percent,
  });

  final Color color;
  final String label;
  final int amount;
  final double percent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
              width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13))),
          Text('${centsToText(amount)} · ${percent.toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.trend});

  final List<_MonthSum> trend;

  @override
  Widget build(BuildContext context) {
    var maxVal = 0.0;
    for (final t in trend) {
      maxVal = max(maxVal, t.expense / 100);
      maxVal = max(maxVal, t.income / 100);
    }
    if (maxVal == 0) maxVal = 1;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('近6个月收支趋势',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                _dot(kExpenseColor, '支出'),
                const SizedBox(width: 10),
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
                  barGroups: [
                    for (var i = 0; i < trend.length; i++)
                      BarChartGroupData(
                        x: i,
                        barsSpace: 4,
                        barRods: [
                          BarChartRodData(
                            toY: trend[i].expense / 100,
                            color: kExpenseColor,
                            width: 10,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          BarChartRodData(
                            toY: trend[i].income / 100,
                            color: kIncomeColor,
                            width: 10,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ],
                      ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 26,
                        getTitlesWidget: (v, meta) => SideTitleWidget(
                          meta: meta,
                          child: Text('${trend[v.toInt()].month}月',
                              style: const TextStyle(fontSize: 11)),
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
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
