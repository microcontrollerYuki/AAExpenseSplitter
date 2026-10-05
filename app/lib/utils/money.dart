import 'package:intl/intl.dart';

final NumberFormat _moneyFmt = NumberFormat('#,##0.00');

/// '12.34' -> 1234（分）；解析失败返回 0；容忍千分位逗号
int parseMoneyToCents(String s) {
  final t = s.replaceAll(',', '').trim().isEmpty
      ? '0'
      : s.replaceAll(',', '').trim();
  final v = double.tryParse(t) ?? 0;
  return (v * 100).round();
}

/// 1234 -> '1,234.00'；signed=true 时正数前加 '+'
String centsToText(int cents, {bool signed = false}) {
  final prefix = cents < 0 ? '-' : (signed && cents > 0 ? '+' : '');
  return '$prefix${_moneyFmt.format(cents.abs() / 100)}';
}

/// 1234 -> '12.34'（无千分位，用于回填输入框）
String centsToPlain(int cents) => (cents / 100).toStringAsFixed(2);

const kWeekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String monthTitle(DateTime d) => '${d.year}年${d.month}月';

String dayTitle(DateTime d) =>
    '${d.month}月${d.day}日 ${kWeekdayNames[d.weekday - 1]}';
