import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/balance.dart';
import '../utils/money.dart';
import 'accounts_page.dart';
import 'bill_detail_page.dart';

/// 账户信息页：资产账户的余额与动账明细（只读视图）。
/// 「修改」才进入账户编辑弹窗（名称/图标/期初余额等）。
class AccountInfoPage extends ConsumerWidget {
  const AccountInfoPage({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final bills = ref.watch(allBillsProvider).value ?? const <Bill>[];
    final balance = computeBalances(accounts, bills)[account.id] ?? 0;

    // 该账户的动账明细：支出/收入命中本账户，转账双方都算
    final related = bills
        .where((b) => b.accountId == account.id || b.toAccountId == account.id)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('${account.emoji} ${account.name}'),
        actions: [
          TextButton(
            onPressed: () async {
              final deleted = await showAccountEditor(
                context,
                ref.read(databaseProvider),
                account: account,
                newSort: account.sort,
              );
              // 编辑弹窗里执行了删除 → 返回账户列表
              if (deleted == true && context.mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('修改'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _balanceCard(balance),
          const SizedBox(height: 12),
          _detailCard(context, related),
        ],
      ),
    );
  }

  Widget _balanceCard(int balance) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          kPrimaryColor,
          kPrimaryColor.withValues(alpha: 0.78),
        ]),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('账户余额',
              style: TextStyle(fontSize: 13, color: Colors.white70)),
          const SizedBox(height: 6),
          Text('¥ ${centsToText(balance)}',
              style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
        ],
      ),
    );
  }

  /// 动账明细：按月分组，每月带流入/流出小计
  Widget _detailCard(BuildContext context, List<Bill> related) {
    final byMonth = <String, List<Bill>>{};
    for (final b in related) {
      final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
      byMonth.putIfAbsent('${d.year}-${d.month}', () => []).add(b);
    }
    final monthKeys = byMonth.keys.toList()
      ..sort((a, b) => b.compareTo(a)); // 近月在前

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 6, 14, 4),
              child: Text('动账明细',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (related.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                    child: Text('该账户还没有动账记录',
                        style: TextStyle(color: Colors.grey, fontSize: 13))),
              ),
            for (final key in monthKeys) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                child: _monthHeader(key, byMonth[key]!),
              ),
              for (final b in byMonth[key]!) _billTile(context, b),
            ],
          ],
        ),
      ),
    );
  }

  Widget _monthHeader(String key, List<Bill> bills) {
    var inflow = 0;
    var outflow = 0;
    for (final b in bills) {
      final inAmt = _inflowOf(b);
      final outAmt = _outflowOf(b);
      inflow += inAmt;
      outflow += outAmt;
    }
    final parts = key.split('-');
    return Row(
      children: [
        Text('${parts[1].padLeft(2, '0')}月',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const Spacer(),
        Text('流入:¥${centsToText(inflow)}  流出:¥${centsToText(outflow)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  /// 流入本账户的金额（收入到账 / 转入）
  int _inflowOf(Bill b) {
    if (b.type == 1 && b.accountId == account.id) return b.amount;
    if (b.type == 2 && b.toAccountId == account.id) return b.amount;
    return 0;
  }

  /// 流出本账户的金额（支出 / 转出）
  int _outflowOf(Bill b) {
    if (b.type == 0 && b.accountId == account.id) return b.amount;
    if (b.type == 2 && b.accountId == account.id) return b.amount;
    return 0;
  }

  Widget _billTile(BuildContext context, Bill b) {
    final inflow = _inflowOf(b) > 0;
    final amount = inflow ? _inflowOf(b) : _outflowOf(b);
    final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
    final title = b.type == 2
        ? (b.accountId == account.id ? '转出' : '转入')
        : (b.note.isEmpty ? (b.type == 0 ? '支出' : '收入') : b.note);
    return ListTile(
      dense: true,
      leading: Text(b.type == 2 ? '🔁' : (b.type == 0 ? '💸' : '💰'),
          style: const TextStyle(fontSize: 20)),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${d.month}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      trailing: Text(
        '${inflow ? '+' : '-'}${centsToText(amount)}',
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: inflow ? kIncomeColor : kExpenseColor),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BillDetailPage(bill: b)),
      ),
    );
  }
}
