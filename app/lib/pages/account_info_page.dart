import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/balance.dart';
import '../utils/currency.dart';
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
    final accountState = ref.watch(accountsProvider);
    if (accountState.hasError) {
      return _status(const Text('账户读取失败，请返回后重试'));
    }
    if (!accountState.hasValue) {
      return _status(const CircularProgressIndicator());
    }
    final accounts = accountState.value!;
    Account? latest;
    for (final a in accounts) {
      if (a.id == this.account.id) {
        latest = a;
        break;
      }
    }
    if (latest == null) {
      return _status(const Text('账户已删除或不存在'));
    }
    final account = latest;
    final bills = ref.watch(allBillsProvider).value ?? const <Bill>[];
    final balance =
        computeExactBalances(accounts, bills)[account.id] ?? BigInt.zero;

    // 该账户的动账明细：支出/收入命中本账户，转账双方都算
    final related = bills
        .where(
          (b) =>
              b.deletedAt == null &&
              (b.accountId == account.id || b.toAccountId == account.id),
        )
        .toList();
    final byId = {for (final item in accounts) item.id: item};

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${account.emoji} ${account.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
          _balanceCard(balance, account),
          const SizedBox(height: 12),
          _detailCard(context, related, account, byId),
        ],
      ),
    );
  }

  Widget _status(Widget child) => Scaffold(
    appBar: AppBar(title: const Text('账户信息')),
    body: Center(child: child),
  );

  Widget _balanceCard(BigInt balance, Account account) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [kPrimaryColor, kPrimaryColor.withValues(alpha: 0.78)],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '账户余额',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  account.currency,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _money(balance, account),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 动账明细：按月分组，每月带流入/流出小计
  Widget _detailCard(
    BuildContext context,
    List<Bill> related,
    Account account,
    Map<String, Account> accounts,
  ) {
    final byMonth = <String, List<Bill>>{};
    for (final b in related) {
      final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
      byMonth
          .putIfAbsent(
            '${d.year}-${d.month.toString().padLeft(2, '0')}',
            () => [],
          )
          .add(b);
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
              child: Text(
                '动账明细',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            if (related.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: Text(
                    '该账户还没有动账记录',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              ),
            for (final key in monthKeys) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                child: _monthHeader(key, byMonth[key]!, account, accounts),
              ),
              for (final b in byMonth[key]!)
                _billTile(context, b, account, accounts),
            ],
          ],
        ),
      ),
    );
  }

  Widget _monthHeader(
    String key,
    List<Bill> bills,
    Account account,
    Map<String, Account> accounts,
  ) {
    var inflow = BigInt.zero;
    var outflow = BigInt.zero;
    for (final b in bills) {
      final change = _changeOf(b, account, accounts);
      if (change > BigInt.zero) inflow += change;
      if (change < BigInt.zero) outflow += change;
    }
    final parts = key.split('-');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${parts[0]}年${parts[1]}月',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _flowText(
                '流入:${_money(inflow, account)}',
                Alignment.centerLeft,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _flowText(
                '流出:${_money(outflow, account, magnitude: true)}',
                Alignment.centerRight,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _flowText(String text, Alignment alignment) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: alignment,
    child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
  );

  BigInt _changeOf(Bill bill, Account account, Map<String, Account> accounts) {
    if (bill.deletedAt != null) return BigInt.zero;
    final isSource = bill.accountId == account.id;
    final actual = BigInt.from(bill.accountAmount);
    if (bill.type == 0) return isSource ? -actual : BigInt.zero;
    if (bill.type == 1 || bill.type == 3) {
      return isSource ? actual : BigInt.zero;
    }
    if (bill.type != 2) return BigInt.zero;
    var change = isSource ? -actual : BigInt.zero;
    final incoming = transferIncomingAmount(bill, accounts);
    if (bill.toAccountId == account.id && incoming != null) {
      change += BigInt.from(incoming);
    }
    return change;
  }

  String _money(
    BigInt amount,
    Account account, {
    bool signed = false,
    bool cnySymbol = true,
    bool magnitude = false,
  }) {
    final currency = Currency.tryFromCode(account.currency);
    if (currency == null) {
      final code = account.currency.trim().isEmpty ? '未知币种' : account.currency;
      final prefix = signed && amount > BigInt.zero ? '+' : '';
      final raw = amount.toString();
      final number = magnitude && amount.isNegative
          ? raw.substring(1)
          : '$prefix$raw';
      return '$code $number 最小单位';
    }
    var number = formatBigMinorUnits(amount, currency, signed: signed);
    if (magnitude && amount.isNegative) number = number.substring(1);
    if (currency == Currency.cny) return cnySymbol ? '¥ $number' : number;
    return '${currency.code} $number';
  }

  Widget _billTile(
    BuildContext context,
    Bill b,
    Account account,
    Map<String, Account> accounts,
  ) {
    final amount = _changeOf(b, account, accounts);
    final inflow = amount > BigInt.zero;
    final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
    final title = b.type == 2
        ? (b.accountId == account.id ? '转出' : '转入')
        : (b.note.isEmpty
              ? (b.type == 3
                    ? '余额调节'
                    : b.type == 0
                    ? '支出'
                    : '收入')
              : b.note);
    return LayoutBuilder(
      builder: (context, constraints) => ListTile(
        dense: true,
        leading: Text(
          b.type == 2
              ? '🔁'
              : (b.type == 3
                    ? '⚖️'
                    : b.type == 0
                    ? '💸'
                    : '💰'),
          style: const TextStyle(fontSize: 20),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${d.month}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} · ${account.currency}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.5),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              _money(amount, account, signed: true, cnySymbol: false),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: inflow ? kIncomeColor : kExpenseColor,
              ),
            ),
          ),
        ),
        onTap: () => showBillDetailSheet(context: context, bill: b),
      ),
    );
  }
}
