import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/utils/money.dart';

void main() {
  group('parseMoneyToCents', () {
    test('常规金额', () {
      expect(parseMoneyToCents('12.34'), 1234);
      expect(parseMoneyToCents('0.01'), 1);
      expect(parseMoneyToCents('100'), 10000);
    });

    test('容忍千分位逗号', () {
      expect(parseMoneyToCents('1,234.56'), 123456);
      expect(parseMoneyToCents('12,345,678.90'), 1234567890);
    });

    test('空串与空白返回 0（空串分支）', () {
      expect(parseMoneyToCents(''), 0);
      expect(parseMoneyToCents('   '), 0);
      expect(parseMoneyToCents(' , '), 0);
    });

    test('解析失败返回 0', () {
      expect(parseMoneyToCents('abc'), 0);
      expect(parseMoneyToCents('1.2.3'), 0);
    });

    test('负数与小数四舍五入到分', () {
      expect(parseMoneyToCents('-5'), -500);
      expect(parseMoneyToCents('-0.01'), -1);
      expect(parseMoneyToCents('.5'), 50);
    });
  });

  group('centsToText', () {
    test('千分位格式化', () {
      expect(centsToText(1234), '12.34');
      expect(centsToText(123456789), '1,234,567.89');
      expect(centsToText(0), '0.00');
      expect(centsToText(5), '0.05');
    });

    test('负数带 - 前缀', () {
      expect(centsToText(-1234), '-12.34');
      // 负数时即使 signed=true 也不重复符号
      expect(centsToText(-1234, signed: true), '-12.34');
    });

    test('signed 正数加 +，零不加', () {
      expect(centsToText(1234, signed: true), '+12.34');
      expect(centsToText(0, signed: true), '0.00');
      expect(centsToText(1234, signed: false), '12.34');
    });
  });

  group('centsToPlain', () {
    test('无千分位两位小数', () {
      expect(centsToPlain(1234), '12.34');
      expect(centsToPlain(123456789), '1234567.89');
      expect(centsToPlain(-5), '-0.05');
      expect(centsToPlain(0), '0.00');
    });
  });

  group('日期标题', () {
    test('monthTitle', () {
      expect(monthTitle(DateTime(2026, 10, 5)), '2026年10月');
      expect(monthTitle(DateTime(2026, 1, 1)), '2026年1月');
    });

    test('dayTitle 含中文星期', () {
      // 2026-10-05 是周一
      expect(dayTitle(DateTime(2026, 10, 5)), '10月5日 周一');
      // 2026-10-11 是周日（验证索引末尾不越界）
      expect(dayTitle(DateTime(2026, 10, 11)), '10月11日 周日');
    });

    test('kWeekdayNames 顺序覆盖周一到周日', () {
      expect(kWeekdayNames.length, 7);
      expect(kWeekdayNames.first, '周一');
      expect(kWeekdayNames.last, '周日');
    });
  });
}
