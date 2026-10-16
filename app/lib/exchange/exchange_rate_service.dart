import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../utils/currency.dart';
import 'exchange_rate.dart';
import 'exchange_rate_source.dart';

export 'exchange_rate_source.dart' show RateSource;

const exchangeRateMetaKey = 'exchange_rates.v1';

abstract interface class RateStore {
  Future<String?> read();
  Future<void> write(String value);
}

class DatabaseRateStore implements RateStore {
  DatabaseRateStore(this.database);
  final AppDatabase database;

  @override
  Future<String?> read() => database.getMeta(exchangeRateMetaKey);

  @override
  Future<void> write(String value) =>
      database.setMeta(exchangeRateMetaKey, value);
}

/// An immutable effective quote. Future consumers must freeze this snapshot,
/// rather than rereading changing network data halfway through a calculation.
class RateQuote {
  const RateQuote({
    required this.base,
    required this.quote,
    required this.ratio,
    required this.isManual,
    required this.isStale,
    required this.source,
    required this.quotedAt,
    required this.fetchedAt,
  });
  final Currency base;
  final Currency quote;
  final RateRatio ratio;
  final bool isManual;
  final bool isStale;
  final String source;
  final DateTime quotedAt;
  final DateTime fetchedAt;
}

class _ManualRate {
  const _ManualRate(this.base, this.quote, this.ratio, this.updatedAt);
  final Currency base;
  final Currency quote;
  final RateRatio ratio;
  final DateTime updatedAt;

  Map<String, Object> toJson() => {
    'base': base.code,
    'quote': quote.code,
    'ratio': ratio.toJson(),
    'updatedAtMs': updatedAt.millisecondsSinceEpoch,
  };
}

String _pair(Currency a, Currency b) =>
    a.index < b.index ? '${a.code}/${b.code}' : '${b.code}/${a.code}';

