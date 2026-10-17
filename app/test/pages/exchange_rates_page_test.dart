import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/pages/exchange_rates_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 10, 16, 10, 30);

NetworkRateSnapshot _snapshot({DateTime? fetchedAt, String cny = '14'}) =>
    NetworkRateSnapshot(
      quotedAt: DateTime.utc(
        (fetchedAt ?? _now).year,
        (fetchedAt ?? _now).month,
        (fetchedAt ?? _now).day,
      ),
      fetchedAt: fetchedAt ?? _now,
      rates: {
        Currency.eur: RateRatio.parse('1'),
        Currency.usd: RateRatio.parse('2'),
        Currency.cny: RateRatio.parse(cny),
        Currency.hkd: RateRatio.parse('16'),
        Currency.jpy: RateRatio.parse('300'),
        Currency.gbp: RateRatio.parse('0.8'),
      },
    );

String _cache(NetworkRateSnapshot snapshot) => jsonEncode({
  'version': 1,
  'network': snapshot.toJson(),
  'manual': <Object>[],
});

class _MemoryStore implements RateStore {
  _MemoryStore(this.data);
  String? data;
  int writes = 0;
  bool failWrites = false;
  Completer<void>? gate;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String value) async {
    writes++;
    await gate?.future;
    if (failWrites) throw StateError('test storage failure');
    data = value;
  }
}

class _TestSource implements RateSource {
  _TestSource(this.fetchResult);
  final Future<NetworkRateSnapshot> Function() fetchResult;
  int cancelled = 0;
  int disposed = 0;

  @override
  Future<NetworkRateSnapshot> fetch() => fetchResult();

  @override
  void cancel() => cancelled++;

  @override
  void dispose() => disposed++;
}

class _Harness {
  _Harness({String? cache, Future<NetworkRateSnapshot> Function()? fetch})
    : store = _MemoryStore(cache) {
    service = ExchangeRateService(
      store: store,
      now: () => _now,
      sourceFactory: () {
        requests++;
        source = _TestSource(fetch ?? () async => _snapshot());
        return source!;
      },
    );
  }

  final _MemoryStore store;
  late final ExchangeRateService service;
  _TestSource? source;
  int requests = 0;
}

/// Bounded frames also work while a deliberately pending request animates.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _mount(WidgetTester tester, _Harness harness) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.service.dispose();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        exchangeRateServiceProvider.overrideWithValue(harness.service),
      ],
      child: const MaterialApp(home: ExchangeRatesPage()),
    ),
  );
  await _frames(tester);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _frames(tester);
}

Future<void> _selectCurrency(
  WidgetTester tester,
  String key,
  String code,
) async {
  await _tapKey(tester, key);
  await tester.tap(find.text(code).last);
  await _frames(tester);
}

Future<void> _manual(WidgetTester tester, String input) async {
  await _tapKey(tester, 'rate-manual-edit');
  await tester.enterText(find.byKey(const Key('rate-manual-input')), input);
  await _tapKey(tester, 'rate-manual-save');
}

String _value(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('rate-value'))).data!;

