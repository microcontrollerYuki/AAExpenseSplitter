import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/bill_money.dart';
import '../utils/calendar_report.dart';
import '../widgets/report_view_hint.dart';
import 'bill_detail_page.dart';

/// R-08 每日明细使用日历页已经生成的同一份报表，不再次查询或折算。
Future<void> showCalendarDaySheet(
  BuildContext context, {
  required DateTime date,
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
          constraints: BoxConstraints(maxHeight: constraints.maxHeight * .85),
          child: SafeArea(top: false, child: CalendarDaySheet(date: date)),
        ),
      ),
    ),
  );
}

class CalendarDaySheet extends ConsumerStatefulWidget {
  const CalendarDaySheet({super.key, required this.date});

  final DateTime date;

  @override
  ConsumerState<CalendarDaySheet> createState() => _CalendarDaySheetState();
}

class _CalendarDaySheetState extends ConsumerState<CalendarDaySheet> {
  Future<void> _openBill(String id) async {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final current = ref.read(calendarReportProvider);
    if (!current.hasValue || current.isLoading || current.hasError) return;
    final day = current.value!.dayFor(widget.date);
    Bill? latest;
    for (final bill in day?.bills ?? const <Bill>[]) {
      if (bill.id == id) {
        latest = bill;
        break;
      }
    }
    if (latest == null) return;
    // 公共详情继续订阅最新 ID，并保留 AA / 结算 / 手续费保护。
    await showBillDetailSheet(context: context, bill: latest);
  }

  @override
  Widget build(BuildContext context) {
    final type = ref.watch(calendarDayTypeProvider);
    final reportState = ref.watch(calendarReportProvider);
    final accountState = ref.watch(accountsProvider);
    final categoryState = ref.watch(categoriesProvider);
    if (reportState.hasError ||
        accountState.hasError ||
        categoryState.hasError) {
      return _frame(
        context,
        child: const Center(child: Text('每日明细读取失败，请稍后重试')),
      );
    }
    if (!reportState.hasValue ||
        reportState.isLoading ||
        !accountState.hasValue ||
        accountState.isLoading ||
        !categoryState.hasValue ||
        categoryState.isLoading) {
      return _frame(
        context,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final report = reportState.value!;
    final day = report.dayFor(widget.date);
    if (day == null) {
      return _frame(
        context,
        child: const Center(
          child: Text('该日期不在当前日历月份内', key: ValueKey('calendar-day-empty')),
        ),
      );
    }
    final rows = switch (type) {
      1 => day.incomeBills,
      0 => day.expenseBills,
      _ => day.bills,
    };
    final missingCount = rows
        .where((bill) => day.valueFor(bill) == null)
        .length;
    final partial = missingCount == 0 ? '' : '（部分合计）';
    String money(BigInt value, {bool signed = false}) =>
        displayCurrencyAmount(value, report.currency, signed: signed);
    final total = switch (type) {
      1 => '收入合计 ${money(day.income)}$partial',
      0 => '支出合计 ${money(day.expense)}$partial',
      _ =>
        '收入 ${money(day.income)}\n'
            '支出 ${money(day.expense)}\n'
            '结余 ${money(day.balance, signed: true)}$partial',
    };
    final empty = switch (type) {
      1 => '当天暂无收入账单',
      0 => '当天暂无支出账单',
      _ => '当天暂无账单',
    };
    final accountById = {
      for (final account in accountState.value!) account.id: account,
    };
    final hierarchy = CategoryHierarchy(categoryState.value!);

    return _frame(
      context,
      child: CustomScrollView(
        key: const ValueKey('calendar-day-scroll'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                report.isConverted
                    ? '总览 · 折合 CNY（估算值）'
                    : '原币 ${report.currency}',
                key: const ValueKey('calendar-day-condition'),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ),
          if (report.quotes != null)
            SliverToBoxAdapter(
              // 月度缺率清单不冒充每日清单；每日缺率在下方单独说明。
              child: ReportViewHint(quotes: report.quotes!, excluded: const []),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SegmentedButton<int>(
                key: const ValueKey('calendar-day-type'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: -1, label: Text('全部')),
                  ButtonSegment(value: 1, label: Text('收入')),
                  ButtonSegment(value: 0, label: Text('支出')),
                ],
                selected: {type},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) {
                    ref
                        .read(calendarDayTypeProvider.notifier)
                        .select(selection.first);
                  }
                },
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '共 ${rows.length} 笔',
                    key: const ValueKey('calendar-day-count'),
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        total,
                        key: const ValueKey('calendar-day-total'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: type == 0
                              ? kExpenseColor
                              : type == 1
                              ? kIncomeColor
                              : null,
                        ),
                      ),
                    ),
                  ),
                  if (missingCount != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '有 $missingCount 笔未纳入合计（缺少汇率或未知币种）',
                        key: const ValueKey('calendar-day-partial'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          if (rows.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    empty,
                    key: const ValueKey('calendar-day-empty'),
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final bill = rows[index];
                  return _billRow(
                    context,
                    bill: bill,
                    account: accountById[bill.accountId],
                    path: hierarchy.pathOf(bill.categoryId),
                    day: day,
                    report: report,
                  );
                }, childCount: rows.length),
              ),
            ),
        ],
      ),
    );
  }

  Widget _billRow(
    BuildContext context, {
    required Bill bill,
    required Account? account,
    required String path,
    required CalendarReportDay day,
    required CalendarReport report,
  }) {
    final date = DateTime.fromMillisecondsSinceEpoch(bill.dateMs);
    final time =
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
    final isExpense = bill.type == 0;
    final actualLabel = isExpense ? '实际扣款' : '实际入账';
    final String? actual;
    if (account == null) {
      actual = '$actualLabel ${bill.accountAmount} 最小单位（账户币种未知）';
    } else if (account.currency != bill.currency ||
        bill.accountAmount != bill.amount) {
      actual =
          '$actualLabel '
          '${displayCurrencyAmount(BigInt.from(bill.accountAmount), account.currency)}';
    } else {
      actual = null;
    }
    final value = day.valueFor(bill);
    final amount = value == null
        ? '未纳入'
        : displayCurrencyAmount(value, report.currency);
    final color = value == null
        ? Colors.grey
        : isExpense
        ? kExpenseColor
        : kIncomeColor;

    return LayoutBuilder(
      builder: (context, constraints) => InkWell(
        key: ValueKey('calendar-day-bill-${bill.id}'),
        onTap: () => _openBill(bill.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bill.note.isEmpty ? path : bill.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$time · ${isExpense ? '支出' : '收入'} · $path',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 2),
                    _amountLine(
                      '原币 ${displayCurrencyAmount(BigInt.from(bill.amount), bill.currency)}',
                    ),
                    if (actual != null) _amountLine(actual),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .4,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    amount,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _amountLine(String text) => Align(
    alignment: Alignment.centerLeft,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    ),
  );

  Widget _frame(BuildContext context, {required Widget child}) => Column(
    key: const ValueKey('calendar-day-sheet'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${widget.date.year}年${widget.date.month}月${widget.date.day}日',
                key: const ValueKey('calendar-day-date'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('calendar-day-close'),
              tooltip: '关闭每日明细',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
      Flexible(child: child),
    ],
  );
}
