import '../data/app_database.dart';

/// 计算各账户当前余额（分）：
/// 期初余额 + 收入 - 支出 + 转入 - 转出
Map<String, int> computeBalances(
    List<Account> accounts, List<Bill> bills) {
  final b = {for (final a in accounts) a.id: a.initBalance};
  for (final t in bills) {
    final from = t.accountId;
    if (t.type == 0) {
      if (b.containsKey(from)) b[from] = b[from]! - t.amount;
    } else if (t.type == 1) {
      if (b.containsKey(from)) b[from] = b[from]! + t.amount;
    } else if (t.type == 2) {
      if (b.containsKey(from)) b[from] = b[from]! - t.amount;
      final to = t.toAccountId;
      if (to != null && b.containsKey(to)) b[to] = b[to]! + t.amount;
    }
  }
  return b;
}