/// Shared, local-only cache. Network and manual changes commit one complete
/// versioned record; memory is published only after persistence succeeds.
class ExchangeRateService extends ChangeNotifier {
  ExchangeRateService({
    required this.store,
    RateSource Function()? sourceFactory,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _sourceFactory = sourceFactory ?? (() => HttpRateSource(now: now));

  final RateStore store;
  final RateSource Function() _sourceFactory;
  final DateTime Function() _now;
  NetworkRateSnapshot? _network;
  Map<String, _ManualRate> _manual = {};
  Future<void> _writes = Future<void>.value();
  Future<void>? _initializing;
  Completer<void>? _cacheReady;
  RateSource? _request;
  int _generation = 0;
  bool _disposed = false;
  bool _initialized = false;
  bool _loading = false;
  int _savingCount = 0;
  bool _cacheCorrupt = false;
  String? _error;

  bool get initialized => _initialized;
  bool get loading => _loading;
  bool get saving => _savingCount > 0;
  bool get cacheCorrupt => _cacheCorrupt;
  String? get error => _error;
  NetworkRateSnapshot? get network => _network;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    // The queue remains usable after failed writes; the caller still receives
    // the original error and no partially updated in-memory state.
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> initialize() {
    if (_disposed || _initialized) return Future<void>.value();
    if (_initializing != null) return _initializing!;
    final ready = Completer<void>();
    _cacheReady = ready;
    return _initializing = _load(ready)
        .whenComplete(() => _initializing = null);
  }

  Future<void> _load(Completer<void> ready) async {
    try {
      final raw = await store.read();
      if (_disposed) return;
      if (raw != null) {
        try {
          _decode(raw);
        } on FormatException {
          _cacheCorrupt = true;
          _error = '本地汇率缓存损坏，未采用；请刷新或重新设置';
        }
      }
      _initialized = true;
      _publish();
    } catch (_) {
      if (!_disposed) {
        _error = '无法读取本地汇率，请重试';
        _publish();
      }
    } finally {
      ready.complete();
    }
    // Do not silently overwrite a corrupt record that may contain manual
    // settings. An explicit refresh/save is required in that case.
    if (_initialized &&
        !_cacheCorrupt &&
        (_network == null || _network!.isStaleAt(_now()))) {
      await _refreshInitialized();
    }
  }

  void _decode(String raw) {
    if (raw.length > 32768) throw const FormatException('Cache too large');
    validateRateJson(raw);
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data.length != 3 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        !data.containsKey('network') ||
        data['manual'] is! List) {
      throw const FormatException('Invalid cache');
    }
    final snapshot = data['network'] == null
        ? null
        : NetworkRateSnapshot.fromJson(data['network']);
    final now = _now().toUtc();
    if (snapshot != null &&
        (snapshot.fetchedAt.isAfter(now.add(const Duration(minutes: 5))) ||
            snapshot.quotedAt.isAfter(
              DateTime.utc(now.year, now.month, now.day),
            ))) {
      throw const FormatException('Future cache');
    }
    final manual = <String, _ManualRate>{};
    final list = data['manual'] as List;
    if (list.length > 15) throw const FormatException('Too many pairs');
    for (final item in list) {
      if (item is! Map<String, dynamic> ||
          item.length != 4 ||
          item['base'] is! String ||
          item['quote'] is! String ||
          item['updatedAtMs'] is! int) {
        throw const FormatException('Invalid manual rate');
      }
      final base = Currency.tryFromCode(item['base'] as String);
      final quote = Currency.tryFromCode(item['quote'] as String);
      final updatedAtMs = item['updatedAtMs'] as int;
      if (base == null ||
          quote == null ||
          base == quote ||
          item['base'] != base.code ||
          item['quote'] != quote.code ||
          updatedAtMs < 0 ||
          updatedAtMs >
              now.add(const Duration(minutes: 5)).millisecondsSinceEpoch) {
        throw const FormatException('Invalid manual direction/time');
      }
      final key = _pair(base, quote);
      if (manual.containsKey(key)) {
        throw const FormatException('Duplicate pair');
      }
      manual[key] = _ManualRate(
        base,
        quote,
        RateRatio.fromJson(item['ratio']),
        DateTime.fromMillisecondsSinceEpoch(updatedAtMs, isUtc: true),
      );
    }
    _network = snapshot;
    _manual = manual;
  }

  String _encode(
    NetworkRateSnapshot? network,
    Map<String, _ManualRate> manual,
  ) => jsonEncode({
    'version': 1,
    'network': network?.toJson(),
    'manual': manual.values.map((rate) => rate.toJson()).toList(),
  });

  RateQuote? quote(Currency base, Currency target) {
    final now = _now().toUtc();
    if (base == target) {
      return RateQuote(
        base: base,
        quote: target,
        ratio: RateRatio(BigInt.one, BigInt.one),
        isManual: false,
        isStale: false,
        source: '同币种',
        quotedAt: now,
        fetchedAt: now,
      );
    }
    final manual = _manual[_pair(base, target)];
    if (manual != null) {
      return RateQuote(
        base: base,
        quote: target,
        ratio: manual.base == base ? manual.ratio : manual.ratio.inverse,
        isManual: true,
        isStale: false,
        source: '手动设置',
        quotedAt: manual.updatedAt,
        fetchedAt: manual.updatedAt,
      );
    }
    final snapshot = _network;
    if (snapshot == null) return null;
    return RateQuote(
      base: base,
      quote: target,
      ratio: snapshot.ratio(base, target),
      isManual: false,
      isStale: snapshot.isStaleAt(now),
      source: snapshot.source,
      quotedAt: snapshot.quotedAt,
      fetchedAt: snapshot.fetchedAt,
    );
  }

  Future<void> refresh() async {
    if (_disposed || _loading) return;
    // initialize already performs the first needed refresh.
    if (!_initialized) {
      final generation = _generation;
      await initialize();
      if (_initialized &&
          !_disposed &&
          !_loading &&
          generation == _generation) {
        await _refreshInitialized();
      }
      return;
    }
    await _refreshInitialized();
  }

  Future<void> _refreshInitialized() async {
    if (_disposed || _loading) return;
    final generation = ++_generation;
    RateSource? source;
    _loading = true;
    _error = null;
    _publish();
    try {
      if (_disposed || generation != _generation) return;
      source = _sourceFactory();
      _request = source;
      final result = await source.fetch();
      final now = _now().toUtc();
      if (result.fetchedAt.isAfter(now.add(const Duration(minutes: 5))) ||
          result.quotedAt.isAfter(DateTime.utc(now.year, now.month, now.day))) {
        throw const FormatException('Future network quote');
      }
      await _serialize(() async {
        if (_disposed || generation != _generation) return;
        // Cancellation ends at this commit boundary. Hide the cancel control
        // and show saving while the atomic cache write is in progress. A later
        // manual operation is serialized after it and uses the committed cache.
        _loading = false;
        _request = null;
        _savingCount++;
        _publish();
        try {
          await store.write(_encode(result, _manual));
          if (_disposed) return;
          _network = result;
          _cacheCorrupt = false;
        } finally {
          _savingCount--;
          _publish();
        }
      });
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _error = switch (error) {
          TimeoutException() => '联网汇率请求超时；可重试或手动设置',
          SocketException() || HandshakeException() => '网络不可用；可使用缓存或手动设置',
          FormatException() => '汇率响应无效，原缓存已保留',
          RateCancelledException() => '汇率刷新已取消',
          HttpException() => '汇率服务暂不可用；可重试或手动设置',
          _ => '汇率刷新或保存失败，原值已保留',
        };
      }
    } finally {
      source?.dispose();
      if (generation == _generation) {
        _request = null;
        _loading = false;
        _publish();
      }
    }
  }

