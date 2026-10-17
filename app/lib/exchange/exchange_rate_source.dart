import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'exchange_rate.dart';

abstract interface class RateSource {
  Future<NetworkRateSnapshot> fetch();
  void cancel();
  void dispose();
}

class RateCancelledException implements Exception {
  const RateCancelledException();
}

/// One bounded request. Closing the client also aborts DNS/socket/body work.
/// Only currency codes are requested; no account or transaction is transmitted.
class HttpRateSource implements RateSource {
  HttpRateSource({
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 8),
    Uri? endpoint,
  }) : _now = now ?? DateTime.now,
       endpoint =
           endpoint ??
           Uri.https('api.frankfurter.dev', '/v2/providers/ecb/rates', {
             'base': 'EUR',
             'quotes': 'CNY,USD,HKD,JPY,GBP',
           });

  final DateTime Function() _now;
  final Duration timeout;
  final Uri endpoint;
  HttpClient? _client;
  bool _cancelled = false;
  bool _started = false;

  @override
  Future<NetworkRateSnapshot> fetch() async {
    if (_started) throw StateError('RateSource can only be used once');
    _started = true;
    if (_cancelled) throw const RateCancelledException();
    final client = HttpClient()..connectionTimeout = timeout;
    _client = client;
    try {
      return await _fetch(client).timeout(
        timeout,
        onTimeout: () {
          cancel();
          throw TimeoutException('汇率请求超时', timeout);
        },
      );
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  Future<NetworkRateSnapshot> _fetch(HttpClient client) async {
    final request = await client.getUrl(endpoint);
    if (_cancelled) throw const RateCancelledException();
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('汇率服务暂不可用（HTTP ${response.statusCode}）');
    }
    const maxBytes = 32768;
    if (response.contentLength > maxBytes) {
      throw const FormatException('汇率响应过大');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (_cancelled) throw const RateCancelledException();
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('汇率响应过大');
      }
      bytes.addAll(chunk);
    }
    if (_cancelled) throw const RateCancelledException();
    return parseEcbRates(utf8.decode(bytes), fetchedAt: _now().toUtc());
  }

  @override
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  @override
  void dispose() => cancel();
}