void main() {
  testWidgets(
    'initializes once and shows reference source, dates and precision',
    (tester) async {
      final harness = _Harness(
        fetch: () async => _snapshot(cny: '14.123456789012345678'),
      );
      await _mount(tester, harness);

      expect(_value(tester), '1 USD ≈ 7.061728394506172839 CNY');
      expect(find.text('来源：Frankfurter / ECB'), findsOneWidget);
      expect(find.text('报价日期：2026-10-16'), findsOneWidget);
      expect(find.textContaining('获取时间：'), findsOneWidget);
      expect(find.textContaining('并非实时成交汇率'), findsOneWidget);
      expect(harness.requests, 1);
      await _selectCurrency(tester, 'rate-base', 'EUR');
      await _selectCurrency(tester, 'rate-base', 'USD');
      expect(harness.requests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual save updates the inverse but does not cross other pairs',
    (tester) async {
      final harness = _Harness(cache: _cache(_snapshot()));
      await _mount(tester, harness);
      await _manual(tester, '7.25');

      expect(_value(tester), '1 USD ≈ 7.25 CNY');
      expect(find.text('来源：手动设置'), findsOneWidget);
      expect(find.textContaining('手动更新时间：'), findsOneWidget);
      expect(
        harness.service.quote(Currency.cny, Currency.usd)!.ratio,
        RateRatio(BigInt.from(4), BigInt.from(29)),
      );
      expect(
        harness.service.quote(Currency.eur, Currency.cny)!.isManual,
        isFalse,
      );
      await _selectCurrency(tester, 'rate-base', 'CNY');
      await _selectCurrency(tester, 'rate-quote', 'USD');
      expect(_value(tester), '1 CNY ≈ 0.137931034482758621 USD');
      expect(harness.store.writes, 1);
    },
  );

  testWidgets('invalid manual inputs remain in dialog and never persist', (
    tester,
  ) async {
    final harness = _Harness(cache: _cache(_snapshot()));
    await _mount(tester, harness);
    await _tapKey(tester, 'rate-manual-edit');
    for (final invalid in ['0', '-1', '1e3', '7.1234567890123456789', 'NaN']) {
      await tester.enterText(
        find.byKey(const Key('rate-manual-input')),
        invalid,
      );
      await _tapKey(tester, 'rate-manual-save');
      expect(find.byType(AlertDialog), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('rate-manual-input')),
      );
      expect(field.decoration!.errorText, isNotNull);
      expect(harness.store.writes, 0);
    }
    await tester.enterText(find.byKey(const Key('rate-manual-input')), '.5');
    await _tapKey(tester, 'rate-manual-save');
    expect(_value(tester), '1 USD ≈ 0.5 CNY');
    expect(harness.store.writes, 1);
  });

  testWidgets('canceling a draft does not change the saved quote', (
    tester,
  ) async {
    final harness = _Harness(cache: _cache(_snapshot()));
    await _mount(tester, harness);
    final before = harness.store.data;
    await _tapKey(tester, 'rate-manual-edit');
    await tester.enterText(find.byKey(const Key('rate-manual-input')), '999');
    await _tapKey(tester, 'rate-manual-cancel');
    expect(_value(tester), '1 USD ≈ 7 CNY');
    expect(harness.store.data, before);
    expect(harness.store.writes, 0);
  });

  testWidgets('restoring network clears the pair and its inverse', (
    tester,
  ) async {
    final harness = _Harness(cache: _cache(_snapshot()));
    await _mount(tester, harness);
    await _manual(tester, '7.25');
    await _tapKey(tester, 'rate-use-network');

    expect(_value(tester), '1 USD ≈ 7 CNY');
    expect(find.text('来源：Frankfurter / ECB'), findsOneWidget);
    expect(
      harness.service.quote(Currency.cny, Currency.usd)!.isManual,
      isFalse,
    );
    expect(harness.store.writes, 2);
    expect(harness.requests, 0);
  });

  testWidgets('offline refresh explicitly retains an expired network cache', (
    tester,
  ) async {
    final harness = _Harness(
      cache: _cache(
        _snapshot(fetchedAt: _now.subtract(const Duration(days: 2))),
      ),
      fetch: () async => throw const SocketException('offline'),
    );
    await _mount(tester, harness);

    expect(_value(tester), '1 USD ≈ 7 CNY');
    expect(find.text('网络缓存已过期，请刷新或手动设置。'), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsOneWidget);
    expect(find.textContaining('继续显示已有网络缓存'), findsOneWidget);
    expect(harness.store.writes, 0);
  });

  testWidgets('cancel rejects late response and manual remains available', (
    tester,
  ) async {
    final pending = Completer<NetworkRateSnapshot>();
    final harness = _Harness(fetch: () => pending.future);
    await _mount(tester, harness);
    expect(find.byKey(const Key('rate-cancel')), findsOneWidget);
    expect(_value(tester), '暂无可用汇率');

    await _tapKey(tester, 'rate-cancel');
    expect(harness.source!.cancelled, 1);
    await _manual(tester, '7.3');
    pending.complete(_snapshot(cny: '200'));
    await _frames(tester);
    expect(_value(tester), '1 USD ≈ 7.3 CNY');
    expect(harness.service.network, isNull);
    expect(harness.store.writes, 1);
  });

  testWidgets('manual save can replace a request without waiting for it', (
    tester,
  ) async {
    final pending = Completer<NetworkRateSnapshot>();
    final harness = _Harness(fetch: () => pending.future);
    await _mount(tester, harness);
    expect(harness.service.loading, isTrue);
    await _manual(tester, '7.4');
    expect(harness.service.loading, isFalse);
    expect(_value(tester), '1 USD ≈ 7.4 CNY');
    pending.complete(_snapshot(cny: '200'));
    await _frames(tester);
    expect(_value(tester), '1 USD ≈ 7.4 CNY');
    expect(harness.source!.cancelled, 1);
  });

  testWidgets('failed storage keeps the dialog and original quote', (
    tester,
  ) async {
    final harness = _Harness(cache: _cache(_snapshot()));
    harness.store.failWrites = true;
    await _mount(tester, harness);
    await _manual(tester, '7.8');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('手动汇率保存失败，原值已保留'),
      ),
      findsOneWidget,
    );
    expect(
      harness.service.quote(Currency.usd, Currency.cny)!.isManual,
      isFalse,
    );
    harness.store.failWrites = false;
    await _tapKey(tester, 'rate-manual-save');
    expect(_value(tester), '1 USD ≈ 7.8 CNY');
  });

  testWidgets('saving disables repeated submissions and cancellation', (
    tester,
  ) async {
    final harness = _Harness(cache: _cache(_snapshot()));
    harness.store.gate = Completer<void>();
    await _mount(tester, harness);
    await _manual(tester, '7.6');

    expect(harness.store.writes, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('rate-manual-save')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('rate-manual-cancel')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('rate-manual-save')));
    await _frames(tester);
    expect(harness.store.writes, 1);
    harness.store.gate!.complete();
    await _frames(tester);
    expect(_value(tester), '1 USD ≈ 7.6 CNY');
  });

  testWidgets(
    'corrupt cache is explicit and same-currency editing is disabled',
    (tester) async {
      final harness = _Harness(cache: '{broken');
      await _mount(tester, harness);
      expect(find.byKey(const Key('rate-cache-corrupt')), findsOneWidget);
      expect(harness.requests, 0);
      await _selectCurrency(tester, 'rate-base', 'CNY');
      expect(_value(tester), '1 CNY = 1 CNY');
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('rate-manual-edit')))
            .onPressed,
        isNull,
      );
      expect(harness.store.writes, 0);
    },
  );

  testWidgets('360-wide keyboard dialog and disposed late request are safe', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final pending = Completer<NetworkRateSnapshot>();
    final harness = _Harness(fetch: () => pending.future);
    await _mount(tester, harness);
    await _tapKey(tester, 'rate-manual-edit');
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await _frames(tester);
    await tester.enterText(find.byKey(const Key('rate-manual-input')), '0');
    await _tapKey(tester, 'rate-manual-save');
    expect(tester.takeException(), isNull);
    await _tapKey(tester, 'rate-manual-cancel');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_snapshot());
    await _frames(tester);
    expect(tester.takeException(), isNull);
  });
}
