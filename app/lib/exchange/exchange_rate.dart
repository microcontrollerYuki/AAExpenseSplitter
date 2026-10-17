import 'dart:convert';

import '../utils/currency.dart';

const rateSource = 'Frankfurter / ECB';

final _ten = BigInt.from(10);
final _rateLimit = _ten.pow(18);

/// Quote-currency major units for one base-currency major unit.
/// All arithmetic stays rational until the final minor-unit rounding.
class RateRatio {
  factory RateRatio(BigInt numerator, BigInt denominator) {
    if (numerator <= BigInt.zero || denominator <= BigInt.zero) {
      throw const FormatException('汇率必须大于零');
    }
    final gcd = numerator.gcd(denominator);
    return RateRatio._(numerator ~/ gcd, denominator ~/ gcd);
  }

  const RateRatio._(this.numerator, this.denominator);

  factory RateRatio.parse(String raw) {
    if (raw.length > 64) throw const FormatException('汇率过长');
    final match = RegExp(
      r'^\+?(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$',
    ).firstMatch(raw.trim());
    if (match == null) throw const FormatException('汇率格式无效');
    final integer = match.group(1) ?? '';
    final fraction = match.group(2) ?? match.group(3) ?? '';
    final coefficient = '$integer$fraction';
    if (coefficient.length > 36) {
      throw const FormatException('汇率有效数字过长');
    }
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null || exponent.abs() > 18) {
      throw const FormatException('汇率指数超出范围');
    }
    final power = exponent - fraction.length;
    final n = BigInt.parse(coefficient);
    final rate = power >= 0
        ? RateRatio(n * _ten.pow(power), BigInt.one)
        : RateRatio(n, _ten.pow(-power));
    _checkRateBounds(rate);
    return rate;
  }

  factory RateRatio.fromJson(Object? json) {
    final map = _objectWithKeys(json, const {'n', 'd'});
    BigInt read(String key) {
      final value = map[key];
      if (value is! String ||
          value.length > 54 ||
          RegExp(r'[1-9]\d*').matchAsPrefix(value)?.end != value.length) {
        throw const FormatException('缓存汇率分数无效');
      }
      return BigInt.parse(value);
    }

    final result = RateRatio(read('n'), read('d'));
    _checkRateBounds(result);
    return result;
  }

  final BigInt numerator;
  final BigInt denominator;

  RateRatio get inverse => RateRatio(denominator, numerator);

  RateRatio operator *(RateRatio other) =>
      RateRatio(numerator * other.numerator, denominator * other.denominator);

  RateRatio operator /(RateRatio other) => this * other.inverse;

  /// Display only. This rounded representation is never used for conversion.
  String toDecimalString({int fractionDigits = 10}) {
    if (fractionDigits < 0 || fractionDigits > 36) {
      throw RangeError.range(fractionDigits, 0, 36, 'fractionDigits');
    }
    final scale = _ten.pow(fractionDigits);
    final rounded = _roundHalfAway(numerator * scale, denominator);
    if (fractionDigits == 0) return rounded.toString();
    final whole = rounded ~/ scale;
    final fraction = (rounded % scale).toString().padLeft(fractionDigits, '0');
    final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.isEmpty ? whole.toString() : '$whole.$trimmed';
  }

  BigInt convertMinorUnits(BigInt amount, Currency base, Currency quote) {
    return _roundHalfAway(
      amount * numerator * _ten.pow(quote.minorUnitDigits),
      denominator * _ten.pow(base.minorUnitDigits),
    );
  }

  Map<String, String> toJson() => {
    'n': numerator.toString(),
    'd': denominator.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is RateRatio &&
      numerator == other.numerator &&
      denominator == other.denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);
}

void _checkRateBounds(RateRatio ratio) {
  if (ratio.numerator > ratio.denominator * _rateLimit ||
      ratio.numerator * _rateLimit < ratio.denominator) {
    throw const FormatException('汇率超出范围');
  }
}

BigInt _roundHalfAway(BigInt numerator, BigInt denominator) {
  final absolute = numerator.abs();
  final whole = absolute ~/ denominator;
  final rounded = absolute.remainder(denominator) * BigInt.two >= denominator
      ? whole + BigInt.one
      : whole;
  return numerator.isNegative ? -rounded : rounded;
}

