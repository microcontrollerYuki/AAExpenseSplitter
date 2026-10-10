import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/utils/money.dart';
import 'package:flutter_test/flutter_test.dart';

const _maxInt64 = 9223372036854775807;
const _minInt64 = -9223372036854775808;

void main() {
  group('Currency', () {
    test('六种币种具有独立代码、中文名和最小单位精度', () {
      final expected = <Currency, (String, String, int)>{
        Currency.cny: ('CNY', '人民币', 2),
        Currency.usd: ('USD', '美元', 2),
        Currency.hkd: ('HKD', '港币', 2),
        Currency.eur: ('EUR', '欧元', 2),
        Currency.jpy: ('JPY', '日元', 0),
        Currency.gbp: ('GBP', '英镑', 2),
      };
      expect(Currency.values.toSet(), expected.keys.toSet());
      for (final entry in expected.entries) {
        expect(entry.key.code, entry.value.$1);
        expect(entry.key.displayName, entry.value.$2);
        expect(entry.key.minorUnitDigits, entry.value.$3);
      }
    });

    test('按代码查询容忍大小写和外侧空白，拒绝符号与未知代码', () {
      for (final currency in Currency.values) {
        expect(
          Currency.tryFromCode(' ${currency.code.toLowerCase()}\t'),
          currency,
        );
      }
      for (final input in ['', 'RMB', 'CN', '人民币', '¥', r'$', 'US D', 'USD1']) {
        expect(Currency.tryFromCode(input), isNull, reason: input);
      }
    });
  });

  group('parseMoneyToMinorUnits', () {
    test('按六种币种精度解析金额，日元保持整数单位', () {
      for (final currency in Currency.values.where((c) => c != Currency.jpy)) {
        expect(parseMoneyToMinorUnits('12.34', currency), 1234);
        expect(parseMoneyToMinorUnits('12', currency), 1200);
        expect(parseMoneyToMinorUnits('0.01', currency), 1);
        expect(parseMoneyToMinorUnits('-.5', currency), -50);
      }
      expect(parseMoneyToMinorUnits('12', Currency.jpy), 12);
      expect(parseMoneyToMinorUnits('-1', Currency.jpy), -1);
    });

    test('接受规范千分位、外侧空白、正负号和省略整数部分', () {
      final samples = <String, int>{
        ' \t+1,234,567.89\n': 123456789,
        '-1,234.5': -123450,
        '+.5': 50,
        '.05': 5,
        '00012.30': 1230,
        '-0.00': 0,
        '1,000': 100000,
      };
      for (final sample in samples.entries) {
        expect(
          parseMoneyToMinorUnits(sample.key, Currency.cny),
          sample.value,
          reason: sample.key,
        );
      }
      expect(parseMoneyToMinorUnits('+1,234', Currency.jpy), 1234);
    });

    test('拒绝非法千分组、内部空白、非十进制、符号和缺失数字', () {
      final invalid = [
        '',
        ' ',
        '.',
        '1.',
        '+',
        '-',
        '++1',
        '1-',
        '+ 1',
        ',123',
        '123,',
        '1,23',
        '1234,567',
        '1,,234',
        '1,2345',
        '1,234.5,6',
        '1 000',
        '1\t.00',
        '1\n2',
        '1e2',
        '0x10',
        'NaN',
        'Infinity',
        r'$1',
        '¥1',
        '１.２０',
        '١.٢',
      ];
      for (final input in invalid) {
        expect(
          parseMoneyToMinorUnits(input, Currency.usd),
          isNull,
          reason: input,
        );
      }
    });

    test('严格拒绝多余小数位，日元连零小数也不接受', () {
      for (final currency in Currency.values.where((c) => c != Currency.jpy)) {
        for (final input in ['1.230', '0.000', '1.005', '-.001']) {
          expect(
            parseMoneyToMinorUnits(input, currency),
            isNull,
            reason: input,
          );
        }
      }
      for (final input in ['1.0', '1.00', '.5', '-.5', '0.0']) {
        expect(
          parseMoneyToMinorUnits(input, Currency.jpy),
          isNull,
          reason: input,
        );
      }
    });

    test('输入长度有界，256 字符合法输入可解析而 257 字符拒绝', () {
      final atLimit = List.filled(256, '0').join();
      expect(parseMoneyToMinorUnits(atLimit, Currency.cny), 0);
      expect(parseMoneyToMinorUnits('${atLimit}0', Currency.cny), isNull);
    });

    test('两位币种准确解析 int64 边界和超过 double 安全整数的值', () {
      expect(
        parseMoneyToMinorUnits('92,233,720,368,547,758.07', Currency.eur),
        _maxInt64,
      );
      expect(
        parseMoneyToMinorUnits('-92,233,720,368,547,758.08', Currency.eur),
        _minInt64,
      );
      expect(
        parseMoneyToMinorUnits('92233720368547758.08', Currency.eur),
        isNull,
      );
      expect(
        parseMoneyToMinorUnits('-92233720368547758.09', Currency.eur),
        isNull,
      );
      expect(
        parseMoneyToMinorUnits('90071992547409.93', Currency.gbp),
        9007199254740993,
      );
    });

    test('日元以最小单位验证 int64 范围而非乘以一百', () {
      expect(
        parseMoneyToMinorUnits('9,223,372,036,854,775,807', Currency.jpy),
        _maxInt64,
      );
      expect(
        parseMoneyToMinorUnits('-9223372036854775808', Currency.jpy),
        _minInt64,
      );
      expect(
        parseMoneyToMinorUnits('9223372036854775808', Currency.jpy),
        isNull,
      );
      expect(
        parseMoneyToMinorUnits('-9223372036854775809', Currency.jpy),
        isNull,
      );
    });
  });

  group('formatMinorUnits', () {
    test('六种币种分别按精度补零，数字文本不混入代码或符号', () {
      for (final currency in Currency.values.where((c) => c != Currency.jpy)) {
        expect(formatMinorUnits(123456, currency), '1,234.56');
        expect(formatMinorUnits(5, currency), '0.05');
        expect(formatMinorUnits(0, currency), '0.00');
        expect(formatMinorUnits(123456, currency, grouping: false), '1234.56');
      }
      expect(formatMinorUnits(123456, Currency.jpy), '123,456');
      expect(formatMinorUnits(5, Currency.jpy), '5');
      expect(formatMinorUnits(0, Currency.jpy), '0');
      expect(formatMinorUnits(123456, Currency.jpy, grouping: false), '123456');
    });

    test('signed 只为正数增加加号，负数和零符号稳定', () {
      expect(formatMinorUnits(1234, Currency.cny, signed: true), '+12.34');
      expect(formatMinorUnits(-1234, Currency.cny, signed: true), '-12.34');
      expect(formatMinorUnits(0, Currency.cny, signed: true), '0.00');
      expect(formatMinorUnits(1234, Currency.jpy, signed: true), '+1,234');
      expect(formatMinorUnits(-1234, Currency.jpy, grouping: false), '-1234');
      expect(formatMinorUnits(0, Currency.jpy, signed: true), '0');
    });

    test('int64 最小负数、最大正数和大额尾分不经过浮点数', () {
      expect(
        formatMinorUnits(_minInt64, Currency.cny),
        '-92,233,720,368,547,758.08',
      );
      expect(
        formatMinorUnits(_maxInt64, Currency.usd),
        '92,233,720,368,547,758.07',
      );
      expect(
        formatMinorUnits(_minInt64, Currency.jpy),
        '-9,223,372,036,854,775,808',
      );
      expect(
        formatMinorUnits(_maxInt64, Currency.jpy),
        '9,223,372,036,854,775,807',
      );
      expect(
        formatMinorUnits(9007199254740993, Currency.hkd),
        '90,071,992,547,409.93',
      );
    });

    test('多样整数在每种币种及分组和符号组合下均完整往返', () {
      const samples = [
        _minInt64,
        -9007199254740993,
        -123456789,
        -101,
        -100,
        -99,
        -1,
        0,
        1,
        9,
        10,
        99,
        100,
        101,
        1000,
        123456789,
        9007199254740993,
        _maxInt64,
      ];
      for (final currency in Currency.values) {
        for (final amount in samples) {
          for (final grouping in [false, true]) {
            for (final signed in [false, true]) {
              final text = formatMinorUnits(
                amount,
                currency,
                grouping: grouping,
                signed: signed,
              );
              expect(
                parseMoneyToMinorUnits(text, currency),
                amount,
                reason: '${currency.code}: $text',
              );
            }
          }
        }
      }
    });

    test('旧人民币格式化入口保留签名并修复大额精度', () {
      expect(centsToText(123456, signed: true), '+1,234.56');
      expect(centsToPlain(5), '0.05');
      expect(centsToPlain(-5), '-0.05');
      expect(centsToText(9007199254740993), '90,071,992,547,409.93');
      expect(centsToPlain(9007199254740993), '90071992547409.93');
      expect(centsToText(_minInt64), '-92,233,720,368,547,758.08');
      expect(centsToPlain(_minInt64), '-92233720368547758.08');
    });
  });

  group('parseMoneyToCents 兼容入口', () {
    test('保留任意逗号、省略整数或尾随小数点和指数输入', () {
      final samples = <String, int>{
        '  +1,2,3.45 ': 12345,
        ',1,,2,': 1200,
        '.5': 50,
        '1.': 100,
        '+1': 100,
        '1e2': 10000,
        '123e-2': 123,
        '-5e-3': -1,
        '': 0,
        ' , ': 0,
      };
      for (final sample in samples.entries) {
        expect(parseMoneyToCents(sample.key), sample.value, reason: sample.key);
      }
    });

    test('十进制精确舍入到分，半分按远离零处理', () {
      final samples = <String, int>{
        '1.004': 100,
        '1.005': 101,
        '1.006': 101,
        '-1.004': -100,
        '-1.005': -101,
        '-1.006': -101,
        '0.0049': 0,
        '0.005': 1,
        '-0.005': -1,
        '9.995': 1000,
        '-9.995': -1000,
      };
      for (final sample in samples.entries) {
        expect(parseMoneyToCents(sample.key), sample.value, reason: sample.key);
      }
    });

    test('大数精确到分，舍入后超出 int64、非有限值和过长输入返回零', () {
      expect(parseMoneyToCents('90071992547409.93'), 9007199254740993);
      expect(parseMoneyToCents('92233720368547758.074'), _maxInt64);
      expect(parseMoneyToCents('-92233720368547758.084'), _minInt64);
      for (final input in [
        '92233720368547758.075',
        '-92233720368547758.085',
        'NaN',
        'Infinity',
        '-Infinity',
        '1e999',
        'abc',
        '1.2.3',
        List.filled(257, '0').join(),
      ]) {
        expect(parseMoneyToCents(input), 0, reason: input);
      }
      expect(parseMoneyToCents(List.filled(256, '0').join()), 0);
    });

    test('指数上下界在缩放前验证，合法边界仍能得到非零结果', () {
      final negativeBoundary = '1${List.filled(126, '0').join()}e-128';
      final negativeOutside = '1${List.filled(127, '0').join()}e-129';
      final positiveBoundary = '0.${List.filled(127, '0').join()}1e128';
      final positiveOutside = '0.${List.filled(128, '0').join()}1e129';
      expect(parseMoneyToCents(negativeBoundary), 1);
      expect(parseMoneyToCents(negativeOutside), 0);
      expect(parseMoneyToCents(positiveBoundary), 100);
      expect(parseMoneyToCents(positiveOutside), 0);
    });
  });
}
