import '../data/app_database.dart';
import '../data/presets.dart';

const noCnyAccountMessage = '暂无可用人民币账户，请先在「账本」中创建';
const staleCnyAccountMessage = '所选账户已变化，请重新选择人民币账户';

/// 在币种记账入口开放前，旧记账与 OCR 界面仍固定使用 CNY。
/// 普通收支保留既有 AA 挂账用途；转账和结算仅接受真实钱包。
List<Account> cnyEntryAccounts(
  Iterable<Account> accounts, {
  bool includeAaCredit = true,
}) => accounts
    .where(
      (account) =>
          account.currency == 'CNY' &&
          ((account.type != 4 && account.id != kAaCreditAccountId) ||
              (includeAaCredit && account.id == kAaCreditAccountId)),
    )
    .toList();

/// 显式选择失效时返回空，必须由用户重选，不能静默换成默认账户。
/// 尚未选择时采用默认账户；默认转入账户排除默认转出账户。
/// 显式选到相同账户交由原有保存校验提示，不在后台静默换选。
String? entryAccountId(
  List<Account> accounts,
  String? selectedId, {
  String? excludeDefaultId,
}) {
  if (selectedId != null) {
    return accounts.any((account) => account.id == selectedId)
        ? selectedId
        : null;
  }
  for (final account in accounts) {
    if (account.id != excludeDefaultId) return account.id;
  }
  return null;
}
