import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'edit_bill_page.dart';

/// 账单详情页：**只读**展示一条账单，按下「修改」才进入编辑（需求 2026-10-06）。
/// 结算收支仅允许修改本机账户 / 备注；旧转账及 AA 伴生应收保持只读。
class BillDetailPage extends ConsumerWidget {
  const BillDetailPage({super.key, required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billState = ref.watch(allBillsProvider);
    if (billState.hasError) {
      return _status(const Text('账单读取失败，请返回后重试'));
    }
    if (!billState.hasValue) {
      return _status(const CircularProgressIndicator());
    }
    Bill? latest;
    for (final b in billState.value!) {
      if (b.id == this.bill.id) {
        latest = b;
        break;
      }
    }
    if (latest == null) {
      return _status(const Text('账单已删除或不存在'));
    }
    // 展示和再次编辑使用同一份最新记录，构造参数只提供稳定 ID。
    final bill = latest;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final categories =
        ref.watch(categoriesProvider).value ?? const <Category>[];

    Account? acc;
    for (final a in accounts) {
      if (a.id == bill.accountId) acc = a;
    }
    Account? toAcc;
    if (bill.toAccountId != null) {
      for (final a in accounts) {
        if (a.id == bill.toAccountId) toAcc = a;
      }
    }
    Category? cat;
    if (bill.categoryId != null) {
      for (final c in categories) {
        if (c.id == bill.categoryId) cat = c;
      }
    }
    final isAa = bill.aaGroupId != null || bill.isAa;
    final isSettlement = bill.settlementId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('账单详情'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => EditBillPage(bill: bill))),
            child: const Text('修改'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _amountCard(bill, acc, toAcc),
          const SizedBox(height: 12),
          _infoCard(
            bill, cat, CategoryHierarchy(categories).pathOf(bill.categoryId),
            acc, toAcc, isAa, isSettlement,
          ),
        ],
      ),
    );
  }

  Widget _status(Widget child) => Scaffold(
    appBar: AppBar(title: const Text('账单详情')),
    body: Center(child: child),
  );

  Widget _amountCard(Bill bill, Account? acc, Account? toAcc) {
    final amountColor = bill.type == 0
        ? kExpenseColor
        : (bill.type == 1 ? kIncomeColor : Colors.black87);
    final typeLabel = bill.type == 0 ? '支出' : (bill.type == 1 ? '收入' : '转账');
    final sign = bill.type == 0 ? '-' : (bill.type == 1 ? '+' : '');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: amountColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            typeLabel,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 6),
          Text(
            '$sign¥ ${centsToText(bill.amount)}',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: amountColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            bill.type == 2
                ? '${acc?.name ?? '—'} → ${toAcc?.name ?? '—'}'
                : (acc?.name ?? '—'),
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(
    Bill bill,
    Category? cat,
    String categoryPath,
    Account? acc,
    Account? toAcc,
    bool isAa,
    bool isSettlement,
  ) {
    final d = DateTime.fromMillisecondsSinceEpoch(bill.dateMs);
    String two(int v) => v.toString().padLeft(2, '0');

    final rows = <Widget>[
      _row('分类', cat == null ? categoryPath : '${cat.emoji} $categoryPath'),
      _row('账户', acc == null ? '—' : '${acc.emoji} ${acc.name}'),
      if (bill.type == 2)
        _row('转入账户', toAcc == null ? '—' : '${toAcc.emoji} ${toAcc.name}'),
      _row(
        '时间',
        '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}',
      ),
      _row('备注', bill.note.isEmpty ? '—' : bill.note),
      if (isAa) _row('AA', 'AA 平分账单（修改需同步给伙伴重新确认）'),
      if (isSettlement) _row('结算', 'AA 结算生成的收支明细'),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: rows),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