class NetworkRateSnapshot {
  NetworkRateSnapshot({
    required DateTime quotedAt,
    required DateTime fetchedAt,
    required Map<Currency, RateRatio> rates,
  }) : quotedAt = _requireUtcDate(quotedAt),
       fetchedAt = fetchedAt.toUtc(),
       rates = Map.unmodifiable(rates) {
    if (rates.length != Currency.values.length ||
        Currency.values.any((currency) => !rates.containsKey(currency)) ||
        rates[Currency.eur] != RateRatio(BigInt.one, BigInt.one)) {
      throw const FormatException('汇率快照必须包含完整六币种且 EUR 等于 1');
    }
    for (final rate in rates.values) {
      _checkRateBounds(rate);
    }
    if (this.fetchedAt.millisecondsSinceEpoch < 0) {
      throw const FormatException('获取时间无效');
    }
  }

  factory NetworkRateSnapshot.fromJson(Object? json) {
    final map = _objectWithKeys(json, const {
      'source',
      'base',
      'quotedAt',
      'fetchedAtMs',
      'rates',
    });
    if (map['source'] != rateSource || map['base'] != 'EUR') {
      throw const FormatException('缓存汇率来源或基准无效');
    }
    final quoted = _parseDate(map['quotedAt']);
    final fetched = map['fetchedAtMs'];
    if (fetched is! int || fetched < 0 || fetched > 8640000000000000) {
      throw const FormatException('缓存获取时间无效');
    }
    final rateMap = _objectWithKeys(
      map['rates'],
      Currency.values.map((currency) => currency.code).toSet(),
    );
    return NetworkRateSnapshot(
      quotedAt: quoted,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetched, isUtc: true),
      rates: {
        for (final currency in Currency.values)
          currency: RateRatio.fromJson(rateMap[currency.code]),
      },
    );
  }

  final DateTime quotedAt;
  final DateTime fetchedAt;
  final Map<Currency, RateRatio> rates;
  String get source => rateSource;

  RateRatio ratio(Currency base, Currency quote) =>
      rates[quote]! / rates[base]!;

  bool isStaleAt(DateTime now) {
    final utcNow = now.toUtc();
    final today = DateTime.utc(utcNow.year, utcNow.month, utcNow.day);
    return utcNow.difference(fetchedAt) >= const Duration(hours: 24) ||
        fetchedAt.difference(utcNow) > const Duration(minutes: 5) ||
        today.difference(quotedAt) >= const Duration(days: 7) ||
        quotedAt.isAfter(today);
  }

  Map<String, Object> toJson() => {
    'source': rateSource,
    'base': 'EUR',
    'quotedAt': _dateText(quotedAt),
    'fetchedAtMs': fetchedAt.millisecondsSinceEpoch,
    'rates': {
      for (final currency in Currency.values)
        currency.code: rates[currency]!.toJson(),
    },
  };
}

/// Parse the provider's JSON numbers directly from their source spelling.
/// jsonDecode would first round decimal rates to IEEE-754 double values.
NetworkRateSnapshot parseEcbRates(String body, {required DateTime fetchedAt}) {
  _checkJsonSize(body);
  final value = _ExactJsonReader(body).read();
  if (value is! List<Object?> || value.length != 5) {
    throw const FormatException('汇率响应数量无效');
  }
  final rates = <Currency, RateRatio>{
    Currency.eur: RateRatio(BigInt.one, BigInt.one),
  };
  DateTime? quotedAt;
  final fetchedUtc = fetchedAt.toUtc();
  final today = DateTime.utc(fetchedUtc.year, fetchedUtc.month, fetchedUtc.day);
  for (final row in value) {
    final map = _objectWithKeys(row, const {'date', 'base', 'quote', 'rate'});
    final date = _parseDate(map['date']);
    final quote = map['quote'];
    final currency = quote is String ? Currency.tryFromCode(quote) : null;
    final number = map['rate'];
    if (map['base'] != 'EUR' ||
        currency == null ||
        quote != currency.code ||
        currency == Currency.eur ||
        rates.containsKey(currency) ||
        number is! _JsonNumber ||
        date.isAfter(today) ||
        (quotedAt != null && date != quotedAt)) {
      throw const FormatException('汇率响应内容无效');
    }
    quotedAt = date;
    rates[currency] = RateRatio.parse(number.raw);
  }
  return NetworkRateSnapshot(
    quotedAt: quotedAt!,
    fetchedAt: fetchedAt,
    rates: rates,
  );
}

