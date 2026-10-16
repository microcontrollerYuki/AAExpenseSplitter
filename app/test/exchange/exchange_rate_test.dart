import 'dart:convert';

import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:flutter_test/flutter_test.dart';

final _fetched = DateTime.utc(2026, 10, 16, 10);

List<Map<String, Object>> _rows() => [
  for (final entry in const {
    'CNY': 7.4993,
    'GBP': 0.8461,
    'HKD': 8.7953,
    'JPY': 177.06,
    'USD': 1.1208,
  }.entries)
    {
      'date': '2026-10-15',
      'base': 'EUR',
      'quote': entry.key,
      'rate': entry.value,
    },
];

String _body() => jsonEncode(_rows());

NetworkRateSnapshot _snapshot({DateTime? quotedAt, DateTime? fetchedAt}) {
  final rates = parseEcbRates(_body(), fetchedAt: _fetched).rates;
  return NetworkRateSnapshot(
    quotedAt: quotedAt ?? DateTime.utc(2026, 10, 15),
    fetchedAt: fetchedAt ?? _fetched,
    rates: rates,
  );
}

void main() {
  group('RateRatio exact arithmetic', () {
    test('positive construction reduces and compares fractions', () {
      final a = RateRatio(BigInt.from(6), BigInt.from(8));
      expect(a.numerator, BigInt.from(3));
      expect(a.denominator, BigInt.from(4));
      expect(a, RateRatio.parse('.75'));
      expect(a.hashCode, RateRatio.parse('0.750').hashCode);
      for (final values in [
        [BigInt.zero, BigInt.one],
        [BigInt.one, BigInt.zero],
        [-BigInt.one, BigInt.one],
        [-BigInt.one, -BigInt.one],
      ]) {
        expect(() => RateRatio(values[0], values[1]), throwsFormatException);
      }
    });

    test('decimals and finite exponents preserve source digits', () {
      final rate = RateRatio.parse('7.49930000000000000000000000000000001');
      expect(
        rate.numerator,
        BigInt.parse('749930000000000000000000000000000001'),
      );
      expect(rate.denominator, BigInt.from(10).pow(35));
      expect(RateRatio.parse('  +7.4993e+0 '), RateRatio.parse('7.4993'));
      expect(RateRatio.parse('125e-2'), RateRatio.parse('1.25'));
      expect(RateRatio.parse('1.'), RateRatio(BigInt.one, BigInt.one));
      expect(RateRatio.parse('1e-18').denominator, BigInt.from(10).pow(18));
      expect(RateRatio.parse('1e18').numerator, BigInt.from(10).pow(18));
    });

    test(
      'inverse products and cross ratios never use rounded display text',
      () {
        final third = RateRatio(BigInt.one, BigInt.from(3));
        expect(third.toDecimalString(fractionDigits: 2), '0.33');
        expect(third * third.inverse, RateRatio(BigInt.one, BigInt.one));
        expect(third / third, RateRatio(BigInt.one, BigInt.one));
        expect(
          third.convertMinorUnits(BigInt.from(300), Currency.cny, Currency.usd),
          BigInt.from(100),
        );
      },
    );

    test('display rounds carry and trims zeros with bounded precision', () {
      expect(RateRatio.parse('1.995').toDecimalString(fractionDigits: 2), '2');
      expect(RateRatio.parse('1.25').toDecimalString(), '1.25');
      expect(RateRatio.parse('1.5').toDecimalString(fractionDigits: 0), '2');
      expect(
        RateRatio.parse('1e-18').toDecimalString(fractionDigits: 18),
        '0.000000000000000001',
      );
      expect(
        () => RateRatio.parse('1').toDecimalString(fractionDigits: -1),
        throwsRangeError,
      );
      expect(
        () => RateRatio.parse('1').toDecimalString(fractionDigits: 37),
        throwsRangeError,
      );
    });

    test('JPY conversion scales minor digits in both directions', () {
      final rate = RateRatio.parse('177.06');
      expect(
        rate.convertMinorUnits(BigInt.from(100), Currency.eur, Currency.jpy),
        BigInt.from(177),
      );
      expect(
        rate.inverse.convertMinorUnits(
          BigInt.from(17706),
          Currency.jpy,
          Currency.eur,
        ),
        BigInt.from(10000),
      );
    });

    test('rounding happens once and half values round away from zero', () {
      final half = RateRatio.parse('.5');
      for (final amount in [BigInt.one, -BigInt.one]) {
        expect(
          half.convertMinorUnits(amount, Currency.cny, Currency.usd),
          amount,
        );
      }
      expect(
        RateRatio.parse('149.5')
            .convertMinorUnits(BigInt.one, Currency.eur, Currency.jpy),
        BigInt.one,
      );
      expect(
        RateRatio.parse('150')
            .convertMinorUnits(-BigInt.one, Currency.eur, Currency.jpy),
        BigInt.from(-2),
      );
      expect(
        half.convertMinorUnits(BigInt.zero, Currency.cny, Currency.usd),
        BigInt.zero,
      );
    });

    test('arbitrarily large integer amounts remain exact', () {
      final amount = BigInt.parse('999999999999999999999999999999999999999999');
      final rate = RateRatio.parse('1.25');
      expect(
        rate.convertMinorUnits(
          amount * BigInt.from(4),
          Currency.cny,
          Currency.usd,
        ),
        amount * BigInt.from(5),
      );
      expect(
        rate.convertMinorUnits(
          -amount * BigInt.from(4),
          Currency.cny,
          Currency.usd,
        ),
        -amount * BigInt.from(5),
      );
    });

    for (final raw in [
      '',
      '0',
      '-1',
      'NaN',
      'Infinity',
      '1/2',
      '1,23',
      '1e19',
      '1e-19',
      '1.000000000000000001e18',
      '.0000000000000000009',
      '1234567890123456789012345678901234567',
      '${' ' * 64}1',
    ]) {
      test('rejects malformed or unbounded rate ${jsonEncode(raw)}', () {
        expect(() => RateRatio.parse(raw), throwsFormatException);
      });
    }

    test(
      'fraction JSON round trip enforces shape digits and numerical bounds',
      () {
        final rate = RateRatio.parse('7.4993');
        expect(RateRatio.fromJson(rate.toJson()), rate);
        expect(RateRatio.fromJson({'n': '2', 'd': '4'}), RateRatio.parse('.5'));
        for (final invalid in [
          null,
          [],
          {'n': 1, 'd': '1'},
          {'n': '1', 'd': '0'},
          {'n': '-1', 'd': '1'},
          {'n': '01', 'd': '1'},
          {'n': '1\n', 'd': '1'},
          {'n': '1.2', 'd': '1'},
          {'n': '1', 'd': '1', 'extra': true},
          {'n': '1'},
          {'n': '1' * 55, 'd': '1' * 55},
          {'n': '1000000000000000001', 'd': '1'},
          {'n': '1', 'd': '1000000000000000001'},
        ]) {
          expect(() => RateRatio.fromJson(invalid), throwsFormatException);
        }
      },
    );
  });

  group('ECB response exact parser', () {
    test('official row shape creates complete immutable EUR snapshot', () {
      final snapshot = parseEcbRates(_body(), fetchedAt: _fetched);
      expect(snapshot.rates.length, 6);
      expect(snapshot.quotedAt, DateTime.utc(2026, 10, 15));
      expect(snapshot.fetchedAt, _fetched);
      expect(snapshot.source, 'Frankfurter / ECB');
      expect(snapshot.rates[Currency.eur], RateRatio.parse('1'));
      expect(snapshot.rates[Currency.cny], RateRatio.parse('7.4993'));
      expect(snapshot.ratio(Currency.cny, Currency.cny), RateRatio.parse('1'));
      expect(
        snapshot.ratio(Currency.usd, Currency.cny),
        RateRatio(BigInt.from(74993), BigInt.from(11208)),
      );
      expect(
        () => snapshot.rates[Currency.cny] = RateRatio.parse('1'),
        throwsUnsupportedError,
      );
    });

    test('numeric lexeme beyond double precision survives unmodified', () {
      const exact = '7.49930000000000000000000000000000001';
      final body = _body().replaceFirst('7.4993', exact);
      final snapshot = parseEcbRates(body, fetchedAt: _fetched);
      expect(snapshot.rates[Currency.cny], RateRatio.parse(exact));
      expect(snapshot.rates[Currency.cny], isNot(RateRatio.parse('7.4993')));
    });

    test('escaped strings are decoded and numeric exponent remains exact', () {
      final body = _body()
          .replaceFirst('"quote"', r'"qu\u006fte"')
          .replaceFirst('"EUR"', r'"E\u0055R"')
          .replaceFirst('7.4993', '74993e-4');
      expect(
        parseEcbRates(body, fetchedAt: _fetched).rates[Currency.cny],
        RateRatio.parse('7.4993'),
      );
    });

    test('duplicate keys including escaped aliases are rejected', () {
      for (final replacement in [
        '"rate":1,"rate":7.4993',
        r'"r\u0061te":1,"rate":7.4993',
      ]) {
        expect(
          () => parseEcbRates(
            _body().replaceFirst('"rate":7.4993', replacement),
            fetchedAt: _fetched,
          ),
          throwsFormatException,
        );
      }
    });

    test('missing duplicate unsupported and EUR quotes are rejected', () {
      final missing = _rows()..removeLast();
      final duplicate = _rows()..last['quote'] = 'CNY';
      final unsupported = _rows()..last['quote'] = 'AUD';
      final eur = _rows()..last['quote'] = 'EUR';
      final lower = _rows()..last['quote'] = 'usd';
      final extra = _rows()..add({..._rows().last});
      for (final rows in [missing, duplicate, unsupported, eur, lower, extra]) {
        expect(
          () => parseEcbRates(jsonEncode(rows), fetchedAt: _fetched),
          throwsFormatException,
        );
      }
    });

    test('schema and rate JSON types are strict', () {
      final stringRate = _rows()..first['rate'] = '7.4993';
      final extra = _rows()..first['extra'] = true;
      final missing = _rows()..first.remove('date');
      final wrongBase = _rows()..last['base'] = 'USD';
      final boolRate = _rows()..first['rate'] = true;
      for (final rows in [stringRate, extra, missing, wrongBase, boolRate]) {
        expect(
          () => parseEcbRates(jsonEncode(rows), fetchedAt: _fetched),
          throwsFormatException,
        );
      }
    });

    test('mixed invalid impossible and future dates are rejected', () {
      for (final date in [
        '2026-10-14',
        '2026-02-30',
        '2026-13-01',
        '0000-01-01',
        '2026-1-15',
        '2026-10-17',
        '2026-10-15T00:00:00Z',
        '2026-10-15\n',
      ]) {
        final rows = _rows()..first['date'] = date;
        expect(
          () => parseEcbRates(jsonEncode(rows), fetchedAt: _fetched),
          throwsFormatException,
        );
      }
    });

    test('future date compares UTC day rather than local time', () {
      final fetched = DateTime.parse('2026-10-15T01:00:00+08:00');
      expect(
        () => parseEcbRates(_body(), fetchedAt: fetched),
        throwsFormatException,
      );
    });

    test('invalid JSON grammar and trailing data cannot be accepted', () {
      for (final body in [
        '',
        '{}',
        '${_body()} null',
        _body().replaceFirst('7.4993', '07.4993'),
        _body().replaceFirst('7.4993', '+7.4993'),
        _body().replaceFirst('7.4993', '7.'),
        _body().replaceFirst('7.4993', 'NaN'),
        _body().replaceFirst('7.4993', '-1'),
        _body().replaceFirst('7.4993', '0'),
        _body().replaceFirst('7.4993', '1e99'),
        _body().replaceFirst('"EUR"', r'"E\qR"'),
        _body().replaceFirst('"EUR"', r'"E\u00GG"'),
        _body().replaceFirst('"EUR"', '"E\nR"'),
        '${_body().substring(0, _body().length - 1)},]',
      ]) {
        expect(
          () => parseEcbRates(body, fetchedAt: _fetched),
          throwsFormatException,
        );
      }
    });

    test('response size depth and node resources are bounded', () {
      for (final body in [
        '${' ' * 32768}${_body()}',
        '["${'汉' * 11000}"]',
        '${'[' * 10}0${']' * 10}',
        '[${List.filled(130, '0').join(',')}]',
      ]) {
        expect(
          () => parseEcbRates(body, fetchedAt: _fetched),
          throwsFormatException,
        );
      }
    });
  });

  group('network rate cache snapshots', () {
    test('raw cache validation rejects duplicate keys before jsonDecode', () {
      for (final raw in [
        '{"version":1,"version":1,"network":null,"manual":[]}',
        r'{"version":1,"manual":[],"m\u0061nual":[]}',
        '{"manual":[{"base":"USD","base":"CNY"}]}',
        '${' ' * 32768}{}',
        '${'[' * 10}0${']' * 10}',
      ]) {
        expect(() => validateRateJson(raw), throwsFormatException);
      }
      final currencies = Currency.values;
      final fullCache = jsonEncode({
        'version': 1,
        'network': _snapshot().toJson(),
        'manual': [
          for (var a = 0; a < currencies.length; a++)
            for (var b = a + 1; b < currencies.length; b++)
              {
                'base': currencies[a].code,
                'quote': currencies[b].code,
                'ratio': RateRatio.parse('1.25').toJson(),
                'updatedAtMs': _fetched.millisecondsSinceEpoch,
              },
        ],
      });
      expect(() => validateRateJson(fullCache), returnsNormally);
    });

    test('cache round trip retains all exact rates source and timestamps', () {
      final snapshot = _snapshot();
      final decoded = NetworkRateSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      expect(decoded.toJson(), snapshot.toJson());
      expect(decoded.source, rateSource);
      expect(decoded.fetchedAt.isUtc, isTrue);
      expect(decoded.quotedAt.isUtc, isTrue);
    });

    test(
      'constructor copies input map instead of exposing external mutation',
      () {
        final rates = Map<Currency, RateRatio>.from(_snapshot().rates);
        final snapshot = NetworkRateSnapshot(
          quotedAt: DateTime.utc(2026, 10, 15),
          fetchedAt: _fetched,
          rates: rates,
        );
        rates.clear();
        expect(snapshot.rates.length, 6);
      },
    );

    test('cache validates shape and complete currencies', () {
      final good = _snapshot().toJson();
      final rates = Map<String, Object>.from(good['rates']! as Map);
      for (final invalid in [
        null,
        [],
        {...good, 'source': 'Other'},
        {...good}..remove('quotedAt'),
        {...good, 'source': 'unknown'},
        {...good, 'base': 'USD'},
        {
          ...good,
          'rates': {...rates}..remove('USD'),
        },
        {
          ...good,
          'rates': {...rates, 'AUD': RateRatio.parse('1').toJson()},
        },
        {
          ...good,
          'rates': {...rates, 'EUR': RateRatio.parse('2').toJson()},
        },
        {
          ...good,
          'rates': {...rates, 'USD': 1.1208},
        },
        {...good, 'quotedAt': '2026-02-30'},
        {...good, 'quotedAt': '2026-10-15T00:00:00Z'},
        {...good, 'fetchedAtMs': '1'},
        {...good, 'fetchedAtMs': 1.5},
        {...good, 'fetchedAtMs': -1},
        {...good, 'fetchedAtMs': 8640000000000001},
      ]) {
        expect(
          () => NetworkRateSnapshot.fromJson(invalid),
          throwsFormatException,
        );
      }
    });

    test('constructor rejects non-UTC and non-midnight quotation dates', () {
      final rates = _snapshot().rates;
      for (final date in [
        DateTime(2026, 10, 15),
        DateTime.utc(2026, 10, 15, 1),
        DateTime.utc(2026, 10, 15, 0, 0, 0, 0, 1),
      ]) {
        expect(
          () => NetworkRateSnapshot(
            quotedAt: date,
            fetchedAt: _fetched,
            rates: rates,
          ),
          throwsFormatException,
        );
      }
    });

    test('fetch age expires at exactly 24 hours', () {
      final snapshot = _snapshot();
      expect(
        snapshot.isStaleAt(
          _fetched.add(const Duration(hours: 23, minutes: 59)),
        ),
        isFalse,
      );
      expect(
        snapshot.isStaleAt(_fetched.add(const Duration(hours: 24))),
        isTrue,
      );
    });

    test('quotation expires on seventh UTC day even after a recent fetch', () {
      expect(
        _snapshot(quotedAt: DateTime.utc(2026, 10, 10)).isStaleAt(_fetched),
        isFalse,
      );
      expect(
        _snapshot(quotedAt: DateTime.utc(2026, 10, 9)).isStaleAt(_fetched),
        isTrue,
      );
    });

    test(
      'future fetch tolerance is five minutes and future quotes stay stale',
      () {
        expect(
          _snapshot(fetchedAt: _fetched.add(const Duration(minutes: 5)))
              .isStaleAt(_fetched),
          isFalse,
        );
        expect(
          _snapshot(
            fetchedAt: _fetched.add(
              const Duration(minutes: 5, milliseconds: 1),
            ),
          ).isStaleAt(_fetched),
          isTrue,
        );
        expect(
          _snapshot(quotedAt: DateTime.utc(2026, 10, 17)).isStaleAt(_fetched),
          isTrue,
        );
      },
    );
  });
}
