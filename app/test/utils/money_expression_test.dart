import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/utils/money_expression.dart';
import 'package:flutter_test/flutter_test.dart';

const _maxInt64 = 9223372036854775807;
const _minInt64 = -9223372036854775808;

void main() {
  group('evaluateMoneyExpression', () {
    test('纯数字按所选币种解释，零与非法输入区分', () {
      for (final currency in Currency.values) {
        expect(
          evaluateMoneyExpression('12', currency),
          currency == Currency.jpy ? 12 : 1200,
        );
        expect(evaluateMoneyExpression('0', currency), 0);
        expect(evaluateMoneyExpression('', currency), isNull);
      }
    });

    test('两位币种连加连减精确到分，不经过浮点数', () {
      for (final currency in Currency.values.where((c) => c != Currency.jpy)) {
        expect(evaluateMoneyExpression('0.1+0.2', currency), 30);
        expect(evaluateMoneyExpression('12.34+0.01-2.35+1', currency), 1100);
        expect(evaluateMoneyExpression('0.3-0.2-0.1', currency), 0);
      }
    });

    test('日元按整数计算，任何操作数都不允许小数点', () {
      expect(evaluateMoneyExpression('100+50-1', Currency.jpy), 149);
      for (final input in ['1.0', '1+0.0', '.5+1', '1.', '1+2.']) {
        expect(
          evaluateMoneyExpression(input, Currency.jpy),
          isNull,
          reason: input,
        );
      }
    });

    test('每个操作数均严格验证精度，多余的零也不能舍入', () {
      for (final input in ['1.001', '1+0.000', '1.230-0.23', '0.001+0.009']) {
        expect(
          evaluateMoneyExpression(input, Currency.usd),
          isNull,
          reason: input,
        );
      }
    });

    test('允许省略整数部分及前导零', () {
      expect(evaluateMoneyExpression('.5+.05-.01', Currency.eur), 54);
      expect(evaluateMoneyExpression('00012.30+000.01', Currency.hkd), 1231);
    });

    test('尾随小数点仅允许在整个输入末尾', () {
      expect(evaluateMoneyExpression('12.', Currency.cny), 1200);
      expect(evaluateMoneyExpression('1.25+2.', Currency.gbp), 325);
      for (final input in ['.', '1.+2', '1..', '1+.', '1.+2.']) {
        expect(
          evaluateMoneyExpression(input, Currency.cny),
          isNull,
          reason: input,
        );
      }
    });

    test('返回负结果供界面校验，恰好相消仍返回零', () {
      expect(evaluateMoneyExpression('1-2.01', Currency.usd), -101);
      expect(evaluateMoneyExpression('1-2+1', Currency.usd), 0);
      expect(evaluateMoneyExpression('0-1', Currency.jpy), -1);
    });

    test('超过 double 安全整数的大额尾分仍然精确', () {
      expect(
        evaluateMoneyExpression('90071992547409.93+0.02-0.01', Currency.cny),
        9007199254740994,
      );
      expect(
        evaluateMoneyExpression('9007199254740993+2-1', Currency.jpy),
        9007199254740994,
      );
    });

    test('精确接受 int64 最大正数和最小负数结果', () {
      expect(
        evaluateMoneyExpression('92233720368547758.07', Currency.usd),
        _maxInt64,
      );
      expect(
        evaluateMoneyExpression('0-92233720368547758.07-0.01', Currency.usd),
        _minInt64,
      );
      expect(
        evaluateMoneyExpression('9223372036854775807', Currency.jpy),
        _maxInt64,
      );
      expect(
        evaluateMoneyExpression('0-9223372036854775807-1', Currency.jpy),
        _minInt64,
      );
    });

    test('最终结果超出 int64 时拒绝，不截断或回绕', () {
      for (final input in [
        '92233720368547758.07+0.01',
        '0-92233720368547758.07-0.02',
      ]) {
        expect(evaluateMoneyExpression(input, Currency.cny), isNull);
      }
      expect(
        evaluateMoneyExpression('9223372036854775807+1', Currency.jpy),
        isNull,
      );
      expect(
        evaluateMoneyExpression('0-9223372036854775807-2', Currency.jpy),
        isNull,
      );
    });

    test('中间总额可越过 int64，最后回到范围时仍能精确计算', () {
      expect(
        evaluateMoneyExpression('92233720368547758.07+0.01-0.01', Currency.cny),
        _maxInt64,
      );
      expect(
        evaluateMoneyExpression(
          '0-92233720368547758.07-0.02+0.01',
          Currency.cny,
        ),
        _minInt64,
      );
      expect(
        evaluateMoneyExpression('9223372036854775807+1-1', Currency.jpy),
        _maxInt64,
      );
    });

    test('操作数自身超出持久化范围时拒绝，即使最后可相消', () {
      expect(
        evaluateMoneyExpression('92233720368547758.08-0.01', Currency.eur),
        isNull,
      );
      expect(
        evaluateMoneyExpression('9223372036854775808-1', Currency.jpy),
        isNull,
      );
    });

    test('拒绝一元符号、空操作数、未完成连算和其他运算符', () {
      for (final input in [
        '+1',
        '-1',
        '1+',
        '1-',
        '1++2',
        '1--2',
        '1+-2',
        '1-+2',
        '1*2',
        '1/2',
        '(1+2)',
      ]) {
        expect(
          evaluateMoneyExpression(input, Currency.cny),
          isNull,
          reason: input,
        );
      }
    });

    test('拒绝空白、分组、科学计数、币种符号及非 ASCII 数字', () {
      for (final input in [
        ' 1',
        '1 ',
        '1 +2',
        '1\n',
        '1\t+2',
        '1,000+2',
        '1e2+1',
        '0x10',
        'NaN',
        'Infinity',
        r'$1',
        'CNY1',
        '１+２',
        '١+٢',
      ]) {
        expect(
          evaluateMoneyExpression(input, Currency.cny),
          isNull,
          reason: input,
        );
      }
    });

    test('限制原始输入长度为 256 字符，避免过长表达式计算', () {
      final zeros = List.filled(256, '0').join();
      final chain = '${List.filled(252, '0').join()}+0.0';
      expect(zeros.length, 256);
      expect(chain.length, 256);
      expect(evaluateMoneyExpression(zeros, Currency.cny), 0);
      expect(evaluateMoneyExpression(chain, Currency.cny), 0);
      expect(evaluateMoneyExpression('${zeros}0', Currency.cny), isNull);
      expect(evaluateMoneyExpression('$zeros.', Currency.cny), isNull);
      expect(evaluateMoneyExpression('$chain+0', Currency.cny), isNull);
    });
  });
}
