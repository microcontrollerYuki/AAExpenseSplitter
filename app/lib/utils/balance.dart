import '../data/app_database.dart';
import '../data/presets.dart';
import 'currency.dart';

/// 各账户币种的最小单位余额：期初 + 实际流入 - 实际流出 + 有符号调节。
/// 交易原币 amount 不能直接作为跨币账户的实际收付款额。
/// 单笔可持久化为 int64，但聚合结果可超出范围，因此使用精确整数。
Map<String, BigInt> computeExactBalances(
  List<Account> accounts,
  List<Bill> bills,
) {
  final byId = {for (final account in accounts) account.id: account};
  final b = {for (final a in accounts) a.id: BigInt.from(a.initBalance)};
  for (final t in bills) {
    if (t.deletedAt != null) continue;
    final from = t.accountId;
    final actual = BigInt.from(t.accountAmount);
    if (t.type == 0) {
      if (b.containsKey(from)) b[from] = b[from]! - actual;
    } else if (t.type == 1) {
      if (b.containsKey(from)) b[from] = b[from]! + actual;
    } else if (t.type == 2) {
      if (b.containsKey(from)) b[from] = b[from]! - actual;
      final incoming = transferIncomingAmount(t, byId);
      if (incoming != null) {
        b[t.toAccountId!] = b[t.toAccountId!]! + BigInt.from(incoming);
      }
    } else if (t.type == 3) {
      if (b.containsKey(from)) b[from] = b[from]! + actual;
    }
  }
  return b;
}

/// 入账额以转入账户最小单位保存。旧同币行可等额兜底；跨币缺额不猜汇率。
/// 与账户动账明细共用，避免资产余额和月流入使用不同口径。
int? transferIncomingAmount(Bill bill, Map<String, Account> accounts) {
  if (bill.type != 2) return null;
  final source = accounts[bill.accountId];
  final target = accounts[bill.toAccountId];
  if (source == null ||
      target == null ||
      bill.currency != source.currency ||
      bill.amount != bill.accountAmount) {
    return null;
  }
  final sameCurrency = source.currency == target.currency;
  if (!sameCurrency &&
      (bill.isAa ||
          bill.aaGroupId != null ||
          bill.settlementId != null ||
          source.type == 4 ||
          target.type == 4 ||
          source.id == kAaCreditAccountId ||
          target.id == kAaCreditAccountId)) {
    return null;
  }
  final incoming = bill.toAccountAmount;
  if (incoming == null) return sameCurrency ? bill.accountAmount : null;
  if (incoming < 0 ||
      (sameCurrency && incoming != bill.accountAmount) ||
      (!sameCurrency && (incoming == 0 || bill.accountAmount <= 0))) {
    return null;
  }
  return incoming;
}

/// 只合计计入净资产的账户，币种之间不折算、不相加。
/// 未知历史代码保留为独立键，不能静默归到人民币。
Map<String, BigInt> computeExactNetWorthByCurrency(
  List<Account> accounts,
  Map<String, BigInt> balances,
) {
  final totals = <String, BigInt>{};
  for (final account in accounts) {
    if (!account.includeNetWorth) continue;
    final code =
        Currency.tryFromCode(account.currency)?.code ?? account.currency;
    totals[code] =
        (totals[code] ?? BigInt.zero) +
        (balances[account.id] ?? BigInt.from(account.initBalance));
  }
  return totals;
}

final _minInt64 = BigInt.parse('-9223372036854775808');
final _maxInt64 = BigInt.parse('9223372036854775807');

Map<String, int> _checkedIntBalances(Map<String, BigInt> values) {
  return values.map((key, value) {
    if (value < _minInt64 || value > _maxInt64) {
      throw RangeError('账户聚合金额超出 int64 范围：$key=$value');
    }
    return MapEntry(key, value.toInt());
  });
}

/// 旧 int 调用兼容接口；聚合超出 int64 时明确拒绝，不能截断或回绕。
/// 资产显示应使用 [computeExactBalances] 保留完整聚合金额。
Map<String, int> computeBalances(List<Account> accounts, List<Bill> bills) =>
    _checkedIntBalances(computeExactBalances(accounts, bills));

/// 旧 int 调用兼容接口；超限资产使用 [computeExactNetWorthByCurrency]。
Map<String, int> computeNetWorthByCurrency(
  List<Account> accounts,
  Map<String, int> balances,
) => _checkedIntBalances(
  computeExactNetWorthByCurrency(
    accounts,
    balances.map((key, value) => MapEntry(key, BigInt.from(value))),
  ),
);
