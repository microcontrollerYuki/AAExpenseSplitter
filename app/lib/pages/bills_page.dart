import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/balance.dart';
import '../utils/bill_money.dart';
import '../utils/money.dart';
import '../utils/report.dart';
import '../utils/report_conversion.dart';
import '../utils/transfer_fee.dart';
import '../widgets/currency_filter.dart';
import '../widgets/month_bar.dart';
import '../widgets/report_view_hint.dart';
import 'accounts_page.dart';
import 'bill_detail_page.dart';

/// 明细页（首页）：月份切换 + 月结余摘要 + 按日分组的账单流
/// 月摘要默认折合 CNY（R-09 折算模型），可切到任一原币视图；账单列表
/// 始终全币种原币展示，切换只影响摘要与按日支出小计。
class BillsPage extends ConsumerWidget {
  const BillsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(selectedMonthProvider);
    final view = ref.watch(billsViewProvider);
    final rateService = ref.watch(exchangeRateReadyProvider);
    ref.watch(exchangeRateVersionProvider);
    final billsAsync = ref.watch(monthBillsProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final categoriesAsync = ref.watch(categoriesProvider);
    final categories = categoriesAsync.value ?? const <Category>[];
    final accBy = {for (final a in accounts) a.id: a};
    final catBy = {for (final c in categories) c.id: c};

    final monthBills = billsAsync.value ?? const <Bill>[];
    final period = ReportPeriod.month(month);

    BigInt income;
    BigInt expense;
    FrozenCnyQuotes? frozen;
    List<CnyExcludedCurrency> excluded = const [];
    List<Bill> convertedSelection = const [];
    CnyConvertedBills? converted;
    if (view.isConverted) {
      frozen = FrozenCnyQuotes.capture(rateService.quote);
      convertedSelection = filterReportBills(
        bills: monthBills,
        categories: categories,
        filter: ReportFilter.allCurrencies(period: period),
      );
      converted = CnyConvertedBills.convert(
        bills: convertedSelection,
        quotes: frozen,
      );
      excluded = converted.excludedView;
      income = converted.sumFor(
        convertedSelection.where((b) => b.type == 1).toList(),
      );
      expense = converted.sumFor(
        convertedSelection.where((b) => b.type == 0).toList(),
      );
    } else {
      final totals = buildReport(
        bills: monthBills,
        categories: categories,
        filter: ReportFilter(
          period: period,
          currency: view.code!,
        ),
      );
      income = totals.income;
      expense = totals.expense;
    }

    return Scaffold(
      appBar: AppBar(
        title: const MonthBar(),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: '账本',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AccountsPage())),
          ),
        ],
      ),
      body: Column(
        children: [
          CurrencyFilter(
            bills: monthBills,
            view: view,
            onSelect: ref.read(billsViewProvider.notifier).select,
          ),
          if (view.isConverted)
            ReportViewHint(quotes: frozen!, excluded: excluded),
          categoriesAsync.when(
            loading: () => const SizedBox(
              height: 72,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, stack) => const Padding(
              padding: EdgeInsets.all(16),
              child: Text('读取分类失败，请稍后重试'),
            ),
            data: (_) =>
                (!billsAsync.hasValue ||
                    billsAsync.isReloading ||
                    billsAsync.hasError)
                ? const SizedBox(height: 72)
                : _MonthSummary(
                    income: income,
                    expense: expense,
                    currency: view.isConverted ? 'CNY' : view.code!,
                    converted: view.isConverted,
                  ),
          ),
          Expanded(
            child: billsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => Center(child: Text('读取失败：$e')),
              data: (bills) {
                if (bills.isEmpty) return const _EmptyView();
                final grouped = <String, List<Bill>>{};
                for (final b in bills) {
                  final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
                  grouped
                      .putIfAbsent('${d.year}-${d.month}-${d.day}', () => [])
                      .add(b);
                }
                return ListView.builder(
                  key: ValueKey('bills-${month.year}-${month.month}'),
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: grouped.length,
                  itemBuilder: (_, i) {
                    final dayBills = grouped.values.elementAt(i);
                    final d = DateTime.fromMillisecondsSinceEpoch(
                      dayBills.first.dateMs,
                    );
                    final BigInt dayExp;
                    if (view.isConverted) {
                      dayExp = converted!.sumFor(
                        convertedSelection
                            .where(
                              (b) =>
                                  b.type == 0 &&
                                  DateTime.fromMillisecondsSinceEpoch(
                                    b.dateMs,
                                  ).day ==
                                      d.day,
                            )
                            .toList(),
                      );
                    } else {
                      dayExp = buildReport(
                        bills: dayBills,
                        categories: categories,
                        filter: ReportFilter(
                          period: ReportPeriod.inclusiveDays(d, d),
                          currency: view.code!,
                        ),
                      ).expense;
                    }
                    return _DayGroup(
                      date: d,
                      dayExpense: dayExp,
                      currency: view.isConverted ? 'CNY' : view.code!,
                      converted: view.isConverted,
                      bills: dayBills,
                      accBy: accBy,
                      catBy: catBy,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({
    required this.income,
    required this.expense,
    required this.currency,
    required this.converted,
  });

  final BigInt income;
  final BigInt expense;
  final String currency;
  final bool converted;

  Widget _stat(String label, BigInt cents, Color color, {bool signed = false}) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              displayCurrencyAmount(
                cents,
                currency,
                signed: signed,
                prefix: converted || currency != 'CNY',
              ),
              key: ValueKey('summary-$label'),
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
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.date,
    required this.dayExpense,
    required this.currency,
    required this.converted,
    required this.bills,
    required this.accBy,
    required this.catBy,
  });

  final DateTime date;
  final BigInt dayExpense;
  final String currency;
  final bool converted;
  final List<Bill> bills;
  final Map<String, Account> accBy;
  final Map<String, Category> catBy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Row(
            children: [
              Text(
                dayTitle(date),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '支出 ${displayCurrencyAmount(dayExpense, currency, prefix: converted || currency != 'CNY')}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final b in bills) _BillTile(bill: b, accBy: accBy, catBy: catBy),
      ],
    );
  }
}

/// 账单行：轻滑露出红色删除按钮，点按钮才删除（AA 账单锁定不提供滑动）
class _BillTile extends ConsumerStatefulWidget {
  const _BillTile({
    required this.bill,
    required this.accBy,
    required this.catBy,
  });

  final Bill bill;
  final Map<String, Account> accBy;
  final Map<String, Category> catBy;

  @override
  ConsumerState<_BillTile> createState() => _BillTileState();
}

class _BillTileState extends ConsumerState<_BillTile> {
  static const double _reveal = 76;
  double _dx = 0;

  Future<void> _delete(Bill bill, Bill? fee) async {
    final db = ref.read(databaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    Bill? deletedTransfer;
    Bill? deletedFee;
    try {
      if (bill.type == 2) {
        // Hold the post-delete snapshots in the same transaction. Undo must
        // never adopt another writer's changes as its expected state.
        await db.transaction(() async {
          await db.softDeleteTransferWithFee(
            expectedTransfer: bill,
            expectedFee: fee,
          );
          deletedTransfer = await (db.select(
            db.bills,
          )..where((row) => row.id.equals(bill.id))).getSingle();
          deletedFee = await db.getTransferFee(bill.id);
        });
      } else {
        await db.softDeleteBill(bill.id);
      }
    } on StateError catch (error) {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    }
    if (!messenger.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          bill.type == 2 && fee != null && fee.deletedAt == null
              ? '已删除转账及手续费'
              : '已删除 1 笔账单',
        ),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            try {
              if (deletedTransfer != null) {
                await db.restoreTransferWithFee(
                  expectedTransfer: deletedTransfer!,
                  expectedFee: deletedFee,
                );
              } else {
                await db.restoreBill(bill.id);
              }
            } on StateError catch (error) {
              if (messenger.mounted) {
                messenger.showSnackBar(SnackBar(content: Text(error.message)));
              }
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill;
    final cat = bill.categoryId == null ? null : widget.catBy[bill.categoryId];
    final categoryPath = CategoryHierarchy(widget.catBy.values)
        .pathOf(bill.categoryId);
    final acc = widget.accBy[bill.accountId];
    final toAcc = bill.toAccountId == null
        ? null
        : widget.accBy[bill.toAccountId];
    final isTransfer = bill.type == 2;

    final String title;
    final String subtitle;
    if (isTransfer) {
      title = '转账';
      subtitle = '${acc?.name ?? '?'} → ${toAcc?.name ?? '?'}';
    } else {
      // AA 支出账单按设计图标为「AA平分：项目」；份额账单已带 AA 语义备注则不重复前缀
      final baseTitle = bill.note.isNotEmpty ? bill.note : categoryPath;
      title = (bill.isAa && bill.type == 0 && !baseTitle.startsWith('AA'))
          ? 'AA平分：$baseTitle'
          : baseTitle;
      subtitle =
          [
            categoryPath,
            acc?.name ?? '',
          ].where((s) => s.isNotEmpty).join(' · ') +
          (acc != null &&
                  (acc.currency != bill.currency ||
                      bill.accountAmount != bill.amount)
              ? '\n${bill.type == 0
                    ? '实际扣款'
                    : bill.type == 1
                    ? '实际入账'
                    : '账户变动'} ${displayCurrencyAmount(BigInt.from(bill.accountAmount), acc.currency)}'
              : '');
    }

    final String trailing;
    final Color trailingColor;
    if (bill.type == 0) {
      trailing = displayBillAmount(bill);
      trailingColor = kExpenseColor;
    } else if (bill.type == 1) {
      trailing = displayBillAmount(bill);
      trailingColor = kIncomeColor;
    } else {
      final incoming = transferIncomingAmount(bill, widget.accBy);
      final isSameTransfer =
          isTransfer &&
          acc?.currency == toAcc?.currency &&
          bill.currency == acc?.currency &&
          incoming == bill.accountAmount;
      trailing = isTransfer && !isSameTransfer
          ? '${acc == null ? '出账待确认' : displayCurrencyAmount(BigInt.from(bill.accountAmount), acc.currency)}\n→ ${incoming == null ? '入账待确认' : displayCurrencyAmount(BigInt.from(incoming), toAcc!.currency)}'
          : displayBillAmount(bill);
      trailingColor = Colors.black54;
    }

    final icon = isTransfer ? '🔁' : (cat?.emoji ?? '❓');

    final tile = LayoutBuilder(
      builder: (context, constraints) => ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.grey.shade100,
          child: Text(icon, style: const TextStyle(fontSize: 19)),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
        trailing: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.45),
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
        onTap: () {
          // 已滑开时，点账单本体 = 收起按钮，不进入编辑
          if (_dx > 0) {
            setState(() => _dx = 0);
            return;
          }
          showBillDetailSheet(context: context, bill: bill);
        },
      ),
    );

    final feeState = isTransfer
        ? ref.watch(transferFeeProvider(bill.id))
        : null;
    final accountState = ref.watch(accountsProvider);
    final billsState = ref.watch(monthBillsProvider);
    final feeManageable =
        feeState != null &&
        billsState.hasValue &&
        !billsState.isLoading &&
        !billsState.hasError &&
        feeState.hasValue &&
        !feeState.isLoading &&
        !feeState.hasError &&
        accountState.hasValue &&
        !accountState.isLoading &&
        !accountState.hasError &&
        canManageTransferFee(bill, feeState.value, widget.accBy);
    final feeReadOnly =
        bill.feeTransferId != null ||
        bill.feeDeletedWithTransferAt != null ||
        (isTransfer && !feeManageable);
    if (bill.aaGroupId != null || feeReadOnly) return tile;

    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              color: kExpenseColor,
              padding: const EdgeInsets.only(right: 10),
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline, color: Colors.white),
                onPressed: () {
                  setState(() => _dx = 0);
                  _delete(bill, feeState?.value);
                },
              ),
            ),
          ),
          GestureDetector(
            onHorizontalDragUpdate: (d) =>
                setState(() => _dx = (_dx - d.delta.dx).clamp(0.0, _reveal)),
            onHorizontalDragEnd: (_) =>
                setState(() => _dx = _dx > _reveal / 2 ? _reveal : 0.0),
            child: Transform.translate(
              offset: Offset(-_dx, 0),
              child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: tile,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Text('🧾', style: TextStyle(fontSize: 44)),
          SizedBox(height: 10),
          Text(
            '本月还没有账单',
            style: TextStyle(fontSize: 15, color: Colors.black54),
          ),
          SizedBox(height: 4),
          Text(
            '点击下方 + 记一笔',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
