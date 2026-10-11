import '../data/app_database.dart';
import 'currency.dart';
import 'money.dart';

/// Format stored minor units exactly. Unknown historical codes keep their raw
/// units instead of silently adopting CNY precision.
String displayCurrencyAmount(
  BigInt units,
  String code, {
  bool signed = false,
  bool prefix = true,
}) {
  final currency = Currency.tryFromCode(code);
  if (currency == null) {
    final label = code.trim().isEmpty ? '未知币种' : code;
    final sign = signed && units > BigInt.zero ? '+' : '';
    return '$label $sign$units 最小单位';
  }
  final number = formatBigMinorUnits(units, currency, signed: signed);
  if (!prefix) return number;
  final sign = number.startsWith('-') || number.startsWith('+')
      ? number.substring(0, 1)
      : '';
  final magnitude = sign.isEmpty ? number : number.substring(1);
  return '$sign${currency == Currency.cny ? '¥' : currency.code} $magnitude';
}

String displayBillAmount(Bill bill, {bool prefix = false}) {
  final units = BigInt.from(bill.amount);
  return displayCurrencyAmount(
    bill.type == 0 ? -units : units,
    bill.currency,
    signed: bill.type == 1 || bill.type == 3,
    prefix: prefix || bill.currency != 'CNY',
  );
}

({BigInt income, BigInt expense}) summarizeBills(
  Iterable<Bill> bills,
  Iterable<Category> categories,
  String currency,
) {
  final internal = {
    for (final category in categories)
      if (category.kind == 2) category.id,
  };
  var income = BigInt.zero;
  var expense = BigInt.zero;
  for (final bill in bills) {
    if (bill.currency != currency || bill.deletedAt != null) continue;
    if (bill.type == 0) expense += BigInt.from(bill.amount);
    if (bill.type == 1 && !internal.contains(bill.categoryId)) {
      income += BigInt.from(bill.amount);
    }
  }
  return (income: income, expense: expense);
}
