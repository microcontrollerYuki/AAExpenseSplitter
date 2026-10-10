import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'edit_bill_page.dart';

/// Shared entry point for bills, account activity and future report details.
/// Keep the sheet in the stack while editing so returning retains the list.
Future<void> showBillDetailSheet({
  required BuildContext context,
  required Bill bill,
}) {
  FocusScope.of(context).unfocus();
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
          child: SafeArea(top: false, child: BillDetailPage(bill: bill)),
        ),
      ),
    ),
  );
}

/// 只读账单详情内容，按下「修改」才进入编辑。
/// 结算收支仅允许修改本机账户 / 备注；旧转账及 AA 伴生应收保持只读。
class BillDetailPage extends ConsumerWidget {
  const BillDetailPage({super.key, required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billState = ref.watch(allBillsProvider);
    if (billState.hasError) {
      return _status(context, const Text('账单读取失败，请返回后重试'));
    }
    if (!billState.hasValue) {
      return _status(context, const CircularProgressIndicator());
    }
    Bill? latest;
    for (final b in billState.value!) {
      if (b.id == this.bill.id) {
        latest = b;
        break;
      }
    }
    if (latest == null) {
      return _status(context, const Text('账单已删除或不存在'));
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

    return _frame(
      context,
      onEdit: () {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => EditBillPage(bill: bill)),
        );
      },
      child: SingleChildScrollView(
        key: const ValueKey('bill-detail-scroll'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _amountCard(bill, acc, toAcc),
            const SizedBox(height: 12),
            _infoCard(
              bill,
              cat,
              CategoryHierarchy(categories).pathOf(bill.categoryId),
              acc,
              toAcc,
              isAa,
              isSettlement,
            ),
          ],
        ),
      ),
    );
  }

  Widget _status(BuildContext context, Widget child) => _frame(
    context,
    child: SingleChildScrollView(
      key: const ValueKey('bill-detail-scroll'),
      padding: const EdgeInsets.all(32),
      child: Center(heightFactor: 1, child: child),
    ),
  );

  Widget _frame(
    BuildContext context, {
    required Widget child,
    VoidCallback? onEdit,
  }) => Column(
    key: const ValueKey('bill-detail-sheet'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 24,
        child: Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 20, right: 8, bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '账单详情',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (onEdit != null)
              TextButton(onPressed: onEdit, child: const Text('修改')),
            IconButton(
              tooltip: '关闭详情',
              onPressed: () {
                if (ModalRoute.of(context)?.isCurrent != true) return;
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Flexible(fit: FlexFit.loose, child: child),
    ],
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
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '$sign¥ ${centsToText(bill.amount)}',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: amountColor,
              ),
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
