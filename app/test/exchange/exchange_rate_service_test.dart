import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

final _now = DateTime.utc(2026, 10, 16, 12);

NetworkRateSnapshot _snapshot({
  DateTime? fetchedAt,
  DateTime? quotedAt,
  String usd = '1.1',
}) => NetworkRateSnapshot(
  quotedAt: quotedAt ?? DateTime.utc(2026, 10, 16),
  fetchedAt: fetchedAt ?? _now,
  rates: {
    Currency.cny: RateRatio.parse('7.7'),
    Currency.usd: RateRatio.parse(usd),
    Currency.hkd: RateRatio.parse('8.58'),
    Currency.eur: RateRatio.parse('1'),
    Currency.jpy: RateRatio.parse('165'),
    Currency.gbp: RateRatio.parse('0.88'),
  },
);

Map<String, Object?> _manual(
  Currency base,
  Currency quote,
  String value, {
  DateTime? updatedAt,
}) => {
  'base': base.code,
  'quote': quote.code,
  'ratio': RateRatio.parse(value).toJson(),
  'updatedAtMs': (updatedAt ?? _now).millisecondsSinceEpoch,
};

String _cache({
  NetworkRateSnapshot? network,
  List<Map<String, Object?>> manual = const [],
  int version = 1,
}) => jsonEncode({
  'version': version,
  'network': network?.toJson(),
  'manual': manual,
});

class _Store implements RateStore {
  _Store([this.value]);

  String? value;
  Future<String?> Function()? readHook;
  Future<void> Function(String)? writeHook;
  int reads = 0;
  int activeWrites = 0;
  int maxActiveWrites = 0;
  final writes = <String>[];

  @override
  Future<String?> read() async {
    reads++;
    return readHook == null ? value : await readHook!();
  }

  @override
  Future<void> write(String next) async {
    writes.add(next);
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    try {
      await writeHook?.call(next);
      value = next;
    } finally {
      activeWrites--;
    }
  }
}

class _Source implements RateSource {
  final result = Completer<NetworkRateSnapshot>();
  int fetches = 0;
  int cancels = 0;
  int disposals = 0;

  @override
  Future<NetworkRateSnapshot> fetch() {
    fetches++;
    return result.future;
  }

  @override
  void cancel() => cancels++;

  @override
  void dispose() => disposals++;
}

ExchangeRateService _service(
  _Store store, {
  List<_Source> sources = const [],
  DateTime Function()? now,
}) {
  var index = 0;
  return ExchangeRateService(
    store: store,
    now: now ?? () => _now,
    sourceFactory: () {
      if (index == sources.length) {
        throw StateError('unexpected network request');
      }
      return sources[index++];
    },
  );
}

Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _expectRatio(
  ExchangeRateService service,
  Currency base,
  Currency quote,
  String value, {
  required bool manual,
}) {
  final result = service.quote(base, quote);
  expect(result, isNotNull);
  expect(result!.base, base);
  expect(result.quote, quote);
  expect(result.ratio, RateRatio.parse(value));
  expect(result.isManual, manual);
}