  void _invalidateRequest() {
    ++_generation;
    _request?.cancel();
    _request = null;
    _loading = false;
  }

  void cancelRefresh() {
    if (!_loading || _disposed) return;
    _invalidateRequest();
    _error = '汇率刷新已取消，原值已保留';
    _publish();
  }

  Future<void> setManual(Currency base, Currency target, String input) async {
    final trimmed = input.trim();
    if (input.length > 64 ||
        !RegExp(r'^(?:[0-9]+(?:\.[0-9]{1,18})?|\.[0-9]{1,18})$')
            .hasMatch(trimmed) ||
        base == target) {
      throw const FormatException('请输入大于零的十进制汇率，最多 18 位小数');
    }
    final ratio = RateRatio.parse(trimmed);
    // Await only the cache read, not a slow automatic network refresh.
    final initialization = initialize();
    if (!_initialized) await (_cacheReady?.future ?? initialization);
    if (!_initialized || _disposed) throw StateError('本地汇率尚未就绪');
    _invalidateRequest();
    _savingCount++;
    _publish();
    try {
      await _serialize(() async {
        if (_disposed) throw StateError('汇率设置已关闭');
        final manual = Map<String, _ManualRate>.of(_manual);
        manual[_pair(base, target)] = _ManualRate(
          base,
          target,
          ratio,
          _now().toUtc(),
        );
        await store.write(_encode(_network, manual));
        if (_disposed) return;
        _manual = manual;
        _cacheCorrupt = false;
        _error = null;
      });
    } catch (_) {
      _error = '手动汇率保存失败，原值已保留';
      rethrow;
    } finally {
      _savingCount--;
      _publish();
    }
  }

  Future<void> useNetwork(Currency base, Currency target) async {
    if (!_initialized) {
      final initialization = initialize();
      await (_cacheReady?.future ?? initialization);
    }
    if (!_initialized || _disposed) throw StateError('本地汇率尚未就绪');
    _invalidateRequest();
    _savingCount++;
    _publish();
    try {
      await _serialize(() async {
        if (_disposed) throw StateError('汇率设置已关闭');
        final manual = Map<String, _ManualRate>.of(_manual)
          ..remove(_pair(base, target));
        await store.write(_encode(_network, manual));
        if (_disposed) return;
        _manual = manual;
        _cacheCorrupt = false;
        _error = null;
      });
    } catch (_) {
      _error = '恢复联网保存失败，原手动值已保留';
      rethrow;
    } finally {
      _savingCount--;
      _publish();
    }
    if (!_disposed && (_network == null || _network!.isStaleAt(_now()))) {
      await _refreshInitialized();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateRequest();
    super.dispose();
  }
}
