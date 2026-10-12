import 'currency.dart';
import 'money.dart';

const _maxExpressionLength = 256;
final _moneyExpression = RegExp(
  r'^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[+-](?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))*$',
);
final _minExpressionUnits = BigInt.parse('-9223372036854775808');
final _maxExpressionUnits = BigInt.parse('9223372036854775807');

/// Evaluates keypad additions and subtractions exactly in [currency]'s minor
/// units. Each unsigned operand must satisfy [parseMoneyToMinorUnits]; no
/// rounding, exponent notation, grouping, whitespace or unary signs are allowed.
/// A trailing decimal point is accepted only at the end, for decimal currencies.
/// Intermediate totals use BigInt; the final signed result must fit int64.
/// Invalid, incomplete, overlong or out-of-range input returns null, not zero.
int? evaluateMoneyExpression(String input, Currency currency) {
  if (input.isEmpty || input.length > _maxExpressionLength) return null;
  final expression = input.endsWith('.') && currency.minorUnitDigits > 0
      ? input.substring(0, input.length - 1)
      : input;
  final match = _moneyExpression.firstMatch(expression);
  if (match == null || match.end != expression.length) return null;

  var total = BigInt.zero;
  var operandStart = 0;
  var subtract = false;
  for (var index = 0; index <= expression.length; index++) {
    final atEnd = index == expression.length;
    if (!atEnd && expression[index] != '+' && expression[index] != '-') {
      continue;
    }
    final operand = parseMoneyToMinorUnits(
      expression.substring(operandStart, index),
      currency,
    );
    if (operand == null) return null;
    final units = BigInt.from(operand);
    total += subtract ? -units : units;
    if (!atEnd) {
      subtract = expression[index] == '-';
      operandStart = index + 1;
    }
  }
  if (total < _minExpressionUnits || total > _maxExpressionUnits) return null;
  return total.toInt();
}