void main() {
  group('shared exchange-rate service', () {
    test(
      'fresh complete cache initializes once without a network request',
      () async {
        final store = _Store(_cache(network: _snapshot()));
        final service = _service(store);
        addTearDown(service.dispose);

        await Future.wait([service.initialize(), service.initialize()]);

        expect(store.reads, 1);
        expect(store.writes, isEmpty);
        expect(service.initialized, isTrue);
        expect(service.loading, isFalse);
        expect(service.cacheCorrupt, isFalse);
        expect(service.error, isNull);
        _expectRatio(service, Currency.usd, Currency.cny, '7', manual: false);
        final quote = service.quote(Currency.usd, Currency.cny)!;
        expect(quote.isStale, isFalse);
        expect(quote.source, _snapshot().source);
        expect(quote.quotedAt, DateTime.utc(2026, 10, 16));
        expect(quote.fetchedAt, _now);
      },
    );

    test(
      'no cache obtains and atomically persists the first network snapshot',
      () async {
        final source = _Source();
        final store = _Store();
        final service = _service(store, sources: [source]);
        addTearDown(service.dispose);

        final initialization = service.initialize();
        await _flush();
        expect(source.fetches, 1);
        expect(service.loading, isTrue);
        expect(store.writes, isEmpty);
        source.result.complete(_snapshot());
        await initialization;
        await _flush();

        expect(store.writes, hasLength(1));
        expect(service.loading, isFalse);
        expect(service.network?.rates, _snapshot().rates);
        expect(jsonDecode(store.value!)['network'], _snapshot().toJson());
        final yen = service.quote(Currency.jpy, Currency.cny)!;
        expect(yen.ratio, RateRatio(BigInt.from(7), BigInt.from(150)));
        expect(
          yen.ratio.convertMinorUnits(
            BigInt.from(150),
            Currency.jpy,
            Currency.cny,
          ),
          BigInt.from(700),
        );
      },
    );

    test(
      'a 24-hour-old fetch refreshes while retaining its stale quote',
      () async {
        final old = _snapshot(
          fetchedAt: _now.subtract(const Duration(hours: 24)),
        );
        final source = _Source();
        final store = _Store(_cache(network: old));
        final service = _service(store, sources: [source]);
        addTearDown(service.dispose);

        final initialization = service.initialize();
        await _flush();
        expect(service.quote(Currency.usd, Currency.cny)!.isStale, isTrue);
        expect(source.fetches, 1);
        source.result.complete(_snapshot(usd: '1.2'));
        await initialization;
        await _flush();

        expect(service.quote(Currency.usd, Currency.cny)!.isStale, isFalse);
        expect(service.network!.rates[Currency.usd], RateRatio.parse('1.2'));
        expect(store.writes, hasLength(1));
      },
    );

    test(
      'a Friday quotation fetched on Sunday is current rather than expired',
      () async {
        final sunday = DateTime.utc(2026, 10, 18, 12);
        final store = _Store(_cache(network: _snapshot(fetchedAt: sunday)));
        final service = _service(store, now: () => sunday);
        addTearDown(service.dispose);

        await service.initialize();

        expect(service.quote(Currency.usd, Currency.cny)!.isStale, isFalse);
        expect(store.writes, isEmpty);
        expect(service.error, isNull);
      },
    );

    test(
      'initial offline failure exposes no fabricated rate and does not throw',
      () async {
        final source = _Source();
        final store = _Store();
        final service = _service(store, sources: [source]);
        addTearDown(service.dispose);

        final initialization = service.initialize();
        await _flush();
        source.result.completeError(StateError('offline'));
        await initialization;
        await _flush();

        expect(service.initialized, isTrue);
        expect(service.loading, isFalse);
        expect(service.error, isNotEmpty);
        expect(service.network, isNull);
        expect(service.quote(Currency.usd, Currency.cny), isNull);
        expect(store.writes, isEmpty);
      },
    );

    test('refresh failure retains the previous network snapshot and persisted bytes', () async {
      final original = _cache(network: _snapshot());
      final source = _Source();
      final store = _Store(original);
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);
      await service.initialize();

      final refresh = service.refresh();
      await _flush();
      source.result.completeError(StateError('timeout'));
      await refresh;

      expect(service.error, isNotEmpty);
      expect(service.loading, isFalse);
      expect(store.value, original);
      expect(store.writes, isEmpty);
      _expectRatio(service, Currency.usd, Currency.cny, '7', manual: false);
    });

    test(
      'cancelled refresh ignores a late successful response without persisting',
      () async {
        final original = _cache(network: _snapshot());
        final source = _Source();
        final store = _Store(original);
        final service = _service(store, sources: [source]);
        addTearDown(service.dispose);
        await service.initialize();

        final refresh = service.refresh();
        await _flush();
        service.cancelRefresh();
        expect(service.loading, isFalse);
        source.result.complete(_snapshot(usd: '1.2'));
        await refresh;

        expect(source.cancels, greaterThanOrEqualTo(1));
        expect(store.value, original);
        expect(store.writes, isEmpty);
        _expectRatio(service, Currency.usd, Currency.cny, '7', manual: false);
      },
    );

    test('cancelled refresh ignores a late failure rather than replacing current status', () async {
      final source = _Source();
      final store = _Store(_cache(network: _snapshot()));
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);
      await service.initialize();

      final refresh = service.refresh();
      await _flush();
      service.cancelRefresh();
      final errorAfterCancel = service.error;
      source.result.completeError(StateError('late offline'));
      await refresh;

      expect(service.error, errorAfterCancel);
      expect(store.writes, isEmpty);
      expect(service.loading, isFalse);
    });

    test('cancel then retry keeps the newer result when responses arrive backwards', () async {
      final first = _Source();
      final second = _Source();
      final store = _Store(_cache(network: _snapshot()));
      final service = _service(store, sources: [first, second]);
      addTearDown(service.dispose);
      await service.initialize();

      final oldRefresh = service.refresh();
      await _flush();
      service.cancelRefresh();
      final newRefresh = service.refresh();
      await _flush();
      second.result.complete(_snapshot(usd: '1.2'));
      await newRefresh;
      first.result.complete(_snapshot(usd: '1.3'));
      await oldRefresh;

      expect(first.cancels, greaterThanOrEqualTo(1));
      expect(store.writes, hasLength(1));
      expect(service.network!.rates[Currency.usd], RateRatio.parse('1.2'));
      expect(
        jsonDecode(store.value!)['network'],
        _snapshot(usd: '1.2').toJson(),
      );
    });

    test('manual save cancels a pending network result and preserves its prior cache', () async {
      final source = _Source();
      final store = _Store(_cache(network: _snapshot()));
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);
      await service.initialize();

      final refresh = service.refresh();
      await _flush();
      await service.setManual(
        Currency.usd,
        Currency.cny,
        '7.123456789012345678',
      );
      source.result.complete(_snapshot(usd: '1.2'));
      await refresh;

      expect(source.cancels, greaterThanOrEqualTo(1));
      expect(store.writes, hasLength(1));
      expect(service.network!.rates[Currency.usd], RateRatio.parse('1.1'));
      _expectRatio(
        service,
        Currency.usd,
        Currency.cny,
        '7.123456789012345678',
        manual: true,
      );
      final quote = service.quote(Currency.usd, Currency.cny)!;
      expect(quote.isStale, isFalse);
      expect(quote.source, isNot(_snapshot().source));
    });

    test('manual save waits for pending cache read and preserves another cached pair', () async {
      final read = Completer<String?>();
      final store = _Store()..readHook = () => read.future;
      final service = _service(store);
      addTearDown(service.dispose);

      final initialization = service.initialize();
      final manual = service.setManual(Currency.usd, Currency.cny, '7.2');
      await _flush();
      expect(store.writes, isEmpty);
      read.complete(
        _cache(
          network: _snapshot(),
          manual: [_manual(Currency.gbp, Currency.cny, '9')],
        ),
      );
      await Future.wait([initialization, manual]);

      expect(store.reads, 1);
      _expectRatio(service, Currency.usd, Currency.cny, '7.2', manual: true);
      _expectRatio(service, Currency.gbp, Currency.cny, '9', manual: true);
      expect(jsonDecode(store.value!)['manual'], hasLength(2));
    });

    test('manual save during empty-cache initialization need not wait for the network', () async {
      final read = Completer<String?>();
      final source = _Source();
      final store = _Store()..readHook = () => read.future;
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);

      final initialization = service.initialize();
      final manual = service.setManual(Currency.usd, Currency.cny, '7.2');
      read.complete(null);
      await manual.timeout(const Duration(seconds: 1));
      _expectRatio(service, Currency.usd, Currency.cny, '7.2', manual: true);
      final bytesAfterManual = store.value;
      source.result.complete(_snapshot());
      await initialization;
      await _flush();

      expect(store.value, bytesAfterManual);
      expect(store.writes, hasLength(1));
      expect(service.network, isNull);
      _expectRatio(service, Currency.usd, Currency.cny, '7.2', manual: true);
    });

    test('read failure blocks unknown-state overwrites and explicit refresh retries the read', () async {
      final source = _Source();
      final store = _Store(_cache(network: _snapshot()))
        ..readHook = () async => throw StateError('read failed');
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);

      await service.initialize();
      expect(service.error, isNotEmpty);
      await expectLater(
        service.setManual(Currency.usd, Currency.cny, '7.2'),
        throwsA(anything),
      );
      expect(store.writes, isEmpty);
      expect(source.fetches, 0);

      store.readHook = null;
      final refresh = service.refresh();
      await _flush();
      source.result.complete(_snapshot(usd: '1.2'));
      await refresh;
      expect(store.reads, greaterThanOrEqualTo(2));
      expect(service.error, isNull);
      expect(store.writes, hasLength(1));
      expect(service.network!.rates[Currency.usd], RateRatio.parse('1.2'));
    });

    test('corrupt future, duplicate, incomplete and unknown-version caches stay untouched', () async {
      final incomplete = _snapshot().toJson();
      final rates = Map<String, Object?>.from(incomplete['rates']! as Map);
      rates.remove('JPY');
      incomplete['rates'] = rates;
      final corruptCaches = <String>[
        '{not json',
        _cache(network: _snapshot(), version: 2),
        jsonEncode({
          'version': 1.0,
          'network': _snapshot().toJson(),
          'manual': [],
        }),
        _cache(
          network: _snapshot(fetchedAt: _now.add(const Duration(minutes: 6))),
        ),
        _cache(network: _snapshot(quotedAt: DateTime.utc(2026, 10, 17))),
        _cache(
          network: _snapshot(),
          manual: [
            _manual(
              Currency.usd,
              Currency.cny,
              '7',
              updatedAt: _now.add(const Duration(minutes: 6)),
            ),
          ],
        ),
        _cache(
          network: _snapshot(),
          manual: [
            _manual(Currency.usd, Currency.cny, '7'),
            _manual(Currency.cny, Currency.usd, '0.2'),
          ],
        ),
        jsonEncode({'version': 1, 'network': incomplete, 'manual': []}),
      ];

      for (final raw in corruptCaches) {
        final store = _Store(raw);
        final service = _service(store);
        try {
          await service.initialize();
          expect(service.initialized, isTrue);
          expect(service.cacheCorrupt, isTrue, reason: raw);
          expect(service.network, isNull, reason: raw);
          expect(store.value, raw);
          expect(store.writes, isEmpty);
        } finally {
          service.dispose();
        }
      }
    });

    test('explicit refresh repairs a corrupt cache after validated network success', () async {
      final source = _Source();
      final store = _Store('broken');
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.cacheCorrupt, isTrue);

      final refresh = service.refresh();
      await _flush();
      source.result.complete(_snapshot());
      await refresh;

      expect(service.cacheCorrupt, isFalse);
      expect(service.error, isNull);
      expect(store.writes, hasLength(1));
      expect(jsonDecode(store.value!)['network'], _snapshot().toJson());
    });

    test('manual override is exact in both directions and does not leak to other pairs', () async {
      final store = _Store(_cache(network: _snapshot()));
      final service = _service(store);
      addTearDown(service.dispose);
      await service.initialize();

      await service.setManual(
        Currency.usd,
        Currency.cny,
        '7.123456789012345678',
      );
      final forward = service.quote(Currency.usd, Currency.cny)!;
      final reverse = service.quote(Currency.cny, Currency.usd)!;
      expect(reverse.isManual, isTrue);
      expect(reverse.ratio, forward.ratio.inverse);
      expect(service.quote(Currency.usd, Currency.jpy)!.isManual, isFalse);
      expect(service.quote(Currency.gbp, Currency.cny)!.isManual, isFalse);
      expect(jsonDecode(store.value!)['manual'], hasLength(1));

      final reopened = _service(_Store(store.value));
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.quote(Currency.usd, Currency.cny)!.ratio, forward.ratio);
      expect(reopened.quote(Currency.cny, Currency.usd)!.ratio, reverse.ratio);
    });

    test(
      'invalid manual values and same-currency overrides cannot write state',
      () async {
        final original = _cache(network: _snapshot());
        final store = _Store(original);
        final service = _service(store);
        addTearDown(service.dispose);
        await service.initialize();

        for (final value in [
          '',
          '0',
          '-1',
          'NaN',
          'Infinity',
          '1e3',
          '1,000',
          '1.1234567890123456789',
          '0.0000000000000000001',
          '1000000000000000001',
          List.filled(100, '1').join(),
        ]) {
          await expectLater(
            service.setManual(Currency.usd, Currency.cny, value),
            throwsA(anything),
          );
        }
        await expectLater(
          service.setManual(Currency.cny, Currency.cny, '1'),
          throwsA(anything),
        );
        expect(store.writes, isEmpty);
        expect(store.value, original);
        _expectRatio(service, Currency.usd, Currency.cny, '7', manual: false);
      },
    );

    test('manual write failure throws and retains the old effective and persisted value', () async {
      final original = _cache(
        network: _snapshot(),
        manual: [_manual(Currency.usd, Currency.cny, '7.1')],
      );
      final store = _Store(original)
        ..writeHook = (_) async => throw StateError('disk full');
      final service = _service(store);
      addTearDown(service.dispose);
      await service.initialize();

      await expectLater(
        service.setManual(Currency.usd, Currency.cny, '7.2'),
        throwsA(anything),
      );

      expect(service.error, isNotEmpty);
      expect(service.saving, isFalse);
      expect(store.value, original);
      _expectRatio(service, Currency.usd, Currency.cny, '7.1', manual: true);
    });

    test('restore network removes either direction of only the selected manual pair', () async {
      final store = _Store(
        _cache(
          network: _snapshot(),
          manual: [
            _manual(Currency.usd, Currency.cny, '7.2'),
            _manual(Currency.gbp, Currency.cny, '9'),
          ],
        ),
      );
      final service = _service(store);
      addTearDown(service.dispose);
      await service.initialize();

      await service.useNetwork(Currency.cny, Currency.usd);

      _expectRatio(service, Currency.usd, Currency.cny, '7', manual: false);
      _expectRatio(service, Currency.gbp, Currency.cny, '9', manual: true);
      expect(jsonDecode(store.value!)['manual'], hasLength(1));
      expect(store.writes, hasLength(1));
    });

    test(
      'restore-network write failure leaves the manual override active',
      () async {
        final original = _cache(
          network: _snapshot(),
          manual: [_manual(Currency.usd, Currency.cny, '7.2')],
        );
        final store = _Store(original)
          ..writeHook = (_) async => throw StateError('disk full');
        final service = _service(store);
        addTearDown(service.dispose);
        await service.initialize();

        await expectLater(
          service.useNetwork(Currency.usd, Currency.cny),
          throwsA(anything),
        );

        expect(store.value, original);
        expect(service.saving, isFalse);
        expect(service.error, isNotEmpty);
        _expectRatio(service, Currency.usd, Currency.cny, '7.2', manual: true);
      },
    );

    test('restore network refreshes an expired snapshot without retaining the old manual mode', () async {
      var clock = _now;
      final source = _Source();
      final store = _Store(
        _cache(
          network: _snapshot(),
          manual: [_manual(Currency.usd, Currency.cny, '7.2')],
        ),
      );
      final service = _service(store, sources: [source], now: () => clock);
      addTearDown(service.dispose);
      await service.initialize();
      clock = _now.add(const Duration(hours: 25));

      final restore = service.useNetwork(Currency.usd, Currency.cny);
      await _flush();
      expect(source.fetches, 1);
      source.result.complete(_snapshot(fetchedAt: clock, usd: '1.2'));
      await restore;
      await _flush();

      final quote = service.quote(Currency.usd, Currency.cny)!;
      expect(quote.isManual, isFalse);
      expect(quote.isStale, isFalse);
      expect(
        quote.ratio,
        _snapshot(usd: '1.2').ratio(Currency.usd, Currency.cny),
      );
      expect(jsonDecode(store.value!)['manual'], isEmpty);
    });

    test('concurrent manual writes serialize and retain both successful pair updates', () async {
      final firstWrite = Completer<void>();
      final store = _Store(_cache(network: _snapshot()));
      var writeIndex = 0;
      store.writeHook = (_) async {
        if (writeIndex++ == 0) await firstWrite.future;
      };
      final service = _service(store);
      addTearDown(service.dispose);
      await service.initialize();

      final first = service.setManual(Currency.usd, Currency.cny, '7.2');
      await _flush();
      final second = service.setManual(Currency.gbp, Currency.cny, '9');
      await _flush();
      expect(service.saving, isTrue);
      expect(store.writes, hasLength(1));
      expect(service.quote(Currency.usd, Currency.cny)!.isManual, isFalse);
      firstWrite.complete();
      await Future.wait([first, second]);

      expect(store.maxActiveWrites, 1);
      expect(store.writes, hasLength(2));
      expect(service.saving, isFalse);
      _expectRatio(service, Currency.usd, Currency.cny, '7.2', manual: true);
      _expectRatio(service, Currency.gbp, Currency.cny, '9', manual: true);
      expect(jsonDecode(store.value!)['manual'], hasLength(2));
    });

    test('network persistence failure exposes an error without replacing the old snapshot', () async {
      final source = _Source();
      final original = _cache(network: _snapshot());
      final store = _Store(original)
        ..writeHook = (_) async => throw StateError('disk full');
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);
      await service.initialize();

      final refresh = service.refresh();
      await _flush();
      source.result.complete(_snapshot(usd: '1.2'));
      await refresh;

      expect(service.error, isNotEmpty);
      expect(service.loading, isFalse);
      expect(store.value, original);
      expect(service.network!.rates[Currency.usd], RateRatio.parse('1.1'));
    });

    test(
      'a loading listener can cancel before the source factory is called',
      () async {
        final source = _Source()..result.complete(_snapshot());
        final store = _Store();
        var factories = 0;
        final service = ExchangeRateService(
          store: store,
          now: () => _now,
          sourceFactory: () {
            factories++;
            return source;
          },
        );
        addTearDown(service.dispose);
        service.addListener(() {
          if (service.loading) service.cancelRefresh();
        });

        await service.initialize();

        expect(factories, 0);
        expect(source.fetches, 0);
        expect(service.initialized, isTrue);
        expect(service.loading, isFalse);
        expect(service.network, isNull);
        expect(service.error, contains('取消'));
        expect(store.writes, isEmpty);
      },
    );

    test(
      'a throwing source factory becomes a controlled refresh error',
      () async {
        final store = _Store();
        final service = ExchangeRateService(
          store: store,
          now: () => _now,
          sourceFactory: () => throw StateError('factory unavailable'),
        );
        addTearDown(service.dispose);

        await service.initialize();

        expect(service.initialized, isTrue);
        expect(service.loading, isFalse);
        expect(service.saving, isFalse);
        expect(service.network, isNull);
        expect(service.error, isNotEmpty);
        expect(store.writes, isEmpty);
      },
    );

    test('network commit cannot be cancelled and a later manual write retains that snapshot', () async {
      final source = _Source();
      final commit = Completer<void>();
      final original = _cache(network: _snapshot());
      final store = _Store(original);
      var writeIndex = 0;
      store.writeHook = (_) async {
        if (writeIndex++ == 0) await commit.future;
      };
      final service = _service(store, sources: [source]);
      addTearDown(service.dispose);
      await service.initialize();

      final refresh = service.refresh();
      await _flush();
      source.result.complete(_snapshot(usd: '1.2'));
      await _flush();
      expect(service.loading, isFalse);
      expect(service.saving, isTrue);
      expect(store.writes, hasLength(1));
      expect(store.value, original);
      service.cancelRefresh();
      expect(service.error, isNull);
      expect(source.cancels, 0);

      final manual = service.setManual(Currency.usd, Currency.cny, '7.2');
      await _flush();
      expect(store.writes, hasLength(1));
      expect(service.quote(Currency.usd, Currency.cny)!.isManual, isFalse);
      commit.complete();
      await Future.wait([refresh, manual]);

      expect(store.maxActiveWrites, 1);
      expect(store.writes, hasLength(2));
      expect(service.loading, isFalse);
      expect(service.saving, isFalse);
      expect(service.network!.rates[Currency.usd], RateRatio.parse('1.2'));
      _expectRatio(service, Currency.usd, Currency.cny, '7.2', manual: true);
      expect(
        jsonDecode(store.value!)['network'],
        _snapshot(usd: '1.2').toJson(),
      );
      expect(jsonDecode(store.value!)['manual'], hasLength(1));
    });

    test('all fifteen pairs survive restart and a reverse update replaces one pair', () async {
      final pairs = <Map<String, Object?>>[];
      for (var i = 0; i < Currency.values.length; i++) {
        for (var j = i + 1; j < Currency.values.length; j++) {
          pairs.add(_manual(Currency.values[i], Currency.values[j], '1.$i$j'));
        }
      }
      expect(pairs, hasLength(15));
      final store = _Store(_cache(network: _snapshot(), manual: pairs));
      final service = _service(store);
      addTearDown(service.dispose);
      await service.initialize();

      expect(service.cacheCorrupt, isFalse);
      expect(store.writes, isEmpty);
      for (final pair in pairs) {
        final base = Currency.tryFromCode(pair['base']! as String)!;
        final quote = Currency.tryFromCode(pair['quote']! as String)!;
        final ratio = RateRatio.fromJson(pair['ratio']);
        expect(service.quote(base, quote)!.ratio, ratio);
        expect(service.quote(quote, base)!.ratio, ratio.inverse);
        expect(service.quote(base, quote)!.isManual, isTrue);
      }

      await service.setManual(Currency.gbp, Currency.jpy, '2');
      expect(jsonDecode(store.value!)['manual'], hasLength(15));
      final reopened = _service(_Store(store.value));
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.cacheCorrupt, isFalse);
      _expectRatio(reopened, Currency.gbp, Currency.jpy, '2', manual: true);
      _expectRatio(reopened, Currency.jpy, Currency.gbp, '0.5', manual: true);
      _expectRatio(reopened, Currency.cny, Currency.usd, '1.01', manual: true);
      expect(reopened.network!.rates, _snapshot().rates);
    });

    test('restore network on first initialization does not await a cancelled startup request', () async {
      final startup = _Source();
      final restored = _Source();
      final store = _Store();
      final service = _service(store, sources: [startup, restored]);
      addTearDown(service.dispose);

      final restore = service.useNetwork(Currency.usd, Currency.cny);
      await _flush();
      expect(startup.fetches, 1);
      expect(startup.cancels, greaterThanOrEqualTo(1));
      expect(restored.fetches, 1);
      restored.result.complete(_snapshot(usd: '1.2'));
      await restore.timeout(const Duration(seconds: 1));
      final afterRestore = store.value;
      startup.result.complete(_snapshot(usd: '1.3'));
      await _flush();

      expect(service.loading, isFalse);
      expect(service.network!.rates[Currency.usd], RateRatio.parse('1.2'));
      expect(store.value, afterRestore);
      expect(store.writes, hasLength(2));
      expect(jsonDecode(store.value!)['manual'], isEmpty);
    });

    test('dispose cancels a pending source and ignores completion without notifying or writing', () async {
      final source = _Source();
      final store = _Store(_cache(network: _snapshot()));
      final service = _service(store, sources: [source]);
      await service.initialize();
      var notifications = 0;
      service.addListener(() => notifications++);
      final refresh = service.refresh();
      await _flush();
      service.dispose();
      final atDispose = notifications;
      source.result.complete(_snapshot(usd: '1.2'));
      await refresh;

      expect(source.cancels, greaterThanOrEqualTo(1));
      expect(source.disposals, greaterThanOrEqualTo(1));
      expect(notifications, atDispose);
      expect(store.writes, isEmpty);
    });

    test('dispose during the initial read prevents later network and cache mutations', () async {
      final read = Completer<String?>();
      final store = _Store()..readHook = () => read.future;
      final service = _service(store);
      var notifications = 0;
      service.addListener(() => notifications++);
      final initialization = service.initialize();
      await _flush();
      service.dispose();
      final atDispose = notifications;
      read.complete(null);
      await initialization;
      await _flush();

      expect(store.writes, isEmpty);
      expect(notifications, atDispose);
    });
  });
}
