// 分类账单明细窗口（R-05）：点击饼图扇区或分类排行行打开同一个滚动窗口。
// 内容跟随图表页当前的粒度 / 周期 / 币种视图 / 收支维度（watch 同一批
// provider，编辑 / 删除后随流自动刷新）；窗口合计与对应图项一致——
// 同一选集与同一逐笔折算值，总览下额外保留原币 / 实际额与未纳入状态。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/bill_money.dart';
import '../utils/report_conversion.dart';
import '../utils/report_filter.dart';
import 'bill_detail_page.dart';

/// 打开某个分类口径的账单明细窗口。[category] 为点击图项的口径：
/// 一级 = root（直属 + 二级）、二级 = exact、未细分 = direct、未分类 =
/// uncategorized；口径与图项一致，保证窗口合计等于图项金额。
Future<void> showCategoryBillsSheet(
  BuildContext context, {
  required ReportCategoryFilter category,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: constraints.maxHeight * .88),
          child: SafeArea(
            top: false,
            child: CategoryBillsSheet(category: category, title: title),
          ),
        ),
      ),
    ),
  );
}

class CategoryBillsSheet extends ConsumerWidget {
  const CategoryBillsSheet({
    super.key,
    required this.category,
    required this.title,
  });

  final ReportCategoryFilter category;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final granularity = ref.watch(statsGranularityProvider);
    final month = ref.watch(selectedMonthProvider);
    final year = ref.watch(selectedYearProvider);
    final range = ref.watch(selectedRangeProvider);
    final view = ref.watch(statsViewProvider);
    final statsType = ref.watch(statsTypeProvider);
    final rateService = ref.watch(exchangeRateReadyProvider);
    ref.watch(exchangeRateVersionProvider);
    final billsAsync = ref.watch(allBillsProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final categoriesAsync = ref.watch(categoriesProvider);

    final isIncome = statsType == 1;
    final displayCode = view.isConverted ? 'CNY' : view.code!;
    final statsPeriod = statsPeriodOf(
      granularity: granularity,
      month: month,
      year: year,
      range: range,
    );
    final condition =
        '${statsPeriod.label} · ${isIncome ? '收入' : '支出'} · '
        '${view.isConverted ? '总览 · 折合 CNY（估算值）' : '原币 ${view.code!}'}';

    if (categoriesAsync.isLoading || categoriesAsync.hasError) {
      return _SheetFrame(
        title: title,
        condition: condition,
        child: Center(
          child: categoriesAsync.hasError
              ? const Text('分类加载失败，暂无法统计')
              : const CircularProgressIndicator(),
        ),
      );
    }
    if (!billsAsync.hasValue ||
        billsAsync.isReloading ||
        billsAsync.hasError) {
      return _SheetFrame(
        title: title,
        condition: condition,
        child: Center(
          child: billsAsync.hasError
              ? const Text('账单读取失败，请稍后重试')
              : const CircularProgressIndicator(),
        ),
      );
    }

    final categories = categoriesAsync.value ?? const <Category>[];
    final allBills = billsAsync.value ?? const <Bill>[];
    final period = statsPeriod.period;

    // 与图表同一选集：周期 + 维度（converted 全币种，original 单币种），
    // 内部分类收入沿用筛选层排除。
    final base = filterReportBills(
      bills: allBills,
      categories: categories,
      filter: view.isConverted
          ? ReportFilter.allCurrencies(period: period, type: statsType)
          : ReportFilter(
              period: period,
              currency: view.code!,
              type: statsType,
            ),
    );
    final Map<String, BigInt> values;
    if (view.isConverted) {
      final converted = CnyConvertedBills.convert(
        bills: base,
        quotes: FrozenCnyQuotes.capture(rateService.quote),
      );
      values = converted.valuesView;
    } else {
      values = const {};
    }

    // 在同一选集内再按图项口径筛：root 含直属与二级、exact 仅自身、
    // direct 仅直属、uncategorized 仅未分类；金额取同一逐笔折算值。
    final scoped = filterReportBills(
      bills: base,
      categories: categories,
      filter: view.isConverted
          ? ReportFilter.allCurrencies(category: category, type: statsType)
          : ReportFilter(
              category: category,
              currency: view.code!,
              type: statsType,
            ),
    );
    BigInt amountOf(Bill bill) =>
        view.isConverted ? values[bill.id]! : BigInt.from(bill.amount);
    final included = view.isConverted
        ? scoped.where((b) => values.containsKey(b.id)).toList()
        : scoped;
    final total = included.fold(BigInt.zero, (sum, b) => sum + amountOf(b));

    final accBy = {for (final a in accounts) a.id: a};
    final hierarchy = CategoryHierarchy(categories);

    return _SheetFrame(
      title: title,
      condition: condition,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(
                  '共 ${scoped.length} 笔',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const Spacer(),
                // 合计（含 MAX 级大数）在窄屏内缩放，不撑破行
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      '合计 ${displayCurrencyAmount(total, displayCode, prefix: view.isConverted || displayCode != 'CNY')}',
                      key: const ValueKey('category-bills-total'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isIncome ? kIncomeColor : kExpenseColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: scoped.isEmpty
                ? const Center(
                    child: Text(
                      '该分类暂无账单',
                      key: ValueKey('category-bills-empty'),
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: scoped.length,
                    itemBuilder: (context, i) {
                      final bill = scoped[i];
                      final date = DateTime.fromMillisecondsSinceEpoch(
                        bill.dateMs,
                      );
                      final path = hierarchy.pathOf(bill.categoryId);
                      final typeLabel = bill.type == 0 ? '支出' : '收入';
                      final acc = accBy[bill.accountId];
                      final actualLine =
                          (acc != null &&
                              (acc.currency != bill.currency ||
                                  bill.accountAmount != bill.amount))
                          ? '\n实际${bill.type == 0 ? '扣款' : '入账'} ${displayCurrencyAmount(BigInt.from(bill.accountAmount), acc.currency)}'
                          : '';
                      final subtitle =
                          '${date.month}月${date.day}日 · $typeLabel'
                          '${path.isEmpty ? '' : ' · $path'}'
                          '\n${displayCurrencyAmount(BigInt.from(bill.amount), bill.currency, prefix: bill.currency != 'CNY')}$actualLine';
                      final String trailing;
                      final Color trailingColor;
                      if (view.isConverted && !values.containsKey(bill.id)) {
                        trailing = '未纳入';
                        trailingColor = Colors.grey;
                      } else {
                        trailing = displayCurrencyAmount(
                          amountOf(bill),
                          displayCode,
                          prefix: view.isConverted || displayCode != 'CNY',
                        );
                        trailingColor =
                            bill.type == 0 ? kExpenseColor : kIncomeColor;
                      }
                      return LayoutBuilder(
                        builder: (context, constraints) => ListTile(
                          key: ValueKey('category-bill-${bill.id}'),
                          contentPadding:
                              const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          title: Text(
                            bill.note.isEmpty
                                ? (path.isEmpty ? '未分类' : path)
                                : bill.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                          subtitle: Text(
                            subtitle,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          // 金额（含 MAX 级大数）不得占满整行宽度
                          trailing: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth * 0.45,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                trailing,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: trailingColor,
                                ),
                              ),
                            ),
                          ),
                          onTap: () => showBillDetailSheet(
                            context: context,
                            bill: bill,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.condition,
    required this.child,
  });

  final String title;
  final String condition;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('category-bills-close'),
                tooltip: '关闭明细窗口',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            condition,
            key: const ValueKey('category-bills-condition'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Flexible(child: child),
      ],
    );
  }
}
