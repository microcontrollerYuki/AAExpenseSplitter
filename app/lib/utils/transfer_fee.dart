import '../data/app_database.dart';
import '../data/presets.dart';
import 'currency.dart';

/// Whether the current snapshots can enter the unified transfer editor.
/// The database repeats these checks and compares all fields when saving.
bool canManageTransferFee(
  Bill parent,
  Bill? fee,
  Map<String, Account> accounts,
) {
  final source = accounts[parent.accountId];
  final target = accounts[parent.toAccountId];
  bool known(String code) => Currency.tryFromCode(code)?.code == code;
  bool real(Account? account) =>
      account != null &&
      account.type >= 0 &&
      account.type <= 3 &&
      account.id != kAaCreditAccountId &&
      known(account.currency);
  if (parent.type != 2 ||
      parent.deletedAt != null ||
      parent.feeTransferId != null ||
      parent.feeDeletedWithTransferAt != null ||
      parent.isAa ||
      parent.aaGroupId != null ||
      parent.settlementId != null ||
      !real(source) ||
      !real(target) ||
      source!.id == target!.id ||
      parent.currency != source.currency ||
      parent.amount < 0 ||
      parent.accountAmount != parent.amount) {
    return false;
  }
  final incoming = parent.toAccountAmount;
  if (incoming == null) {
    if (fee != null) return false;
  } else if (source.currency == target.currency
      ? incoming != parent.amount
      : incoming <= 0 || parent.amount <= 0) {
    return false;
  }
  if (fee == null) return true;
  if (fee.id == parent.id ||
      fee.feeTransferId != parent.id ||
      fee.feeDeletedWithTransferAt != null ||
      fee.type != 0 ||
      fee.amount <= 0 ||
      fee.amount != fee.accountAmount ||
      !known(fee.currency) ||
      fee.toAccountId != null ||
      fee.toAccountAmount != null ||
      fee.isAa ||
      fee.aaGroupId != null ||
      fee.settlementId != null) {
    return false;
  }
  return fee.deletedAt != null ||
      (fee.accountId == parent.accountId &&
          fee.currency == parent.currency &&
          fee.dateMs == parent.dateMs);
}
