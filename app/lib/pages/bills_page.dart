import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/month_bar.dart';
import 'accounts_page.dart';
import 'bill_detail_page.dart';

/// 明细页（首页）：月份切换 + 月结余摘要 + 按日分组的账单流
class BillsPage extends ConsumerWidget {
  const BillsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billsAsync = ref.watch(monthBillsProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final accBy = {for (final a in accounts) a.id: a};
    final catBy = {for (final c in categories) c.id: c};

    // kind=2（AA往来）是内部挂账应收，不计入收支统计
    final internalCatIds = {
      for (final c in categories)
        if (c.kind == 2) c.id
    };
    var expense = 0;
    var income = 0;
    for (final b in billsAsync.value ?? const <Bill>[]) {
      if (b.type == 0) expense += b.amount;
      if (b.type == 1 && !internalCatIds.contains(b.categoryId)) {
        income += b.amount;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const MonthBar(),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: '账本',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AccountsPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _MonthSummary(income: income, expense: expense),
          Expanded(
            child: billsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
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
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: grouped.length,
                  itemBuilder: (_, i) {
                    final dayBills = grouped.values.elementAt(i);
                    final d = DateTime.fromMillisecondsSinceEpoch(
                        dayBills.first.dateMs);
                    final dayExp = dayBills
                        .where((b) => b.type == 0)
                        .fold<int>(0, (s, b) => s + b.amount);
                    return _DayGroup(
                      date: d,
                      dayExpense: dayExp,
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
  const _MonthSummary({required this.income, required this.expense});

  final int income;
  final int expense;

  Widget _stat(String label, int cents, Color color, {bool signed = false}) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(centsToText(cents, signed: signed),
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: color)),
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
          _stat('结余', balance, balance >= 0 ? kIncomeColor : kExpenseColor,
              signed: true),
        ],
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.date,
    required this.dayExpense,
    required this.bills,
    required this.accBy,
    required this.catBy,
  });

  final DateTime date;
  final int dayExpense;
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
              Text(dayTitle(date),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54)),
              const Spacer(),
              Text('支出 ${centsToText(dayExpense)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        for (final b in bills)
          _BillTile(bill: b, accBy: accBy, catBy: catBy),
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

  Future<void> _delete() async {
    final db = ref.read(databaseProvider);
    final messenger = ScaffoldMessenger.of(context);
    final billId = widget.bill.id;
    try {
      await db.softDeleteBill(billId);
    } on StateError catch (error) {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    }
    if (!messenger.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: const Text('已删除 1 笔账单'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => db.restoreBill(billId),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill;
    final cat = bill.categoryId == null ? null : widget.catBy[bill.categoryId];
    final acc = widget.accBy[bill.accountId];
    final toAcc =
        bill.toAccountId == null ? null : widget.accBy[bill.toAccountId];
    final isTransfer = bill.type == 2;

    final String title;
    final String subtitle;
    if (isTransfer) {
      title = '转账';
      subtitle = '${acc?.name ?? '?'} → ${toAcc?.name ?? '?'}';
    } else {
      // AA 支出账单按设计图标为「AA平分：项目」；份额账单已带 AA 语义备注则不重复前缀
      final baseTitle = bill.note.isNotEmpty
          ? bill.note
          : (cat?.name ?? '未分类');
      title = (bill.isAa &&
              bill.type == 0 &&
              !baseTitle.startsWith('AA'))
          ? 'AA平分：$baseTitle'
          : baseTitle;
      subtitle = [if (cat != null) cat.name, acc?.name ?? '']
          .where((s) => s.isNotEmpty)
          .join(' · ');
    }

    final String trailing;
    final Color trailingColor;
    if (bill.type == 0) {
      trailing = '-${centsToText(bill.amount)}';
      trailingColor = kExpenseColor;
    } else if (bill.type == 1) {
      trailing = centsToText(bill.amount, signed: true);
      trailingColor = kIncomeColor;
    } else {
      trailing = centsToText(bill.amount);
      trailingColor = Colors.black54;
    }

    final icon = isTransfer ? '🔁' : (cat?.emoji ?? '❓');

    final tile = ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.grey.shade100,
        child: Text(icon, style: const TextStyle(fontSize: 19)),
      ),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15)),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
      trailing: Text(trailing,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: trailingColor)),
      onTap: () {
        // 已滑开时，点账单本体 = 收起按钮，不进入编辑
        if (_dx > 0) {
          setState(() => _dx = 0);
          return;
        }
        // 进入只读详情，按下「修改」才可编辑（2026-10-06 需求）
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => BillDetailPage(bill: bill)),
        );
      },
    );

    if (bill.aaGroupId != null) return tile;

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
                  _delete();
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
          Text('本月还没有账单',
              style: TextStyle(fontSize: 15, color: Colors.black54)),
          SizedBox(height: 4),
          Text('点击下方 + 记一笔',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}
