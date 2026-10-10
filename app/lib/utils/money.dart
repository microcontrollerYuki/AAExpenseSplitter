import 'currency.dart';

// The mobile app and SQLite store signed 64-bit minor units. Check with BigInt
// before converting to int, so overflow cannot silently wrap or clamp.
final _minMinorUnits = BigInt.parse('-9223372036854775808');
final _maxMinorUnits = BigInt.parse('9223372036854775807');
const _maxMoneyInputLength = 256;
final _strictMoney = RegExp(
  r'^([+-]?)(?:([0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.([0-9]+))?|\.([0-9]+))$',
);
final _legacyMoney = RegExp(
  r'^([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?$',
);

int? _checkedMinorUnits(BigInt value) =>
    value < _minMinorUnits || value > _maxMinorUnits ? null : value.toInt();

/// Exact input for new currency-aware callers. Invalid input is distinct from
/// zero. Accepts outer whitespace, a leading sign, decimal dots and correctly
/// grouped commas. Rejects excess precision (even zeroes), exponents, symbols,
/// incomplete input, overlong input and values outside signed int64.
/// JPY rejects all decimal points, including "1.0". No rounding or conversion.
int? parseMoneyToMinorUnits(String input, Currency currency) {
  if (input.length > _maxMoneyInputLength) return null;
  final match = _strictMoney.firstMatch(input.trim());
  if (match == null) return null;
  final fraction = match.group(3) ?? match.group(4) ?? '';
  if (fraction.length > currency.minorUnitDigits) return null;
  final whole = (match.group(2) ?? '0').replaceAll(',', '');
  final digits = '$whole${fraction.padRight(currency.minorUnitDigits, '0')}';
  final magnitude = BigInt.parse(digits);
  return _checkedMinorUnits(match.group(1) == '-' ? -magnitude : magnitude);
}

/// Exact numeric text, without a currency symbol/code. Precision comes from the
/// currency; [grouping] adds commas and [signed] adds '+' only to positive values.
/// Splitting the int's text also handles the minimum negative int without abs().
String formatMinorUnits(
  int units,
  Currency currency, {
  bool grouping = true,
  bool signed = false,
}) {
  final negative = units < 0;
  final prefix = negative ? '-' : (signed && units > 0 ? '+' : '');
  final raw = units.toString();
  final digits = (negative ? raw.substring(1) : raw).padLeft(
    currency.minorUnitDigits + 1,
    '0',
  );
  final split = digits.length - currency.minorUnitDigits;
  final whole = digits.substring(0, split);
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (grouping && i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  final fraction = currency.minorUnitDigits == 0
      ? ''
      : '.${digits.substring(split)}';
  return '$prefix$grouped$fraction';
}

/// Existing CNY input compatibility: removes all commas, accepts .5 / 1. and
/// exponent notation, and rounds excess decimals half away from zero. Invalid,
/// non-finite, overlong or out-of-range input returns 0. Exponents are bounded to
/// [-128, 128]. New currency-aware forms should use parseMoneyToMinorUnits.
int parseMoneyToCents(String s) {
  if (s.length > _maxMoneyInputLength) return 0;
  final match = _legacyMoney.firstMatch(s.replaceAll(',', '').trim());
  if (match == null) return 0;
  final exponent = int.tryParse(match.group(5) ?? '0');
  if (exponent == null || exponent < -128 || exponent > 128) return 0;
  final whole = match.group(2) ?? '0';
  final fraction = match.group(3) ?? match.group(4) ?? '';
  final coefficient = BigInt.parse('$whole$fraction');
  final shift = 2 + exponent - fraction.length;
  BigInt magnitude;
  if (shift >= 0) {
    magnitude = coefficient * BigInt.from(10).pow(shift);
  } else {
    final divisor = BigInt.from(10).pow(-shift);
    magnitude = coefficient ~/ divisor;
    if (coefficient.remainder(divisor) * BigInt.two >= divisor) {
      magnitude += BigInt.one;
    }
  }
  return _checkedMinorUnits(match.group(1) == '-' ? -magnitude : magnitude) ??
      0;
}

/// 1234 -> '12.34'；signed=true 时正数前加 '+'。
String centsToText(int cents, {bool signed = false}) =>
    formatMinorUnits(cents, Currency.cny, signed: signed);

/// 1234 -> '12.34'（无千分位，用于回填输入框）
String centsToPlain(int cents) =>
    formatMinorUnits(cents, Currency.cny, grouping: false);

const kWeekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String monthTitle(DateTime d) => '${d.year}年${d.month}月';

String dayTitle(DateTime d) =>
    '${d.month}月${d.day}日 ${kWeekdayNames[d.weekday - 1]}';