/// Validate cached JSON before jsonDecode can silently discard duplicate keys.
/// Cache records may hold all fifteen manual pairs, so permit a bounded larger
/// node budget than the five-row provider response.
void validateRateJson(String raw) {
  _checkJsonSize(raw);
  _ExactJsonReader(raw, maxNodes: 256).read();
}

void _checkJsonSize(String raw) {
  if (raw.length > 32768 || utf8.encode(raw).length > 32768) {
    throw const FormatException('汇率 JSON 过大');
  }
}

Map<Object?, Object?> _objectWithKeys(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      value.keys.any((key) => key is! String || !keys.contains(key))) {
    throw const FormatException('汇率数据结构无效');
  }
  return Map<Object?, Object?>.from(value);
}

DateTime _requireUtcDate(DateTime date) {
  if (!date.isUtc ||
      date.year < 1 ||
      date.year > 9999 ||
      date.hour != 0 ||
      date.minute != 0 ||
      date.second != 0 ||
      date.millisecond != 0 ||
      date.microsecond != 0) {
    throw const FormatException('报价日期必须为 UTC 日期');
  }
  return date;
}

DateTime _parseDate(Object? value) {
  if (value is! String ||
      value.length != 10 ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('报价日期无效');
  }
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  final date = DateTime.utc(year, month, day);
  if (year == 0 ||
      date.year != year ||
      date.month != month ||
      date.day != day) {
    throw const FormatException('报价日期无效');
  }
  return date;
}

String _dateText(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

class _JsonNumber {
  const _JsonNumber(this.raw);
  final String raw;
}

/// Bounded JSON reader, retaining only numeric tokens without float parsing.
class _ExactJsonReader {
  _ExactJsonReader(this.body, {this.maxNodes = 128});
  final String body;
  final int maxNodes;
  int index = 0;
  int nodes = 0;

  Object? read() {
    final result = _value(0);
    _space();
    if (index != body.length) _invalid();
    return result;
  }

  Object? _value(int depth) {
    if (depth > 8 || ++nodes > maxNodes) _invalid();
    _space();
    if (index >= body.length) _invalid();
    final char = body[index];
    if (char == '"') return _string();
    if (char == '{') {
      index++;
      final result = <String, Object?>{};
      _space();
      if (_take('}')) return result;
      while (true) {
        _space();
        if (index >= body.length || body[index] != '"') _invalid();
        final key = _string();
        if (result.containsKey(key)) _invalid();
        _space();
        if (!_take(':')) _invalid();
        result[key] = _value(depth + 1);
        _space();
        if (_take('}')) return result;
        if (!_take(',')) _invalid();
      }
    }
    if (char == '[') {
      index++;
      final result = <Object?>[];
      _space();
      if (_take(']')) return result;
      while (true) {
        result.add(_value(depth + 1));
        _space();
        if (_take(']')) return result;
        if (!_take(',')) _invalid();
      }
    }
    for (final literal in const ['true', 'false', 'null']) {
      if (body.startsWith(literal, index)) {
        index += literal.length;
        return switch (literal) {
          'true' => true,
          'false' => false,
          _ => null,
        };
      }
    }
    final match = RegExp(r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?')
        .matchAsPrefix(body, index);
    if (match == null) _invalid();
    index = match.end;
    return _JsonNumber(match.group(0)!);
  }

  String _string() {
    final start = index++;
    while (index < body.length) {
      final char = body.codeUnitAt(index++);
      if (char == 0x22) {
        try {
          return jsonDecode(body.substring(start, index)) as String;
        } on FormatException {
          _invalid();
        }
      }
      if (char < 0x20) _invalid();
      if (char == 0x5c) {
        if (index >= body.length) _invalid();
        final escaped = body[index++];
        if (escaped == 'u') {
          if (index + 4 > body.length ||
              !RegExp(r'^[0-9a-fA-F]{4}$')
                  .hasMatch(body.substring(index, index + 4))) {
            _invalid();
          }
          index += 4;
        } else if (!const [
          '"',
          r'\',
          '/',
          'b',
          'f',
          'n',
          'r',
          't',
        ].contains(escaped)) {
          _invalid();
        }
      }
    }
    _invalid();
  }

  bool _take(String char) {
    if (index < body.length && body[index] == char) {
      index++;
      return true;
    }
    return false;
  }

  void _space() {
    while (index < body.length &&
        const [0x20, 0x09, 0x0a, 0x0d].contains(body.codeUnitAt(index))) {
      index++;
    }
  }

  Never _invalid() => throw const FormatException('汇率 JSON 无效');
}
